import Foundation
@testable import RoamingApp
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: [false, true])
  func completedICloudKeysStayWithTheirAccountWhenMetadataSyncWasOff(
    enableMetadata: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    var model = app(secrets: secrets)
    let original = try await model.identityStore.generate(
      name: "A",
      policy: .iCloudKeychain
    )
    let local = try await model.identityStore.generate(
      name: "Local",
      policy: .deviceOnly
    )
    #expect(model.connections.intents.isEmpty)
    await defaultCloud.setAccount("account-b")
    model = app(secrets: secrets)
    await model.refreshConnections()
    if enableMetadata {
      try await #require(model.sync).setMetadataSync(true)
      await model.sync?.refresh()?.value
    }
    #expect(!model.identities.contains { $0.id == original.id })
    #expect(model.identities.contains { $0.id == local.id })
    #expect(
      await defaultCloud.records("account-b")
        .allSatisfy {
          $0.name != ConnectionSnapshot.identityRecord(original.id)
        }
    )
    await #expect(throws: IdentityResolutionError.unknownIdentity) {
      _ = try await model.identityStore.resolve(original.id)
    }
    await #expect(throws: IdentityOperationError.notFound) {
      try await model.identityStore.delete(original.id)
    }
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain) == [
        original.id
      ]
    )
    await defaultCloud.setAccount("acct-a")
    model.sync?.accountDidChange()
    await model.refreshConnections()
    #expect(model.identities.contains { $0.id == original.id })
    #expect(model.connections.identity(original.id)?.isDeleted == false)
  }

  @Test(arguments: ["delete", "withdraw", "copy", "repair"])
  func completedICloudMutationsRejectAnUnreportedAccountSwitch(
    operation: String
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = InMemoryIdentitySecretStore()
    let model = app(secrets: secrets)
    let original = try await model.identityStore.generate(
      name: "A",
      policy: .iCloudKeychain
    )
    let before = model.connections
    await defaultCloud.setAccount("account-b")
    await #expect(throws: IdentityOperationError.accountChanged) {
      switch operation {
      case "withdraw":
        _ = try await model.identityStore.withdrawFromICloud(
          original.id,
          name: "Copy",
          reassign: []
        )
      case "copy":
        _ = try await model.identityStore.createICloudCopy(
          of: original.id,
          name: "Copy",
          reassign: []
        )
      case "repair":
        // Account ownership must be checked before parsing any supplied file.
        try await model.identityStore.repair(original.id, with: Data())
      default: try await model.identityStore.delete(original.id)
      }
    }
    #expect(model.connections == before)
    #expect(
      try await secrets.storedIdentities(policy: .iCloudKeychain) == [
        original.id
      ]
    )
  }
}
