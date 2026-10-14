import Foundation
import Testing

@testable import RoamingApp

extension MainActorIntegrationTests {
  struct HostProfileStoreTests {
    @MainActor
    @Test
    func failedSaveReportsFailureAndPreservesTheHostList() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      let parent = directory.appendingPathComponent("file")
      try Data([1]).write(to: parent)
      let app = RoamingAppModel(
        store: HostProfileStore(
          fileURL: parent.appendingPathComponent("hosts.json")
        )
      )
      let host = HostProfile(
        nickname: "Test",
        host: "test.local",
        username: "test"
      )
      #expect(!(try app.save(host)))
      #expect(app.hosts.isEmpty)
      #expect(app.lastError != nil)
      #expect(try Data(contentsOf: parent) == Data([1]))
    }

    @Test
    func duplicateHostIDsCannotReplaceTheSavedFile() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = HostProfileStore(
        fileURL: directory.appendingPathComponent("hosts.json")
      )
      let first = HostProfile(
        nickname: "First",
        host: "first.local",
        username: "test"
      )
      try store.save([first])
      let original = try Data(contentsOf: store.fileURL)
      var duplicate = first
      duplicate.host = "second.local"
      #expect(throws: HostProfileStore.StoreError.self) {
        try store.save([first, duplicate])
      }
      #expect(try Data(contentsOf: store.fileURL) == original)
      #expect(try store.load() == [first])
    }

    @Test
    func decodingKeepsTheFirstValidHostForEachIdentity() throws {
      let first = HostProfile(
        nickname: "First",
        host: "first.local",
        username: "test"
      )
      var duplicate = first
      duplicate.host = "second.local"
      let independent = HostProfile(
        nickname: "Other",
        host: "other.local",
        username: "test"
      )
      var invalid = independent
      invalid.host = ""
      let data = try JSONEncoder()
        .encode(
          HostProfileStore.File(
            version: 1,
            hosts: [first, duplicate, invalid, independent]
          )
        )
      #expect(try HostProfileStore.decode(data) == [first, independent])
    }

    @MainActor
    @Test
    func aFailedLoadRefusesToReplaceTheSavedFile() throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      let store = HostProfileStore(
        fileURL: directory.appendingPathComponent("hosts.json")
      )
      let first = HostProfile(
        nickname: "First",
        host: "first.local",
        username: "test"
      )
      try store.save([first])
      let app = RoamingAppModel(store: store)
      app.load()
      #expect(app.hosts == [first])
      let broken = Data("nope".utf8)
      try broken.write(to: store.fileURL)
      app.load()
      #expect(app.hosts == [first])
      #expect(app.lastError != nil)
      let added = HostProfile(
        nickname: "Added",
        host: "added.local",
        username: "test"
      )
      #expect(!(try app.save(added)))
      #expect(app.hosts == [first])
      #expect(try Data(contentsOf: store.fileURL) == broken)
    }
  }
}
