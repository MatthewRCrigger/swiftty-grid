#if !os(tvOS)
import Foundation
@testable import RoamingApp
import SessionCore
import SSHClient
import SSHIdentity
import Testing

private actor TransferRecoveryGate {
  private var stage: String?
  private var arrival: CheckedContinuation<String, Never>?
  private var release: CheckedContinuation<Void, Never>?
  func hold(_ path: String) async {
    stage = path
    arrival?.resume(returning: path)
    arrival = nil
    await withCheckedContinuation { release = $0 }
  }
  func wait() async -> String {
    if let stage { return stage }
    return await withCheckedContinuation { arrival = $0 }
  }
  func resume() {
    release?.resume();
    release = nil
  }
}

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: ["unchanged", "account", "dismissed", "claimed"])
  func delayedTransferRecoveryCannotAdoptAnObsoleteReview(
    change: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let host = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(host))
    let root = directory.appendingPathComponent("transfers")
    let source = directory.appendingPathComponent("source.bin")
    try Data("older-source".utf8).write(to: source)
    let manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/source.bin",
      stagingDirectory: root.appendingPathComponent("staging")
    )
    let store = TransferManifestStore(
      directory: root.appendingPathComponent("manifests")
    )
    try store.save(manifest)
    let gate = TransferRecoveryGate()
    let browser = SFTPBrowserModel(
      host: host,
      app: model,
      transferDirectory: root,
      prepareUpload: { source, path, directory, overwrite in
        let prepared = try await SFTPTransfers.prepareUpload(
          source: source,
          remotePath: path,
          stagingDirectory: directory,
          overwriteExisting: overwrite
        )
        await gate.hold(prepared.localPath)
        // Deliberately returns even when its owner was cancelled.
        return prepared
      }
    )
    let reviewed = try #require(browser.recoverableTransfers.first)
    let pending = Task { await browser.recover(reviewed) }
    let staged = await gate.wait()
    var retirement: Task<Void, Never>?
    var claimant: SFTPBrowserModel?
    do {
      switch change {
      case "account": await select("account-b", in: model)
      case "dismissed": retirement = browser.shutdown()
      case "claimed":
        let other = SFTPBrowserModel(
          host: host,
          app: model,
          transferDirectory: root
        )
        claimant = other
        await other.recover(try #require(other.recoverableTransfers.first))
        #expect(other.transfers.map(\.id) == [manifest.id])
      default: break
      }
      await gate.resume()
      await pending.value
      await retirement?.value
      if change == "unchanged" {
        #expect(browser.transfers.map(\.id) == [manifest.id])
        #expect(FileManager.default.fileExists(atPath: staged))
        #expect(!FileManager.default.fileExists(atPath: manifest.localPath))
      } else {
        #expect(browser.transfers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staged))
        if change != "claimed" {
          #expect(store.loadAll() == [manifest])
          #expect(FileManager.default.fileExists(atPath: manifest.localPath))
        }
      }
    } catch {
      await gate.resume();
      await pending.value;
      await retirement?.value
      await browser.shutdown().value;
      await claimant?.shutdown().value
      throw error
    }
    await browser.shutdown().value;
    await claimant?.shutdown().value
  }
}
#endif
