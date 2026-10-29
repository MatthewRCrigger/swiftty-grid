import Foundation
@testable import RoamingApp
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  @Test(arguments: [false, true])
  func retainedHostDeletionCannotDeleteAnotherAccountsRecord(
    collision: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let original = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(original))
    await select("account-b", in: model)
    if collision {
      var replacement = original
      replacement.nickname = "B"
      replacement.host = "b.local"
      #expect(
        model.commitConnections {
          $0.activateRecord(
            ConnectionSnapshot.hostRecord(original.id),
            for: "account-b"
          )
          $0.upsertHost(replacement)
        }
      )
    }
    let before = model.connections
    model.delete(original)
    #expect(model.connections == before)
  }

  @Test(arguments: ["hidden", "cached", "deleted"])
  func directHostSaveCannotEditAnUnavailableRecord(state: String) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    var host = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(host))
    if state == "deleted" {
      model.delete(host)
    } else {
      await select("account-b", in: model)
      if state == "cached" {
        #expect(
          model.commitConnections {
            $0.activateRecord(
              ConnectionSnapshot.hostRecord(host.id),
              for: "account-b"
            )
          }
        )
      }
    }
    let before = model.connections
    host.nickname = "Stale edit"
    #expect(!(try model.save(host)))
    #expect(model.connections == before)
  }

  @Test(
    arguments: [
      "unchanged", "unrelated", "collision", "roundTrip", "revision",
      "conflict", "notification",
    ],
    [false, true]
  )
  func reviewedHostActionsRequireTheirOriginalContext(
    change: String,
    deletion: Bool
  ) async throws {
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = app(secrets: InMemoryIdentitySecretStore())
    await select("account-a", in: model)
    let host = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(host))
    let context = model.hostMutationContext(for: host)
    switch change {
    case "unrelated":
      #expect(
        try model.save(
          HostProfile(nickname: "Other", host: "other.local", username: "me")
        )
      )
    case "collision", "roundTrip":
      await select("account-b", in: model)
      if change == "collision" {
        // Even byte-identical profiles belong to different account records.
        #expect(
          model.commitConnections {
            $0.activateRecord(
              ConnectionSnapshot.hostRecord(host.id),
              for: "account-b"
            )
            $0.upsertHost(host)
          }
        )
      } else {
        await select("account-a", in: model)
      }
    case "revision":
      var edited = host
      edited.nickname = "Changed"
      #expect(try model.save(edited))
      #expect(try model.save(host))
    case "conflict":
      var remote = host
      remote.host = "remote.local"
      #expect(
        model.commitConnections {
          ConnectionSyncCoordinator.merge(
            .init(
              profile: remote,
              revision: .init(counter: 100, deviceID: UUID()),
              deletedAt: nil
            ),
            name: ConnectionSnapshot.hostRecord(host.id),
            account: "account-a",
            into: &$0
          )
        }
      )
      #expect(model.connections.hostRevisions[host.id] == context.revision)
      #expect(model.connections.hostConflicts[host.id] != nil)
    case "notification": model.identityStore.accountDidChange()
    default: break
    }
    let allowed = change == "unchanged" || change == "unrelated"
    let before = model.connections
    if deletion {
      model.delete(host, expecting: context)
      #expect((model.connections.hostTombstones[host.id] != nil) == allowed)
    } else {
      var edited = host
      edited.nickname = "Reviewed edit"
      #expect(try model.save(edited, expecting: context) == allowed)
      if allowed { #expect(model.hosts.contains(edited)) }
    }
    if !allowed { #expect(model.connections == before) }
  }
}

