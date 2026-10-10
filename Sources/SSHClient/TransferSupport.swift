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
}

func posixError() -> POSIXError {
  POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

/// A local file descriptor used only through `BlockingFileIO`.
struct LocalFile: Sendable {
  let fd: Int32

  static func open(
    _ path: String,
    flags: Int32,
    mode: mode_t = 0o600
  ) async throws -> LocalFile {
    try await BlockingFileIO.run {
      let fd = Darwin.open(path, flags | O_CLOEXEC, mode)
      guard fd >= 0 else { throw posixError() }
      return LocalFile(fd: fd)
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

  static func readSync(fd: Int32, offset: UInt64, count: Int) throws
    -> [UInt8]
  {
    var bytes = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
      let n = bytes.withUnsafeMutableBytes { raw in
        pread(fd, raw.baseAddress! + filled, count - filled,
          off_t(offset) + off_t(filled))
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
    let fd = self.fd
    try await BlockingFileIO.run {
      var written = 0
      while written < bytes.count {
        let n = bytes.withUnsafeBytes { raw in
          pwrite(fd, raw.baseAddress! + written, bytes.count - written,
            off_t(offset) + off_t(written))
        }
        if n < 0 {
          if errno == EINTR { continue }
          throw posixError()
        }
        written += n
      }
    }
  }

  func truncate(to length: UInt64) async throws {
    let fd = self.fd
    try await BlockingFileIO.run {
      guard ftruncate(fd, off_t(length)) == 0 else { throw posixError() }
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
    let fd = self.fd
    return try await BlockingFileIO.run {
      var hasher = SHA256()
      var offset: UInt64 = 0
      let block = 256 * 1024
      while offset < length {
        let want = Int(min(UInt64(block), length - offset))
        let bytes = try Self.readSync(fd: fd, offset: offset, count: want)
        guard bytes.count == want else { return nil }
        hasher.update(data: bytes)
        offset += UInt64(want)
      }
      return hexString(hasher.finalize())
    }
  }
}
