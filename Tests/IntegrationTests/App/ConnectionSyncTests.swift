import Foundation
@testable import RoamingApp
import SSHClient
@testable import SSHIdentity
import Testing

/// An in-memory private database with change tags and a change log, per
/// account (spec.ssh-identity.md §8).
actor FakeCloud: ConnectionCloudDatabase {
  struct Zone {
    var records: [String: (record: CloudRecord, tag: Int)] = [:]
    var log: [(seq: Int, name: String)] = []
    var seq = 0
  }

  var account: String? = "acct-a"
  var zones: [String: Zone] = [:]
  var fetchFailure: CloudSyncError?
  var saveFailure: CloudSyncError?
  /// Runs once, before the next save is applied.
  var beforeSave: (@Sendable () async -> Void)?
  private(set) var saveCount = 0

  func setAccount(_ value: String?) { account = value }
  func failNextFetch(_ error: CloudSyncError?) { fetchFailure = error }
  func failNextSave(_ error: CloudSyncError?) { saveFailure = error }
  func onNextSave(_ work: (@Sendable () async -> Void)?) { beforeSave = work }
  func records(_ account: String) -> [CloudRecord] {
    zones[account]?.records.values.map(\.record) ?? []
  }

  func accountID() throws(CloudSyncError) -> String {
    guard let account else { throw .accountRequired }
    return account
  }

  func createZone() throws(CloudSyncError) {
    let account = try accountID()
    if zones[account] == nil { zones[account] = Zone() }
  }

  func fetchChanges(
    since token: Data?
  ) throws(CloudSyncError) -> CloudChangePage {
    if let fetchFailure {
      self.fetchFailure = nil
      throw fetchFailure
    }
    let account = try accountID()
    guard let zone = zones[account] else { throw .zoneNotFound }
    let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
    let names = Set(zone.log.filter { $0.seq > since }.map(\.name))
    return CloudChangePage(
      changed: names.sorted().compactMap { zone.records[$0]?.record },
      deleted: [],
      token: Data(String(zone.seq).utf8),
      moreComing: false
    )
  }

  func save(
    _ records: [CloudRecord]
  ) async throws(CloudSyncError) -> [String: Result<
    CloudRecord, CloudSyncError
  >] {
    if let work = beforeSave {
      beforeSave = nil
      await work()
    }
    if let saveFailure {
      self.saveFailure = nil
      throw saveFailure
    }
    saveCount += 1
    let account = try accountID()
    guard var zone = zones[account] else { throw .zoneNotFound }
    var results: [String: Result<CloudRecord, CloudSyncError>] = [:]
    for record in records {
      let sentTag = record.systemFields.flatMap {
        Int(String(decoding: $0, as: UTF8.self))
      }
      if let existing = zone.records[record.name], sentTag != existing.tag {
        results[record.name] = .failure(.conflict(existing.record))
        continue
      }
      let tag = (zone.records[record.name]?.tag ?? 0) + 1
      var saved = record
      saved.systemFields = Data(String(tag).utf8)
      zone.seq += 1
      zone.records[record.name] = (saved, tag)
      zone.log.append((zone.seq, record.name))
      results[record.name] = .success(saved)
    }
    zones[account] = zone
    return results
  }
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct ConnectionSyncTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "sync-" + UUID().uuidString
    )

    func device(_ name: String, cloud: FakeCloud) -> RoamingAppModel {
      let model = RoamingAppModel(
        profile: .profile(for: .mobile),
        store: ConnectionStore(
          fileURL: root.appendingPathComponent(name)
            .appendingPathComponent("hosts.json")
        ),
        secrets: InMemoryIdentitySecretStore(),
        legacyKeys: InMemoryLegacyKeySource(),
        cloud: cloud
      )
      model.load()
      model.sync?.setActive(false)
      model.identityStore.verifyICloudAccount = { true }
      return model
    }

    func sync(_ model: RoamingAppModel) async {
      await model.sync?.refresh()?.value
    }

    func enable(_ models: RoamingAppModel...) async throws {
      for model in models {
        try await #require(model.sync).setMetadataSync(true)
        await sync(model)
      }
    }

    static func host(
      _ name: String,
      auth: AuthMethodReference = .password
    ) -> HostProfile {
      HostProfile(
        nickname: name,
        host: name.lowercased() + ".local",
        username: "me",
        auth: auth
      )
    }

    @Test
    func syncIsOffByDefaultAndUploadsNothing() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      #expect(try a.save(Self.host("Mac")))
      await sync(a)
      #expect(a.sync?.status == .off)
      #expect(await cloud.saveCount == 0)
    }

    // SYN-01
    @Test
    func profilesAndPublicMetadataSyncButDeviceOnlySecretsDoNot() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let key = try await a.identityStore.generate(
        name: "A's key",
        policy: .deviceOnly
      )
      #expect(try a.save(Self.host("Mac", auth: .key(identityID: key.id))))
      try await enable(a, b)
      #expect(b.hosts.map(\.nickname) == ["Mac"])
      #expect(b.identities.map(\.fingerprint) == [key.fingerprint])
      #expect(
        await b.identityStore.availability(key.id) == .unavailableOnThisDevice
      )
      await #expect(throws: IdentityResolutionError.unavailableOnThisDevice) {
        _ = try await b.identityStore.resolve(key.id)
      }
      // No private material in any cloud field.
      let secret = try await a.identityStore.resolve(key.id)
      let raw = secret.privateKey.rawRepresentation
      for record in await cloud.records("acct-a") {
        for value in record.fields.values {
          if case .bytes(let data) = value {
            #expect(data.range(of: raw) == nil)
          }
          if case .string(let text) = value {
            #expect(!text.contains(raw.base64EncodedString()))
          }
        }
      }
      if case .upToDate = a.sync?.status {
      } else {
        Issue.record("not up to date")
      }
    }

    // SYN-03
    @Test
    func anAcknowledgmentCannotDiscardANewerEdit() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      try await enable(a)
      var host = Self.host("Mac")
      #expect(try a.save(host))
      host.nickname = "Edited in flight"
      let edited = host
      await cloud.onNextSave { @Sendable in
        await MainActor.run { _ = try? a.save(edited) }
      }
      await sync(a)
      let account = try #require(a.connections.boundAccount)
      let name = ConnectionSnapshot.hostRecord(host.id)
      #expect(a.connections.accounts[account]?.outbox[name] != nil)
      await sync(a)
      #expect(a.connections.accounts[account]?.outbox[name] == nil)
      let stored = await cloud.records(account).first { $0.name == name }
      #expect(stored?.fields["nickname"] == .string("Edited in flight"))
    }

    // SYN-03, SYN-04: an offline edit survives process death; a failed
    // fetch does not advance the checkpoint or drop queued work.
    @Test
    func failuresKeepQueuedWorkAndCheckpoints() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      var a = device("a", cloud: cloud)
      try await enable(a)
      let account = try #require(a.connections.boundAccount)
      let token = a.connections.accounts[account]?.changeToken
      await cloud.failNextFetch(.networkUnavailable)
      #expect(try a.save(Self.host("Offline")))
      await sync(a)
      #expect(a.sync?.status == .offline)
      #expect(a.connections.accounts[account]?.changeToken == token)
      #expect(a.connections.accounts[account]?.outbox.count == 1)
      // Relaunch; the retry window is cleared for the test.
      a = device("a", cloud: cloud)
      #expect(a.commitConnections { $0.accounts[account]?.retryAt = nil })
      #expect(a.connections.accounts[account]?.outbox.count == 1)
      await cloud.failNextSave(.quotaExceeded)
      await sync(a)
      #expect(a.sync?.status == .error(CloudSyncError.quotaExceeded.message))
      #expect(a.connections.accounts[account]?.outbox.count == 1)
      await sync(a)
      #expect(a.connections.accounts[account]?.outbox.isEmpty == true)
    }

    // SYN-05
    @Test
    func renamesConvergeAndTupleConflictsNeedReview() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let original = Self.host("Mac")
      #expect(try a.save(original))
      try await enable(a, b)
      var renamedA = original
      renamedA.nickname = "From A"
      var renamedB = original
      renamedB.nickname = "From B"
      #expect(try a.save(renamedA))
      #expect(try b.save(renamedB))
      await sync(a)
      await sync(b)
      await sync(a)
      #expect(a.hosts.first?.nickname == b.hosts.first?.nickname)

      var movedA = try #require(a.hosts.first)
      movedA.host = "a-network.local"
      var movedB = try #require(b.hosts.first)
      movedB.host = "b-network.local"
      #expect(try a.save(movedA))
      #expect(try b.save(movedB))
      await sync(a)
      await sync(b)
      #expect(
        b.connections.hostConflicts[original.id]?.remote.host
          == "a-network.local"
      )
      #expect(b.hosts.first?.host == "b-network.local")
      b.sync?.resolveConflict(host: original.id, keepLocal: false)
      await sync(b)
      #expect(b.hosts.first?.host == "a-network.local")
      #expect(b.connections.hostConflicts.isEmpty)
    }

    /// The agreed base is what the server received: an edit made while a
    /// save was in flight still conflicts with a concurrent remote edit.
    @Test
    func anInFlightEditStillConflictsWithAConcurrentRemoteEdit() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let original = Self.host("Mac")
      #expect(try a.save(original))
      try await enable(a, b)
      var sent = original
      sent.host = "sent.local"
      var inFlight = original
      inFlight.host = "in-flight.local"
      let edit = inFlight
      #expect(try a.save(sent))
      await cloud.onNextSave { @Sendable in
        await MainActor.run { _ = try? a.save(edit) }
      }
      await sync(a)
      await sync(b)
      #expect(b.hosts.first?.host == "sent.local")
      var remote = try #require(b.hosts.first)
      remote.host = "remote.local"
      #expect(try b.save(remote))
      await sync(b)
      await sync(a)
      #expect(a.hosts.first?.host == "in-flight.local")
      #expect(
        a.connections.hostConflicts[original.id]?.remote.host == "remote.local"
      )
    }

    @Test
    func sameUUIDWithDifferentKeyMaterialIsQuarantined() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let key = try await a.identityStore.generate(
        name: "Key",
        policy: .deviceOnly
      )
      try await enable(a, b)
      let forged = SSHIdentityMetadata(
        id: key.id,
        name: "Forged",
        publicKey: SSHEd25519Key.generate().publicKey,
        storage: .deviceOnly,
        revision: LogicalRevision(counter: 999, deviceID: UUID())
      )
      _ = try await cloud.save([
        CloudRecord(
          name: ConnectionSnapshot.identityRecord(key.id),
          type: ConnectionRecords.identity,
          fields: ConnectionRecords.encode(identity: forged),
          systemFields: Data("1".utf8)
        )
      ])
      await sync(a)
      #expect(a.identity(key.id)?.publicKey == key.publicKey)
      #expect(a.connections.identityConflicts[key.id] != nil)
      await #expect(throws: IdentityResolutionError.integrityConflict) {
        _ = try await a.identityStore.resolve(key.id)
      }
    }

    // SYN-06
    @Test
    func aStaleDeviceCannotResurrectATombstone() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      let host = Self.host("Mac")
      #expect(try a.save(host))
      try await enable(a, b)
      a.delete(host)
      await sync(a)
      var stale = try #require(b.hosts.first)
      stale.nickname = "Stale edit"
      #expect(try b.save(stale))
      await sync(b)
      await sync(a)
      #expect(a.hosts.isEmpty)
      #expect(b.hosts.isEmpty)
      #expect(b.connections.hostTombstones[host.id] != nil)
      // Disabling sync keeps local data and deletes nothing remotely.
      try await #require(b.sync).setMetadataSync(false)
      #expect(await cloud.records("acct-a").count == 1)
    }

    // SYN-07
    @Test
    func anAccountSwitchQuarantinesThePreviousAccountsData() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      #expect(try a.save(Self.host("Synced")))
      try await enable(a)
      await cloud.setAccount("acct-b")
      a.sync?.accountDidChange()
      await sync(a)
      #expect(a.sync?.status == .accountChanged)
      #expect(a.hosts.isEmpty)
      #expect(a.connections.hiddenCount == 1)
      #expect(try a.save(Self.host("Local")))
      try await #require(a.sync).confirmCurrentAccount()
      await sync(a)
      let uploaded = await cloud.records("acct-b")
        .compactMap { $0.fields["nickname"] }
      #expect(uploaded == [.string("Local")])
      // Signing back in to the first account restores its data.
      await cloud.setAccount("acct-a")
      a.sync?.accountDidChange()
      await sync(a)
      #expect(a.hosts.map(\.nickname).contains("Synced"))
    }

    @Test
    func signingOutQuarantinesUntilTheSameAccountReturns() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      #expect(try a.save(Self.host("Synced")))
      try await enable(a)
      await cloud.setAccount(nil)
      a.sync?.accountDidChange()
      await sync(a)
      #expect(a.sync?.status == .accountRequired)
      #expect(a.hosts.isEmpty)
      await cloud.setAccount("acct-a")
      a.sync?.accountDidChange()
      await sync(a)
      #expect(a.hosts.map(\.nickname) == ["Synced"])
    }

    @Test
    func zoneLossNeedsExplicitRecovery() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      #expect(try a.save(Self.host("Mac")))
      try await enable(a)
      await cloud.failNextFetch(.zoneNotFound)
      await sync(a)
      #expect(a.sync?.status == .zoneRecoveryRequired)
      let saves = await cloud.saveCount
      await sync(a)
      #expect(await cloud.saveCount == saves)
      try await #require(a.sync).recoverZone()
      await sync(a)
      if case .upToDate = a.sync?.status {
      } else {
        Issue.record("not recovered")
      }
    }

    @Test
    func unsupportedAndMalformedRecordsAreKeptApart() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      try await enable(a)
      _ = try await cloud.save([
        CloudRecord(
          name: "future-1",
          type: "SwifttyFutureV9",
          fields: ["schema": .int(9)]
        ),
        CloudRecord(
          name: ConnectionSnapshot.hostRecord(UUID()),
          type: ConnectionRecords.host,
          fields: ["schema": .int(1)]
        ),
      ])
      await sync(a)
      let account = try #require(a.connections.boundAccount)
      #expect(a.connections.accounts[account]?.opaque["future-1"] != nil)
      #expect(a.connections.accounts[account]?.quarantine.count == 1)
      #expect(a.hosts.isEmpty)
    }

    // Known-host conflicts block rather than overwrite (§8.3).
    @Test
    func trustConflictsKeepTheLocalPin() async throws {
      defer { try? FileManager.default.removeItem(at: root) }
      let cloud = FakeCloud()
      let a = device("a", cloud: cloud)
      let b = device("b", cloud: cloud)
      try await enable(a, b)
      let endpoint = try #require(HostIdentity(host: "mac.local", port: 22))
      let keyA = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      let keyB = SSHEd25519Key.authorizedKeysLine(
        for: SSHEd25519Key.generate().publicKey
      )
      try await a.ssh.trustStore.setTrustedKey(keyA, for: endpoint)
      try await b.ssh.trustStore.setTrustedKey(keyB, for: endpoint)
      try #require(a.sync)
        .setTrustSync(true, trustedKeys: try await a.ssh.trustFile.entries())
      try #require(b.sync)
        .setTrustSync(true, trustedKeys: try await b.ssh.trustFile.entries())
      await sync(a)
      await sync(b)
      #expect(try await b.ssh.trustFile.trustedKey(for: endpoint) == keyB)
      #expect(b.connections.trustReviews.count == 1)

      // A third device with no pin adopts the delegated trust.
      let c = device("c", cloud: cloud)
      try await enable(c)
      try #require(c.sync).setTrustSync(true, trustedKeys: [:])
      await sync(c)
      let adopted = try await c.ssh.trustFile.trustedKey(for: endpoint)
      #expect(adopted == keyA || adopted == keyB)
    }
  }
}
