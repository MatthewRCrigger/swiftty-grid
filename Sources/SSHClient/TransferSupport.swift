import Crypto
import Foundation
import SessionCore

#if canImport(Darwin)
import Darwin
#endif

/// Throttle hook for bulk SFTP work (spec §10, A15): transfers await the
/// gate before issuing each request, so the app can pause bulk traffic
/// while interactive terminal input is stalled.
public protocol TransferGate: Sendable {
  /// Returns when bulk work may proceed; throws on cancellation.
  func waitUntilOpen() async throws
}

/// A gate that never pauses.
public struct OpenTransferGate: TransferGate {
  public init() {}
  public func waitUntilOpen() async throws { try Task.checkCancellation() }
}

/// A gate the app pauses and resumes, e.g. while terminal input awaits
/// acknowledgment. Waiting is cancellation-aware and bounded.
public actor TransferPauseGate: TransferGate {
  public static let maxWaiters = 256

  public enum GateError: Error { case tooManyWaiters }

  private var paused = false
  private var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
  private var nextWaiter: UInt64 = 0

  public init() {}

  public var isPaused: Bool { paused }

  public func pause() { paused = true }

  public func resume() {
    paused = false
    let pending = waiters
    waiters.removeAll()
    for continuation in pending.values { continuation.resume() }
  }

  public func waitUntilOpen() async throws {
    while paused {
      guard waiters.count < Self.maxWaiters else {
        throw GateError.tooManyWaiters
      }
      let id = nextWaiter
      nextWaiter &+= 1
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            waiters[id] = continuation
          }
        }
      } onCancel: {
        Task { await self.cancelWaiter(id) }
      }
    }
    try Task.checkCancellation()
  }

  private func cancelWaiter(_ id: UInt64) {
    waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
  }
}

/// Blocking local file I/O confined to a dedicated serial queue so it
/// never runs on the cooperative pool or an event loop (spec §11).
enum BlockingFileIO {
  static let queue = DispatchQueue(label: "swiftty.sftp.file-io", qos: .utility)

  static func run<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try body() }) }
    }
  }

  /// Opt in only for jobs whose body can stop and clean up owned resources.
  /// Cancellation skips queued work but still joins its queue turn. Running
  /// jobs cooperate between bounded chunks; an in-flight syscall may finish.
  static func runCancellable<T: Sendable>(
    on queue: DispatchQueue = Self.queue,
    afterEnqueueForTesting: (@Sendable () -> Void)? = nil,
    _ body: @escaping @Sendable (FileIOCancellation) throws -> T
  ) async throws -> T {
    let cancellation = FileIOCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        queue.async {
          continuation.resume(
            with: Result {
              try cancellation.check()
              return try body(cancellation)
            }
          )
        }
        afterEnqueueForTesting?()
      }
    } onCancel: {
      cancellation.cancel()
    }
  }
}