extension MainActorIntegrationTests.PairingTrustTests {
  @Test
  func pairingRejectsAStaleConfirmationBeforeStartingSSH() async throws {
    let f = try await fixture()
    #expect(
      f.app.commitConnections {
        ConnectionSyncCoordinator.bind(&$0, to: "account-a")
      }
    )
    let context = f.app.hostMutationContext(for: nil, id: f.host.id)
    #expect(
      f.app.commitConnections {
        ConnectionSyncCoordinator.bind(&$0, to: "account-b")
      }
    )
    await #expect(
      throws: PairingFailure.notSaved(RoamingAppModel.hostChangedMessage)
    ) {
      _ = try await f.app.pair(
        f.host,
        expectedHostKeys: [f.serverPrint],
        access: f.access,
        context: context
      )
    }
    #expect(f.app.pendingTrust == nil)
    #expect(f.app.pendingPassword == nil)
    #expect(f.server.state.authRequests.withLock { $0 } == 0)
    #expect(f.app.hosts.isEmpty)
    await finish(f)
  }

  @Test(arguments: [
    "unchanged", "existing", "account", "roundTrip", "revision", "arrival",
    "deleted", "conflict",
  ])
  func pairingRechecksTheReviewedRecordAfterAuthentication(
    change: String
  ) async throws {
    let f = try await fixture()
    do {
      #expect(
        f.app.commitConnections {
          $0.settings.metadataSync = true
          ConnectionSyncCoordinator.bind(&$0, to: "account-a")
        }
      )
      if ["revision", "deleted", "existing", "conflict"].contains(change) {
        #expect(try f.app.save(f.host))
      }
      var draft = f.host
      draft.nickname = "Confirmed profile"
      let confirmed = draft
      try await f.trust.setTrustedKey(
        f.server.hostKeyLine,
        for: f.server.identity
      )
      f.server.state.faults.withLock { $0.holdNextPasswordAuth = true }
      let pairing = Task {
        try await f.app.pair(
          confirmed,
          expectedHostKeys: [f.serverPrint],
          access: f.access
        )
      }
      defer { pairing.cancel() }
      try #require(try await eventually { f.app.pendingPassword != nil })
      f.app.resolvePassword(TestSSHServer.password)
      try #require(
        try await eventually {
          f.server.state.heldPasswordAuth.withLock { $0 != nil }
        }
      )
      switch change {
      case "account", "roundTrip":
        #expect(
          f.app.commitConnections {
            ConnectionSyncCoordinator.bind(&$0, to: "account-b")
          }
        )
        if change == "roundTrip" {
          #expect(
            f.app.commitConnections {
              ConnectionSyncCoordinator.bind(&$0, to: "account-a")
            }
          )
        }
      case "revision", "arrival":
        var remote = f.host
        remote.nickname = "Arriving metadata"
        #expect(try f.app.save(remote))
      case "conflict":
        var remote = f.host
        remote.host = "other.local"
        #expect(
          f.app.commitConnections {
            ConnectionSyncCoordinator.merge(
              .init(
                profile: remote,
                revision: .init(counter: 100, deviceID: UUID()),
                deletedAt: nil
              ),
              name: ConnectionSnapshot.hostRecord(remote.id),
              account: "account-a",
              into: &$0
            )
          }
        )
        #expect(f.app.connections.hostConflicts[f.host.id] != nil)
      case "deleted": f.app.delete(f.host)
      default: break
      }
      let before = f.app.connections
      let held = f.server.state.heldPasswordAuth.withLock { value in
        let held = value
        value = nil
        return held
      }
      try #require(held).succeed(.success)
      if change == "unchanged" || change == "existing" {
        #expect(try await pairing.value == confirmed)
        #expect(f.app.hosts == [confirmed])
      } else {
        await #expect(
          throws: PairingFailure.notSaved(RoamingAppModel.hostChangedMessage)
        ) { _ = try await pairing.value }
        #expect(f.app.connections == before)
      }
      #expect(f.app.activeSession == nil)
      #expect(f.server.state.bootstrapRequests.withLock { $0 }.isEmpty)
      #expect(
        try await eventually {
          f.server.state.connections.withLock { $0.channels.isEmpty }
        }
      )
    } catch {
      await finish(f)
      throw error
    }
    await finish(f)
  }

  @Test
  func pairingDoesNotSaveIntoAnAccountSelectedDuringSignIn() async throws {
    let f = try await fixture()
    #expect(
      f.app.commitConnections {
        ConnectionSyncCoordinator.bind(&$0, to: "account-a")
      }
    )
    let pairing = Task {
      try await f.app.pair(
        f.host,
        expectedHostKeys: [f.serverPrint],
        access: f.access
      )
    }
    try #require(try await eventually { f.app.pendingTrust != nil })
    f.app.resolveTrust(.trust)
    try #require(try await eventually { f.app.pendingPassword != nil })
    #expect(
      f.app.commitConnections {
        ConnectionSyncCoordinator.bind(&$0, to: "account-b")
      }
    )
    f.app.resolvePassword(TestSSHServer.password)
    let result = await pairing.result
    if case .success = result {
      Issue.record("Pairing saved under a different account")
    }
    #expect(f.app.hosts.isEmpty)
    #expect(f.app.connections.hosts.isEmpty)
    #expect(f.app.connections.accounts["account-b"]?.outbox.isEmpty != false)
    await finish(f)
  }
}
