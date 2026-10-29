import Foundation
@testable import RoamingApp
import SSHClient
import SSHIdentity
import Testing

@MainActor
struct ConnectionAccountCacheTests {
  private func host() -> HostProfile {
    HostProfile(nickname: "A", host: "a.local", username: "me", auth: .password)
  }

  @Test
  func aNewLocalTrustDecisionDoesNotOverwriteAnotherAccountsRecord() throws {
    var snapshot = ConnectionSnapshot()
    snapshot.settings.metadataSync = true
    snapshot.settings.trustSync = true
    ConnectionSyncCoordinator.bind(&snapshot, to: "a")
    let keyA = SSHEd25519Key.authorizedKeysLine(
      for: SSHEd25519Key.generate().publicKey
    )
    let keyB = SSHEd25519Key.authorizedKeysLine(
      for: SSHEd25519Key.generate().publicKey
    )
    func record(_ key: String, in snapshot: inout ConnectionSnapshot) {
      snapshot.recordLocalTrust(
        host: "same.local",
        port: 22,
        publicKey: key,
        fingerprint: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: key)!
      )
    }
    record(keyA, in: &snapshot)
    let name = ConnectionSnapshot.knownHostRecord(host: "same.local", port: 22)
    let originalEntry = snapshot.accounts["a"]?.outbox[name]
    snapshot.selectAccount("b")
    record(keyB, in: &snapshot)
    ConnectionSyncCoordinator.bind(&snapshot, to: "b")
    #expect(snapshot.knownHosts[name]?.publicKey == keyB)
    #expect(snapshot.scopes[name] == "b")
    #expect(snapshot.accounts["a"]?.outbox[name] == originalEntry)
    snapshot = try ConnectionStore.decode(ConnectionStore.encode(snapshot))
    snapshot.selectAccount("a")
    #expect(snapshot.knownHosts[name]?.publicKey == keyA)
    #expect(snapshot.scopes[name] == "a")
    snapshot.selectAccount("b")
    #expect(snapshot.knownHosts[name]?.publicKey == keyB)
  }

  @Test
  func accountSwitchRestoresProfileOrderAfterSeveralCollisions() throws {
    var snapshot = ConnectionSnapshot()
    snapshot.settings.metadataSync = true
    let profiles = (1 ... 3)
      .map { index in
        HostProfile(
          id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!,
          nickname: "A \(index)",
          host: "a.local",
          username: "me",
          auth: .password
        )
      }
    for profile in profiles { snapshot.upsertHost(profile) }
    ConnectionSyncCoordinator.bind(&snapshot, to: "a")
    snapshot.selectAccount(nil)
    ConnectionSyncCoordinator.bind(&snapshot, to: "b")
    for profile in profiles {
      let name = ConnectionSnapshot.hostRecord(profile.id)
      snapshot.activateRecord(name, for: "b")
      var other = profile
      other.nickname = "B"
      snapshot.upsertHost(other)
    }
    snapshot = try ConnectionStore.decode(ConnectionStore.encode(snapshot))
    snapshot.selectAccount("a")
    #expect(snapshot.visibleHosts == profiles)
  }

  @Test
  func versionTwoLoadsAndNextWritePreservesAccountCaches() throws {
    var original = ConnectionSnapshot()
    original.upsertHost(host())
    original.settings.metadataSync = true
    ConnectionSyncCoordinator.bind(&original, to: "account-a")
    var json = try #require(
      JSONSerialization.jsonObject(with: ConnectionStore.encode(original))
        as? [String: Any]
    )
    json["version"] = 2
    var migrated = try ConnectionStore.decode(
      JSONSerialization.data(withJSONObject: json)
    )
    #expect(migrated.version == ConnectionSnapshot.version)
    #expect(migrated.hosts == original.hosts)
    #expect(migrated.accounts == original.accounts)
    let name = ConnectionSnapshot.hostRecord(original.hosts[0].id)
    migrated.activateRecord(name, for: "account-b")
    #expect(migrated.hosts.isEmpty)
    let encoded = try ConnectionStore.encode(migrated)
    #expect(ConnectionStore.version(of: encoded) == ConnectionSnapshot.version)
    var restored = try ConnectionStore.decode(encoded)
    restored.selectAccount("account-a")
    #expect(restored.hosts == original.hosts)
    #expect(
      restored.accounts["account-a"]?.outbox
        == original.accounts["account-a"]?.outbox
    )
  }

  @Test
  func tombstonesAndConflictsBelongToTheirAccount() throws {
    var snapshot = ConnectionSnapshot()
    let profile = host()
    let name = ConnectionSnapshot.hostRecord(profile.id)
    snapshot.upsertHost(profile)
    snapshot.selectAccount("a")
    snapshot.scopes[name] = "a"
    let revision = snapshot.tick()
    let conflict = HostConflict(remote: profile, remoteRevision: revision)
    snapshot.hostConflicts[profile.id] = conflict
    snapshot.activateRecord(name, for: "b")
    #expect(snapshot.hostConflicts.isEmpty)
    snapshot.scopes[name] = "b"
    let tombstone = HostTombstone(
      revision: revision,
      deletedAt: Date(timeIntervalSince1970: 100)
    )
    snapshot.hostTombstones[profile.id] = tombstone
    snapshot.selectAccount("a")
    #expect(snapshot.hosts == [profile])
    #expect(snapshot.hostConflicts[profile.id] == conflict)
    #expect(snapshot.hostTombstones.isEmpty)
    snapshot = try ConnectionStore.decode(ConnectionStore.encode(snapshot))
    snapshot.selectAccount("b")
    #expect(snapshot.hosts.isEmpty)
    #expect(snapshot.hostConflicts.isEmpty)
    #expect(snapshot.hostTombstones[profile.id] == tombstone)
    #expect(snapshot.hiddenCount == 1)
  }

  @Test
  func identityTombstonesAndIntegrityConflictsStayWithTheirAccount() throws {
    var snapshot = ConnectionSnapshot()
    let metadata = SSHIdentityMetadata(
      name: "A",
      publicKey: SSHEd25519Key.generate().publicKey,
      storage: .deviceOnly,
      revision: snapshot.tick()
    )
    let name = ConnectionSnapshot.identityRecord(metadata.id)
    snapshot.insertIdentity(metadata)
    snapshot.scopes[name] = "a"
    snapshot.identityConflicts[metadata.id] = metadata
    snapshot.activateRecord(name, for: "b")
    #expect(snapshot.identityConflicts.isEmpty)
    var deleted = metadata
    deleted.name = "B"
    deleted.deletedAt = Date(timeIntervalSince1970: 100)
    snapshot.insertIdentity(deleted)
    snapshot.scopes[name] = "b"
    snapshot.selectAccount("a")
    #expect(snapshot.identity(metadata.id)?.isDeleted == false)
    #expect(snapshot.identityConflicts[metadata.id]?.name == "A")
    snapshot = try ConnectionStore.decode(ConnectionStore.encode(snapshot))
    snapshot.selectAccount("b")
    #expect(snapshot.identity(metadata.id)?.isDeleted == true)
    #expect(snapshot.identityConflicts.isEmpty)
    #expect(snapshot.hiddenCount == 1)
  }

  @Test
  func archivedProfilesStillCountAgainstTheStorageBound() throws {
    var snapshot = ConnectionSnapshot()
    for _ in 0 ..< ConnectionStore.maxHosts {
      let profile = host()
      snapshot.upsertHost(profile)
      let name = ConnectionSnapshot.hostRecord(profile.id)
      snapshot.scopes[name] = "a"
      snapshot.activateRecord(name, for: "b")
    }
    #expect(snapshot.hosts.isEmpty)
    #expect(snapshot.hiddenCount == ConnectionStore.maxHosts)
    _ = try ConnectionStore.encode(snapshot)
    snapshot.upsertHost(host())
    #expect(throws: ConnectionStore.StoreError.tooManyHosts) {
      _ = try ConnectionStore.encode(snapshot)
    }
  }

  @Test
  func anotherAccountsCachedValueCannotBeSentThroughAnOldOutboxEntry() {
    var snapshot = ConnectionSnapshot()
    let profile = host()
    snapshot.upsertHost(profile)
    let name = ConnectionSnapshot.hostRecord(profile.id)
    snapshot.scopes[name] = "b"
    let entry = OutboxEntry(
      recordName: name,
      revision: snapshot.hostRevisions[profile.id]!
    )
    #expect(
      ConnectionSyncCoordinator.record(for: entry, account: "a", in: snapshot)
        == nil
    )
  }
}