func posixError() -> POSIXError {
  POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

/// A local file descriptor used only through `BlockingFileIO`.
struct LocalFile: Sendable {
  let fd: Int32

  /// POSIX paths cannot contain NUL: C file APIs would use only the prefix.
  static func isValidPath(_ path: String) -> Bool {
    !path.isEmpty && !path.utf8.contains(0)
  }

  private static func checkedOffset(
    _ offset: UInt64,
    count: Int = 0
  ) throws -> off_t {
    guard count >= 0 else { throw POSIXError(.EINVAL) }
    guard let base = off_t(exactly: offset),
      UInt64(count) <= UInt64(off_t.max) - offset
    else { throw POSIXError(.EOVERFLOW) }
    return base
  }

  static func open(
    _ path: String,
    flags: Int32,
    mode: mode_t = 0o600,
    excluding destinationPath: String? = nil
  ) async throws -> LocalFile {
    try await BlockingFileIO.run {
      guard Self.isValidPath(path),
        destinationPath.map(Self.isValidPath) ?? true
      else { throw SFTPTransferError.invalidManifest }
      if let destinationPath {
        try Self.validateDistinctDestination(
          path,
          destinationPath: destinationPath
        )
      }
      let fd = Darwin.open(
        path,
        flags | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
        mode
      )
      guard fd >= 0 else {
        if errno == ELOOP || errno == EISDIR {
          throw SFTPTransferError.notRegularFile
        }
        throw posixError()
      }
      do {
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else {
          throw SFTPTransferError.notRegularFile
        }
        if let destinationPath {
          var destination = Darwin.stat()
          if stat(destinationPath, &destination) == 0 {
            guard
              info.st_dev != destination.st_dev
                || info.st_ino != destination.st_ino
            else { throw SFTPTransferError.invalidManifest }
          } else if errno != ENOENT {
            throw posixError()
          }
        }
        return LocalFile(fd: fd)
      } catch {
        Darwin.close(fd)
        throw error
      }
    }
  }

  /// Checks names before O_CREAT can make an absent destination appear.
  /// Opened-descriptor identity also protects existing hardlink aliases.
  private static func validateDistinctDestination(
    _ path: String,
    destinationPath: String
  ) throws {
    let source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
      .standardizedFileURL
    let destination = URL(fileURLWithPath: destinationPath)
      .resolvingSymlinksInPath().standardizedFileURL
    guard source.path != destination.path else {
      throw SFTPTransferError.invalidManifest
    }
    guard
      source.lastPathComponent.compare(
        destination.lastPathComponent,
        options: .caseInsensitive
      ) == .orderedSame
    else { return }
    // Resolve parents separately: full-path resolution may leave a parent
    // symlink unresolved when the final entry is absent.
    let sourceParent = source.deletingLastPathComponent()
      .resolvingSymlinksInPath().standardizedFileURL
    let destinationParent = destination.deletingLastPathComponent()
      .resolvingSymlinksInPath().standardizedFileURL
    var sourceInfo = Darwin.stat()
    guard stat(sourceParent.path, &sourceInfo) == 0 else { throw posixError() }
    var destinationInfo = Darwin.stat()
    guard stat(destinationParent.path, &destinationInfo) == 0 else {
      if errno == ENOENT { return }
      throw posixError()
    }
    guard sourceInfo.st_dev == destinationInfo.st_dev,
      sourceInfo.st_ino == destinationInfo.st_ino
    else { return }
    if source.lastPathComponent == destination.lastPathComponent {
      throw SFTPTransferError.invalidManifest
    }
    let values = try sourceParent.resourceValues(forKeys: [
      .volumeSupportsCaseSensitiveNamesKey
    ])
    if values.volumeSupportsCaseSensitiveNames == false {
      throw SFTPTransferError.invalidManifest
    }
  }

  func size() async throws -> UInt64 {
    let fd = self.fd
    return try await BlockingFileIO.run {
      var info = Darwin.stat()
      guard fstat(fd, &info) == 0 else { throw posixError() }
      return UInt64(info.st_size)
    }
  }

  /// Reads up to `count` bytes at `offset`; shorter only at end of file.
  func read(at offset: UInt64, count: Int) async throws -> [UInt8] {
    let fd = self.fd
    return try await BlockingFileIO.run {
      try Self.readSync(fd: fd, offset: offset, count: count)
    }
  }

  static func readSync(fd: Int32, offset: UInt64, count: Int) throws -> [UInt8]
  {
    let base = try checkedOffset(offset, count: count)
    var bytes = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
      let n = bytes.withUnsafeMutableBytes { raw in
        pread(
          fd,
          raw.baseAddress! + filled,
          count - filled,
          base + off_t(filled)
        )
      }
      if n < 0 {
        if errno == EINTR { continue }
        throw posixError()
      }
      if n == 0 { break }
      filled += n
    }
    bytes.removeLast(count - filled)
    return bytes
  }

  /// Positioned write of every byte.
  func write(_ bytes: [UInt8], at offset: UInt64) async throws {
    let base = try Self.checkedOffset(offset, count: bytes.count)
    let fd = self.fd
    try await BlockingFileIO.run {
      var written = 0
      while written < bytes.count {
        let n = bytes.withUnsafeBytes { raw in
          pwrite(
            fd,
            raw.baseAddress! + written,
            bytes.count - written,
            base + off_t(written)
          )
        }
        if n < 0 {
          if errno == EINTR { continue }
          throw posixError()
        }
        guard n > 0 else { throw POSIXError(.EIO) }
        written += n
      }
    }
  }

  func truncate(to length: UInt64) async throws {
    let size = try Self.checkedOffset(length)
    let fd = self.fd
    try await BlockingFileIO.run {
      guard ftruncate(fd, size) == 0 else { throw posixError() }
    }
  }

  func sync() async throws {
    let fd = self.fd
    try await BlockingFileIO.run {
      guard fsync(fd) == 0 else { throw posixError() }
    }
  }

  /// SHA-256 of bytes `0 ..< length`, or `nil` if the file is shorter.
  func sha256(length: UInt64) async throws -> String? {
    try await sha256(length: length, afterReadForTesting: nil)
  }

  func sha256(
    length: UInt64,
    afterReadForTesting: (@Sendable (UInt64) throws -> Void)?
  ) async throws -> String? {
    let fd = self.fd
    return try await BlockingFileIO.runCancellable { cancellation in
      var hasher = SHA256()
      var offset: UInt64 = 0
      let block = 256 * 1024
      while offset < length {
        try cancellation.check()
        let want = Int(min(UInt64(block), length - offset))
        let bytes = try Self.readSync(fd: fd, offset: offset, count: want)
        try afterReadForTesting?(offset)
        try cancellation.check()
        guard bytes.count == want else { return nil }
        hasher.update(data: bytes)
        offset += UInt64(want)
      }
      try cancellation.check()
      return hexString(hasher.finalize())
    }
  }
}
