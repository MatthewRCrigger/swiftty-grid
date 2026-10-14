#if !os(tvOS)
import Darwin
import Foundation
import SessionCore
import Testing
@testable import RoamingApp

struct TransferManifestStoreTests {
  @Test
  func loaderBoundsRegularFileAliasesAndRejectsNonregularFiles() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("manifest-bounds-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifest = TransferManifest(
      direction: .upload,
      localPath: "/staged",
      remotePath: "/remote",
      sourceSize: 1,
      sourceSHA256: String(repeating: "0", count: 64)
    )
    var data = try manifest.encoded()
    data.append(
      contentsOf: repeatElement(
        UInt8(0x20),
        count: TransferManifest.maxEncodedBytes - data.count
      )
    )
    let target = directory.appendingPathComponent("exact.record")
    try data.write(to: target)
    let alias = directory.appendingPathComponent("exact.json")
    try FileManager.default.createSymbolicLink(
      at: alias,
      withDestinationURL: target
    )
    let store = TransferManifestStore(directory: directory)
    #expect(store.loadAll() == [manifest])
    data.append(0x20)
    try data.write(to: target)
    #expect(store.loadAll().isEmpty)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("folder.json"),
      withIntermediateDirectories: false
    )
    let fifo = directory.appendingPathComponent("pipe.json")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(store.loadAll().isEmpty)
    try store.save(manifest)
    #expect(store.loadAll() == [manifest])
  }

  @Test
  func invalidOrOversizedSaveCannotReplaceAValidCheckpoint() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("manifest-save-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = TransferManifestStore(directory: directory)
    var manifest = TransferManifest(
      direction: .upload,
      localPath: "/staged",
      remotePath: "/remote",
      sourceSize: 1,
      sourceSHA256: String(repeating: "0", count: 64)
    )
    manifest.acknowledgedOffset = 2
    #expect(throws: EncodingError.self) { try store.save(manifest) }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    manifest.acknowledgedOffset = 0
    try store.save(manifest)
    let saved = manifest
    manifest.localPath = String(
      repeating: "x",
      count: TransferManifest.maxEncodedBytes
    )
    #expect(throws: EncodingError.self) { try store.save(manifest) }
    #expect(store.loadAll() == [saved])
  }
}
#endif
