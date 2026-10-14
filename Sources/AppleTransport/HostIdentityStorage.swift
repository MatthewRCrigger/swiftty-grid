#if os(macOS)
import Darwin
import Foundation
import SessionCore

/// Anchors identity operations to one validated, owner-only directory.
/// Each read validates the descriptor it uses, rather than a prior path lookup.
final class HostIdentityStorage {
  enum File {
    case key, certificate

    var name: String {
      self == .key ? HostIdentity.keyFile : HostIdentity.certificateFile
    }

    var byteRange: ClosedRange<Int> {
      self == .key ? 32 ... 32 : 1 ... HostIdentity.maxCertificateBytes
    }
  }

  private let directory: Int32

  init(directory url: URL, create: Bool = false) throws {
    let path = url.path(percentEncoded: false)
    guard url.isFileURL, !path.utf8.contains(0) else {
      throw HostIdentityError.storage("invalid directory")
    }
    if create, mkdir(path, 0o700) != 0, errno != EEXIST {
      throw HostIdentityError.storage("mkdir errno \(errno)")
    }
    let descriptor = open(
      path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      if errno == ELOOP || errno == ENOTDIR {
        throw HostIdentityError.insecureStorage(url.lastPathComponent)
      }
      throw HostIdentityError.storage("open directory errno \(errno)")
    }
    do {
      _ = try Self.validate(
        descriptor,
        kind: S_IFDIR,
        name: url.lastPathComponent
      )
    } catch {
      close(descriptor)
      throw error
    }
    directory = descriptor
  }

  deinit { close(directory) }

  private static func validate(
    _ descriptor: Int32,
    kind: mode_t,
    name: String
  ) throws -> stat {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw HostIdentityError.storage("stat \(name)")
    }
    guard info.st_mode & S_IFMT == kind, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0
    else { throw HostIdentityError.insecureStorage(name) }
    return info
  }

  func read(
    _ file: File,
    afterValidationForTesting: (() throws -> Void)? = nil
  ) throws -> Data {
    let descriptor = openat(
      directory,
      file.name,
      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      if errno == ELOOP { throw HostIdentityError.insecureStorage(file.name) }
      throw HostIdentityError.storage("open \(file.name) errno \(errno)")
    }
    defer { close(descriptor) }
    let info = try Self.validate(descriptor, kind: S_IFREG, name: file.name)
    let range = file.byteRange
    guard info.st_size >= range.lowerBound, info.st_size <= range.upperBound
    else { throw HostIdentityError.storage("invalid size \(file.name)") }
    try afterValidationForTesting?()
    var bytes = Data()
    bytes.reserveCapacity(Int(info.st_size))
    var chunk = [UInt8](
      repeating: 0,
      count: min(16 * 1024, range.upperBound + 1)
    )
    while true {
      let count = chunk.withUnsafeMutableBytes {
        Darwin.read(
          descriptor,
          $0.baseAddress,
          min($0.count, range.upperBound - bytes.count + 1)
        )
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw HostIdentityError.storage("read \(file.name) errno \(errno)")
      }
      if count == 0 { break }
      guard count <= range.upperBound - bytes.count else {
        throw HostIdentityError.storage("invalid size \(file.name)")
      }
      bytes.append(contentsOf: chunk.prefix(count))
    }
    guard range.contains(bytes.count) else {
      throw HostIdentityError.storage("invalid size \(file.name)")
    }
    return bytes
  }

  /// Replaces one checkpoint atomically within the opened directory.
  func write(_ data: Data, to file: File) throws {
    guard file.byteRange.contains(data.count) else {
      throw HostIdentityError.storage("invalid size \(file.name)")
    }
    let temporary = ".\(file.name).\(hexString(secureRandomBytes(6)))"
    let descriptor = openat(
      directory,
      temporary,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard descriptor >= 0 else {
      throw HostIdentityError.storage("open temporary errno \(errno)")
    }
    defer {
      close(descriptor)
      unlinkat(directory, temporary, 0)
    }
    guard fchmod(descriptor, 0o600) == 0 else {
      throw HostIdentityError.storage("chmod temporary errno \(errno)")
    }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(
          descriptor,
          buffer.baseAddress! + offset,
          buffer.count - offset
        )
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw HostIdentityError.storage("write failed") }
        offset += count
      }
    }
    guard fsync(descriptor) == 0,
      renameat(directory, temporary, directory, file.name) == 0
    else { throw HostIdentityError.storage("write failed") }
  }
}
#endif
