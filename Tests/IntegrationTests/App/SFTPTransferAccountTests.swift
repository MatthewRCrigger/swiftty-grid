#if !os(tvOS)
import Foundation
@testable import RoamingApp
import SSHClient
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: ["account", "endpoint"], ["resume", "remove", "export"])
  func replacementBrowserCannotUseAnotherOwnersTransfers(
    change: String,
    operation: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let firstServer = try await TestSSHServer.start()
    let secondServer = try await TestSSHServer.start()
    let root = directory.appendingPathComponent("transfers")
    let source = directory.appendingPathComponent("private.bin")
    let bytes = Data("account-a-file".utf8)
    try bytes.write(to: source)
    let host = HostProfile(
      nickname: "A",
      host: "127.0.0.1",
      port: firstServer.port,
      username: TestSSHServer.username
    )
    #expect(try model.save(host))
    let first = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: root,
      connectSSH: { try await firstServer.connect() }
    )
    var second: SFTPBrowserModel?
    do {
      if operation == "export" {
        try bytes.write(to: firstServer.url("/private.bin"))
        await first.connect()
        first.download(
          .init(
            name: "private.bin",
            path: "/private.bin",
            isDirectory: false,
            size: UInt64(bytes.count)
          )
        )
        try #require(
          await eventually { @MainActor in
            first.transfers.first?.state == .completed
          }
        )
      } else {
        // Stage offline: its zero-byte checkpoint is ready for a future resume.
        await first.upload(from: source)
      }
      let item = try #require(first.transfers.first)
      await first.shutdown().value
      var replacement = host
      if change == "account" {
        await select("account-b", in: model)
        #expect(
          model.commitConnections {
            $0.activateRecord(
              ConnectionSnapshot.hostRecord(host.id),
              for: "account-b"
            )
            $0.upsertHost(replacement)
          }
        )
      } else {
        replacement.port = secondServer.port
        #expect(try model.save(replacement))
      }
      let target = change == "account" ? firstServer : secondServer
      let browser = SFTPBrowserModel(
        host: replacement,
        app: model,
        transferDirectory: root,
        connectSSH: { try await target.connect() }
      )
      second = browser
      #expect(browser.transfers.isEmpty)
      switch operation {
      case "resume":
        if let loaded = browser.transfers.first {
          await browser.resume(loaded)
          try #require(
            await eventually { @MainActor in
              browser.transfers.first?.state == .completed
            }
          )
        }
        #expect(
          !FileManager.default.fileExists(
            atPath: target.url("/private.bin").path
          )
        )
      case "remove":
        let temporary = try #require(item.manifest.remoteTemporaryPath)
        try Data("belongs-to-b".utf8).write(to: target.url(temporary))
        await browser.connect()
        await browser.remove(item)
        #expect(
          try Data(contentsOf: target.url(temporary))
            == Data("belongs-to-b".utf8)
        )
        #expect(FileManager.default.fileExists(atPath: item.manifest.localPath))
      default:
        browser.export(item)
        #expect(browser.exportDocument == nil)
        #expect(!browser.exporting)
      }
    } catch {
      await first.shutdown().value
      await second?.shutdown().value
      await firstServer.shutdown()
      await secondServer.shutdown()
      throw error
    }
    await first.shutdown().value
    await second?.shutdown().value
    await firstServer.shutdown()
    await secondServer.shutdown()
  }
}
#endif
