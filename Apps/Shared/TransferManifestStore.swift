#if !os(tvOS)
import Darwin
import Foundation
import SessionCore

/// Non-secret transfer checkpoints, one bounded JSON file per manifest.
struct TransferManifestStore: Sendable {
  let directory: URL

  private func url(for id: UUID) -> URL {
    directory.appending(
      path: id.uuidString + ".json",
      directoryHint: .notDirectory
    )
  }

  func save(_ manifest: TransferManifest) throws {
    let data = try manifest.encoded()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try data.write(to: url(for: manifest.id), options: [.atomic])
  }

  func remove(_ id: UUID) {
    try? FileManager.default.removeItem(at: url(for: id))
  }

  func loadAll() -> [TransferManifest] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )) ?? []
    return files.filter { $0.pathExtension == "json" }
      .compactMap { file in
        guard let data = read(file) else { return nil }
        return try? TransferManifest.decode(data)
      }
  }

  /// Metadata and reads use one descriptor, including regular-file aliases.
  /// Nonblocking open makes FIFOs safe to reject before attempting a read.
  private func read(_ file: URL) -> Data? {
    guard file.isFileURL, !file.path.utf8.contains(0) else { return nil }
    let descriptor = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }
    var info = Darwin.stat()
    let limit = TransferManifest.maxEncodedBytes
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size >= 0, info.st_size <= limit
    else { return nil }
    var data = Data()
    data.reserveCapacity(Int(info.st_size))
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let count = chunk.withUnsafeMutableBytes {
        Darwin.read(
          descriptor,
          $0.baseAddress,
          min($0.count, limit - data.count + 1)
        )
      }
      if count < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if count == 0 { return data }
      guard count <= limit - data.count else { return nil }
      data.append(contentsOf: chunk.prefix(count))
    }
  }
}
#endif
