import Darwin
import Foundation
import SwifttyEngine

/// Bounded UTF-8 input from the same opened regular file. Symlinks to regular
/// files are allowed; byte limits do not impose a filesystem I/O deadline.
enum ConfigurationFile {
  enum Failure: Error { case invalidURL, notRegular, tooLarge, invalidUTF8 }

  static func path(for url: URL) -> String? {
    guard url.isFileURL else { return nil }
    let path = url.path(percentEncoded: false)
    return path.unicodeScalars.contains("\0") ? nil : path
  }

  /// Counts actual reads, including bytes later rejected by size/UTF-8 checks.
  static func read(
    _ url: URL,
    maxBytes: Int,
    didRead: (Int) -> Void = { _ in }
  ) throws -> String {
    guard let path = path(for: url) else { throw Failure.invalidURL }
    guard maxBytes >= 0, maxBytes < Int.max else { throw Failure.tooLarge }
    let fd = path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NONBLOCK) }
    guard fd >= 0 else {
      let code = errno
      if code == ENOENT { throw CocoaError(.fileReadNoSuchFile) }
      throw POSIXError("open", code: code)
    }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0 else { throw POSIXError("fstat") }
    guard status.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegular }
    guard status.st_size >= 0, status.st_size <= Int64(maxBytes) else {
      throw Failure.tooLarge
    }
    var data = Data()
    data.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      // A file can grow after fstat; read only the allowance plus one byte.
      let count = buffer.withUnsafeMutableBytes {
        Darwin.read(
          fd,
          $0.baseAddress,
          min($0.count, maxBytes + 1 - data.count)
        )
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw POSIXError("read")
      }
      if count == 0 { break }
      didRead(count)
      guard count <= maxBytes - data.count else { throw Failure.tooLarge }
      data.append(contentsOf: buffer.prefix(count))
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw Failure.invalidUTF8
    }
    return text
  }
}
