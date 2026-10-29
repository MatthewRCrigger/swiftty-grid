#if !os(tvOS)
import Foundation
@testable import RoamingApp
import SessionCore
import SSHClient
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: ["upload", "download", "lostRenameReply"])
  func staleBrowserResumesLatestCheckpoint(direction: String) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let root = directory.appendingPathComponent("transfers")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let source = root.appendingPathComponent("source.bin")
    let destination = root.appendingPathComponent("download.bin")
    let bytes = Data("completed-transfer-content".utf8)
    try bytes.write(to: source)
    let server = try await TestSSHServer.start()
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username
    )
    var first: SFTPBrowserModel?
    var stale: SFTPBrowserModel?
    do {
      #expect(try model.save(host))
      let manifest: TransferManifest
      if direction != "download" {
        manifest = try await SFTPTransfers.prepareUpload(
          source: source,
          remotePath: "/target.bin",
          stagingDirectory: root.appendingPathComponent("staging")
        )
      } else {
        try bytes.write(to: server.url("/target.bin"))
        manifest = try SFTPTransfers.prepareDownload(
          remotePath: "/target.bin",
          temporaryDirectory: root,
          destination: destination
        )
      }
      let store = TransferManifestStore(
        directory: root.appendingPathComponent("manifests"),
        owner: HostDataOwner(model.connectionSelection(for: host))
      )
      try store.save(manifest)
      let writer = SFTPBrowserModel(
        host: host,
        app: model,
        transferDirectory: root,
        connectSSH: { try await server.connect() }
      )
      first = writer
      let reader = SFTPBrowserModel(
        host: host,
        app: model,
        transferDirectory: root,
        connectSSH: { try await server.connect() }
      )
      stale = reader
      let cached = try #require(reader.transfers.first)
      await reader.connect()
      if direction == "lostRenameReply" {
        server.state.faults.withLock { $0.dropRenameResponse = true }
      }
      await writer.resume(try #require(writer.transfers.first))
      try #require(
        await eventually { @MainActor in
          writer.transfers.first?.state != .running
        }
      )
      await writer.shutdown().value
      let checkpoint = try #require(store.loadAll().first)
      #expect(
        checkpoint.state
          == (direction == "lostRenameReply" ? .renaming : .completed)
      )
      #expect(reader.transfers.first?.manifest == manifest)
      let requests = server.state.sftpRequests.withLock { $0 }
      await reader.resume(cached)
      try #require(
        await eventually { @MainActor in
          reader.transfers.first?.state != .running
        }
      )
      #expect(reader.transfers.first?.state == .completed)
      let completed = try #require(reader.transfers.first?.manifest)
      #expect(completed.isComplete)
      #expect(store.loadAll() == [completed])
      #expect(completed.restartCount == checkpoint.restartCount)
      if checkpoint.isComplete {
        #expect(completed == checkpoint)
        #expect(server.state.sftpRequests.withLock { $0 } == requests)
      }
      #expect(
        try Data(
          contentsOf: direction == "download"
            ? destination : server.url("/target.bin")
        ) == bytes
      )
    } catch {
      await first?.shutdown().value
      await stale?.shutdown().value
      await server.shutdown()
      throw error
    }
    await first?.shutdown().value
    await stale?.shutdown().value
    await server.shutdown()
  }

  @Test
  func staleBrowserRemovesCurrentTemporaryFile() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let root = directory.appendingPathComponent("transfers")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let source = root.appendingPathComponent("source.bin")
    let bytes = Data("retained-old-path".utf8)
    try bytes.write(to: source)
    let server = try await TestSSHServer.start()
    var browser: SFTPBrowserModel?
    do {
      let host = HostProfile(
        nickname: "A",
        host: "127.0.0.1",
        port: server.port,
        username: TestSSHServer.username
      )
      #expect(try model.save(host))
      var manifest = try await SFTPTransfers.prepareUpload(
        source: source,
        remotePath: "/target.bin",
        stagingDirectory: root
      )
      let store = TransferManifestStore(
        directory: root.appendingPathComponent("manifests"),
        owner: HostDataOwner(model.connectionSelection(for: host))
      )
      try store.save(manifest)
      let reader = SFTPBrowserModel(
        host: host,
        app: model,
        transferDirectory: root,
        connectSSH: { try await server.connect() }
      )
      browser = reader
      let cached = try #require(reader.transfers.first)
      let oldPath = try #require(manifest.remoteTemporaryPath)
      // A previous attempt restarted under a fresh temporary name. Its old
      // pathname is no longer the checkpoint's deletion target.
      manifest.remoteTemporaryPath = "/new-attempt.part"
      manifest.restartCount += 1
      try store.save(manifest)
      try bytes.write(to: server.url(oldPath))
      try bytes.write(to: server.url("/new-attempt.part"))
      await reader.connect()
      await reader.remove(cached)
      #expect(try Data(contentsOf: server.url(oldPath)) == bytes)
      #expect(
        !FileManager.default.fileExists(
          atPath: server.url("/new-attempt.part").path
        )
      )
      #expect(!FileManager.default.fileExists(atPath: manifest.localPath))
      #expect(store.loadAll().isEmpty)
      #expect(reader.transfers.isEmpty)
    } catch {
      await browser?.shutdown().value
      await server.shutdown()
      throw error
    }
    await browser?.shutdown().value
    await server.shutdown()
  }
}
#endif
