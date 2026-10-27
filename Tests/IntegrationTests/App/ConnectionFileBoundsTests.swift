import Darwin
import Foundation
@testable import RoamingApp
import SSHIdentity
import Testing

struct ConnectionFileBoundsTests {
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("connection-files-" + UUID().uuidString)

  @Test
  func missingFilesAreDistinctFromDanglingLinksAndSpecialFiles() throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("missing")
    #expect(try BoundedFile.readIfPresent(missing, limit: 64) == nil)
    #expect(try ConnectionStore(fileURL: missing).loadSnapshot().hosts.isEmpty)
    let dangling = directory.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(
      at: dangling,
      withDestinationURL: missing
    )
    let fifo = directory.appendingPathComponent("fifo")
    try #require(mkfifo(fifo.path, 0o600) == 0)
    for file in [dangling, directory, fifo] {
      #expect(throws: ConnectionStore.StoreError.self) {
        try ConnectionStore(fileURL: file).loadSnapshot()
      }
      #expect(KeyFile.read(file) == nil)
    }
  }

  @Test(arguments: [false, true])
  func oversizedSnapshotAliasesAreRejected(previous: Bool) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConnectionStore(
      fileURL: directory.appendingPathComponent("hosts.json")
    )
    let target = directory.appendingPathComponent("oversized")
    try Data(repeating: 0x20, count: ConnectionStore.maxFileBytes + 1)
      .write(to: target)
    try FileManager.default.createSymbolicLink(
      at: previous ? store.previousURL : store.fileURL,
      withDestinationURL: target
    )
    #expect(throws: ConnectionStore.StoreError.tooLarge) {
      if previous {
        _ = try store.loadPrevious()
      } else {
        _ = try store.loadSnapshot()
      }
    }
    if !previous {
      #expect(throws: ConnectionStore.StoreError.tooLarge) {
        try store.commit(ConnectionSnapshot())
      }
      #expect(
        try Data(contentsOf: target).count == ConnectionStore.maxFileBytes + 1
      )
    }
  }

  @Test
  func selectedKeyAliasesCannotBypassTheReadLimit() throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("key")
    let alias = directory.appendingPathComponent("alias")
    let boundary = Data(
      repeating: 0x61,
      count: OpenSSHKeyImporter.maxInputBytes
    )
    try boundary.write(to: target)
    try FileManager.default.createSymbolicLink(
      at: alias,
      withDestinationURL: target
    )
    #expect(KeyFile.read(alias) == boundary)
    try (boundary + Data([0x61])).write(to: target)
    #expect(KeyFile.read(alias) == nil)
  }

  @Test(arguments: [false, true])
  func commitRefusesAnUnreadableFileThatChangedAfterLoad(
    newerVersion: Bool
  ) throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConnectionStore(
      fileURL: directory.appendingPathComponent("hosts.json")
    )
    try store.commit(ConnectionSnapshot())
    var snapshot = try store.loadSnapshot()
    snapshot.upsertHost(
      HostProfile(nickname: "New", host: "new.local", username: "me")
    )
    let changed = Data(
      (newerVersion
        ? "{\"version\":\(ConnectionSnapshot.version + 1)}" : "corrupt")
        .utf8
    )
    try changed.write(to: store.fileURL)
    #expect(throws: ConnectionStore.StoreError.self) {
      try store.commit(snapshot)
    }
    #expect(try Data(contentsOf: store.fileURL) == changed)
    #expect(!FileManager.default.fileExists(atPath: store.previousURL.path))
  }
}
