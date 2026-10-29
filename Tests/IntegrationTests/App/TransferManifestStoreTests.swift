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
  @MainActor
  @Test
  func ownedEnvelopesBoundEncodingAndNeverDowngradeToLegacy() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("owned-manifest-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = RoamingAppModel()
    let host = HostProfile(nickname: "A", host: "a.local", username: "me")
    let owner = HostDataOwner(model.connectionSelection(for: host))
    let store = TransferManifestStore(directory: directory, owner: owner)
    var manifest = TransferManifest(
      direction: .upload,
      localPath: "/stage",
      remotePath: "/target",
      sourceSize: 1
    )
    try store.save(manifest)
    let file = directory.appendingPathComponent(
      manifest.id.uuidString + ".json"
    )
    let saved = try Data(contentsOf: file)
    manifest.localPath = String(
      repeating: "x",
      count: TransferManifest.maxEncodedBytes
    )
    #expect(throws: TransferManifestStore.StoreError.self) {
      try store.save(manifest)
    }
    #expect(try Data(contentsOf: file) == saved)
    var object = try #require(
      JSONSerialization.jsonObject(with: saved) as? [String: Any]
    )
    for invalid in ["version", "owner", "progress"] {
      var changed = object
      if invalid == "version" { changed["version"] = 2 }
      if invalid == "owner" { changed["owner"] = "invalid" }
      if invalid == "progress" {
        var nested = try #require(changed["manifest"] as? [String: Any])
        nested["acknowledgedOffset"] = 2
        changed["manifest"] = nested
      }
      try JSONSerialization.data(withJSONObject: changed).write(to: file)
      #expect(store.loadAll().isEmpty)
      #expect(store.recoverable().isEmpty)
    }
    // Extra raw manifest fields must not turn a broken envelope into legacy data.
    object["owner"] = "invalid"
    let raw = try #require(
      JSONSerialization.jsonObject(
        with: TransferManifest(
          direction: .upload,
          localPath: "/stage",
          remotePath: "/target",
          sourceSize: 1
        )
        .encoded()
      ) as? [String: Any]
    )
    object.merge(raw) { current, _ in current }
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    #expect(store.recoverable().isEmpty)
    let corrupt = try Data(contentsOf: file)
    TransferManifestStore(directory: directory).remove(manifest.id)
    #expect(try Data(contentsOf: file) == corrupt)
    var exact = saved
    exact.append(
      contentsOf: repeatElement(
        0x20,
        count: TransferManifest.maxEncodedBytes - saved.count
      )
    )
    try exact.write(to: file)
    #expect(store.loadAll().count == 1)
    exact.append(0x20)
    try exact.write(to: file)
    #expect(store.loadAll().isEmpty)
  }

  @MainActor
  @Test
  func aClaimedCheckpointRejectsStaleOwnersAndConcurrentUses() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("claimed-manifest-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = RoamingAppModel()
    let host = HostProfile(nickname: "A", host: "a.local", username: "me")
    let first = TransferManifestStore(
      directory: directory,
      owner: HostDataOwner(model.connectionSelection(for: host))
    )
    var otherHost = host
    otherHost.username = "other"
    let second = TransferManifestStore(
      directory: directory,
      owner: HostDataOwner(model.connectionSelection(for: otherHost))
    )
    let legacy = TransferManifestStore(directory: directory)
    let manifest = TransferManifest(
      direction: .upload,
      localPath: "/stage",
      remotePath: "/target",
      sourceSize: 1
    )
    try legacy.save(manifest)
    let reviewed = try #require(first.recoverable().first)
    #expect(legacy.beginUse(manifest.id) == manifest)
    #expect(legacy.beginUse(manifest.id) == nil)
    #expect(throws: TransferManifestStore.StoreError.self) {
      try first.recover(reviewed, as: manifest)
    }
    legacy.endUse(manifest.id)
    try first.recover(reviewed, as: manifest)
    #expect(throws: TransferManifestStore.StoreError.self) {
      try second.recover(reviewed, as: manifest)
    }
    #expect(throws: TransferManifestStore.StoreError.self) {
      try legacy.save(manifest)
    }
    #expect(throws: TransferManifestStore.StoreError.self) {
      try second.save(manifest)
    }
    legacy.remove(manifest.id)
    second.remove(manifest.id)
    #expect(first.loadAll() == [manifest])
    #expect(second.loadAll().isEmpty)
    #expect(second.recoverable().isEmpty)
    #expect(second.beginUse(manifest.id) == nil)
    #expect(first.beginUse(manifest.id) == manifest)
    first.endUse(manifest.id)
  }

}
#endif
