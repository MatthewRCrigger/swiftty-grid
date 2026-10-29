#if !os(tvOS)
import Foundation
@testable import RoamingApp
import SessionCore
import SSHClient
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: [
    "unchanged", "rename", "key", "accountReturn", "endpointReturn",
  ])
  func ownedTransferSurvivesValidReopening(change: String) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let server = try await TestSSHServer.start()
    let root = directory.appendingPathComponent("transfers")
    let source = directory.appendingPathComponent("source.bin")
    let bytes = Data("retained-source".utf8)
    try bytes.write(to: source)
    var host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username
    )
    #expect(try model.save(host))
    let original = host
    let first = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: root,
      connectSSH: { try await server.connect() }
    )
    var reopened: SFTPBrowserModel?
    do {
      await first.upload(from: source)
      let id = try #require(first.transfers.first?.id)
      await first.shutdown().value
      switch change {
      case "rename":
        host.nickname = "Renamed";
        #expect(try model.save(host))
      case "key":
        let identity = try await model.identityStore.generate(
          name: "New key",
          policy: .deviceOnly
        )
        host.auth = .key(identityID: identity.id)
        #expect(try model.save(host))
      case "accountReturn":
        await select("account-b", in: model)
        await select("account-a", in: model)
      case "endpointReturn":
        host.host = "different.local";
        #expect(try model.save(host))
        host = original;
        #expect(try model.save(host))
      default: break
      }
      let browser = SFTPBrowserModel(
        host: host,
        app: model,
        transferDirectory: root,
        connectSSH: { try await server.connect() }
      )
      reopened = browser
      #expect(browser.transfers.map(\.id) == [id])
      #expect(browser.recoverableTransfers.isEmpty)
      let item = try #require(browser.transfers.first)
      await browser.resume(item)
      try #require(
        await eventually { @MainActor in
          browser.transfers.first?.state == .completed
        }
      )
      #expect(try Data(contentsOf: server.url("/source.bin")) == bytes)
    } catch {
      await first.shutdown().value;
      await reopened?.shutdown().value
      await server.shutdown();
      throw error
    }
    await first.shutdown().value;
    await reopened?.shutdown().value
    await server.shutdown()
  }

  @Test(
    arguments: ["legacy", "localBinding"],
    ["upload", "download", "completedDownload"]
  )
  func oldTransfersRequireReviewBeforeRecovery(
    origin: String,
    direction: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    let server = try await TestSSHServer.start()
    let root = directory.appendingPathComponent("transfers")
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let source = root.appendingPathComponent("source.bin")
    let bytes = Data("older-source".utf8)
    try bytes.write(to: source)
    try bytes.write(to: server.url("/source.bin"))
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username
    )
    #expect(try model.save(host))
    let localOwner = HostDataOwner(model.connectionSelection(for: host))
    var manifest: TransferManifest
    if direction == "upload" {
      manifest = try await SFTPTransfers.prepareUpload(
        source: source,
        remotePath: "/new.bin",
        stagingDirectory: root.appendingPathComponent("staging"),
        overwriteExisting: true
      )
      manifest.acknowledgedOffset = 2
      manifest.state = .transferring
    } else {
      manifest = try SFTPTransfers.prepareDownload(
        remotePath: "/source.bin",
        temporaryDirectory: root,
        destination: root.appendingPathComponent("downloaded.bin"),
        overwriteExisting: true
      )
      if direction == "completedDownload" {
        try bytes.write(
          to: URL(fileURLWithPath: manifest.localDestinationPath!)
        )
        manifest.state = .completed
        manifest.sourceSize = UInt64(bytes.count)
        manifest.acknowledgedOffset = manifest.sourceSize
      } else {
        try bytes.prefix(2).write(to: URL(fileURLWithPath: manifest.localPath))
        manifest.sourceSize = UInt64(bytes.count)
        manifest.acknowledgedOffset = 2
      }
    }
    let store = TransferManifestStore(
      directory: root.appendingPathComponent("manifests"),
      owner: origin == "legacy" ? nil : localOwner
    )
    try store.save(manifest)
    await select("account-a", in: model)
    let browser = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: root,
      connectSSH: { try await server.connect() }
    )
    do {
      #expect(browser.transfers.isEmpty)
      let reviewed = try #require(browser.recoverableTransfers.first)
      #expect(reviewed.manifest == manifest)
      await browser.resume(.init(manifest: manifest, state: .paused("Old")))
      browser.export(.init(manifest: manifest, state: .completed))
      #expect(server.state.authRequests.withLock { $0 } == 0)
      #expect(browser.exportDocument == nil)
      let oldTemporary = manifest.remoteTemporaryPath
      if let oldTemporary {
        try Data("keep-old-remote".utf8).write(to: server.url(oldTemporary))
      }
      await browser.recover(reviewed)
      #expect(browser.recoverableTransfers.isEmpty)
      let recovered = try #require(browser.transfers.first)
      #expect(recovered.id == manifest.id)
      #expect(server.state.authRequests.withLock { $0 } == 0)
      if direction != "completedDownload" {
        #expect(recovered.manifest.acknowledgedOffset == 0)
        #expect(!recovered.manifest.overwriteExisting)
        #expect(recovered.manifest.localPath != manifest.localPath)
        if direction == "upload" {
          #expect(recovered.manifest.remoteTemporaryPath != oldTemporary)
        }
        await browser.resume(recovered)
        try #require(
          await eventually { @MainActor in
            browser.transfers.first?.state == .completed
          }
        )
      } else {
        browser.export(recovered)
        let document = try #require(browser.exportDocument)
        #expect(try Data(contentsOf: document.url) == bytes)
      }
      if let oldTemporary {
        #expect(
          try Data(contentsOf: server.url(oldTemporary))
            == Data("keep-old-remote".utf8)
        )
      }
      let final = try #require(browser.transfers.first)
      if direction == "upload" {
        #expect(try Data(contentsOf: server.url("/new.bin")) == bytes)
      } else {
        #expect(
          try Data(
            contentsOf: URL(
              fileURLWithPath: final.manifest.localDestinationPath!
            )
          ) == bytes
        )
      }
      await browser.shutdown().value
      let again = SFTPBrowserModel(
        host: host,
        app: model,
        transferDirectory: root
      )
      #expect(again.transfers.map(\.id) == [manifest.id])
      #expect(again.recoverableTransfers.isEmpty)
      await again.shutdown().value
    } catch {
      await browser.shutdown().value;
      await server.shutdown();
      throw error
    }
    await browser.shutdown().value;
    await server.shutdown()
  }

  @Test
  func bindingAnAccountCannotClaimAnActiveLocalTransfer() async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    let server = try await TestSSHServer.start()
    let source = directory.appendingPathComponent("source.bin")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Data("active-source".utf8).write(to: source)
    let root = directory.appendingPathComponent("transfers")
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: server.port,
      username: TestSSHServer.username
    )
    #expect(try model.save(host))
    let first = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: root,
      connectSSH: { try await server.connect() }
    )
    var second: SFTPBrowserModel?
    do {
      await first.connect()
      server.state.faults.withLock { $0.holdNextWriteResponse = true }
      await first.upload(from: source)
      try #require(
        await eventually { @MainActor in
          server.state.heldSFTPResponse.withLock { $0 != nil }
        }
      )
      let active = try #require(first.transfers.first)
      await select("account-a", in: model)
      let other = SFTPBrowserModel(
        host: host,
        app: model,
        transferDirectory: root
      )
      second = other
      let reviewed = try #require(other.recoverableTransfers.first)
      await other.recover(reviewed)
      #expect(other.transfers.isEmpty)
      #expect(other.recoverableTransfers.map(\.id) == [active.id])
      #expect(FileManager.default.fileExists(atPath: active.manifest.localPath))
      server.state.heldSFTPResponse.withLock { pending in
        pending?();
        pending = nil
      }
      try #require(
        await eventually { @MainActor in
          first.transfers.first?.state == .completed
        }
      )
      #expect(
        try Data(contentsOf: server.url("/source.bin"))
          == Data("active-source".utf8)
      )
      // A stale owner may not overwrite the checkpoint after it is explicitly assigned.
      await first.shutdown().value
      let fresh = SFTPBrowserModel(
        host: host,
        app: model,
        transferDirectory: root
      )
      let completed = try #require(fresh.recoverableTransfers.first)
      await fresh.recover(completed)
      #expect(fresh.transfers.first?.state == .completed)
      await other.recover(reviewed)
      #expect(other.transfers.isEmpty)
      await fresh.shutdown().value
    } catch {
      server.state.heldSFTPResponse.withLock { pending in
        pending?();
        pending = nil
      }
      await first.shutdown().value;
      await second?.shutdown().value
      await server.shutdown();
      throw error
    }
    await first.shutdown().value;
    await second?.shutdown().value
    await server.shutdown()
  }
  @Test(arguments: ["file", "directory", "symlink"])
  func removingADownloadPreservesItsNeighboursAndReplacedDirectories(
    kind: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let host = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(host))
    let root = directory.appendingPathComponent("transfers")
    let folder = root.appendingPathComponent("downloads")
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: folder,
      withIntermediateDirectories: true
    )
    let destination = folder.appendingPathComponent("download.bin")
    let neighbour = folder.appendingPathComponent("other-file.bin")
    let target = root.appendingPathComponent("link-target.bin")
    let bytes = Data("keep-other-file".utf8)
    try bytes.write(to: neighbour)
    try bytes.write(to: target)
    if kind == "directory" {
      try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: false
      )
      try bytes.write(to: destination.appendingPathComponent("nested.bin"))
    } else if kind == "symlink" {
      try FileManager.default.createSymbolicLink(
        at: destination,
        withDestinationURL: target
      )
    } else {
      try Data("download".utf8).write(to: destination)
    }
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/download.bin",
      temporaryDirectory: root,
      destination: destination
    )
    manifest.state = .completed
    let store = TransferManifestStore(
      directory: root.appendingPathComponent("manifests"),
      owner: HostDataOwner(model.connectionSelection(for: host))
    )
    try store.save(manifest)
    let browser = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: root
    )
    await browser.remove(try #require(browser.transfers.first))
    #expect(try Data(contentsOf: neighbour) == bytes)
    #expect(try Data(contentsOf: target) == bytes)
    if kind == "directory" {
      #expect(
        try Data(contentsOf: destination.appendingPathComponent("nested.bin"))
          == bytes
      )
    } else {
      #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
    #expect(store.loadAll().isEmpty)
    await browser.shutdown().value
  }

}
#endif
