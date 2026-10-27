import Foundation
@testable import RoamingApp
import SSHClient
import SSHIdentity
import Testing

struct ConnectionSnapshotBoundsTests {
  private func encoded(_ snapshot: ConnectionSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(snapshot)
  }

  @Test(arguments: [false, true])
  func identityReadLimitIncludesHiddenCachesButExcludesTombstones(
    cached: Bool
  ) throws {
    let key = SSHEd25519Key.generate().publicKey
    var snapshot = ConnectionSnapshot()
    var identities = (0 ... ConnectionStore.maxIdentities)
      .map { index in
        SSHIdentityMetadata(
          name: "Key \(index)",
          publicKey: key,
          storage: .deviceOnly,
          revision: LogicalRevision(counter: 0, deviceID: snapshot.deviceID)
        )
      }
    func install() {
      if cached {
        snapshot.identities = [identities[0]]
        snapshot.accounts["hidden", default: AccountPartition()].cachedRecords =
          Dictionary(
            uniqueKeysWithValues: identities.dropFirst()
              .map {
                (
                  ConnectionSnapshot.identityRecord($0.id),
                  .identity(metadata: $0, conflict: nil)
                )
              }
          )
      } else {
        snapshot.identities = identities
      }
    }
    identities[identities.count - 1].deletedAt = .now
    install()
    let valid = try ConnectionStore.decode(encoded(snapshot))
    #expect(
      valid.identities.count + valid.cachedIdentities.count == ConnectionStore
        .maxIdentities + 1
    )
    identities[identities.count - 1].deletedAt = nil
    install()
    #expect(throws: ConnectionStore.StoreError.tooManyIdentities) {
      _ = try ConnectionStore.decode(encoded(snapshot))
    }
  }

  @Test(arguments: [false, true])
  func trustReadLimitIncludesHiddenCachesButExcludesTombstones(
    cached: Bool
  ) throws {
    let key = SSHEd25519Key.authorizedKeysLine(
      for: SSHEd25519Key.generate().publicKey
    )
    let fingerprint = try #require(
      SSHPublicKeyFormat.fingerprint(openSSHPublicKey: key)
    )
    var snapshot = ConnectionSnapshot()
    var records = (0 ... ConnectionStore.maxTrustEntries)
      .map { index in
        KnownHostRecord(
          host: "host-\(index).local",
          port: 22,
          publicKey: key,
          fingerprint: fingerprint,
          provenance: .local,
          revision: LogicalRevision(counter: 0, deviceID: snapshot.deviceID)
        )
      }
    func install() {
      snapshot.knownHosts = [:]
      snapshot.accounts["hidden", default: AccountPartition()].cachedRecords =
        [:]
      for (index, record) in records.enumerated() {
        let name = ConnectionSnapshot.knownHostRecord(
          host: record.host,
          port: record.port
        )
        if cached && index > 0 {
          snapshot.accounts["hidden"]?.cachedRecords?[name] = .knownHost(
            record: record,
            incoming: nil,
            review: nil
          )
        } else {
          snapshot.knownHosts[name] = record
        }
      }
    }
    records[records.count - 1].deletedAt = .now
    install()
    let valid = try ConnectionStore.decode(encoded(snapshot))
    #expect(
      valid.knownHosts.count + valid.cachedKnownHosts.count == ConnectionStore
        .maxTrustEntries + 1
    )
    records[records.count - 1].deletedAt = nil
    install()
    #expect(throws: ConnectionStore.StoreError.tooManyTrustEntries) {
      _ = try ConnectionStore.decode(encoded(snapshot))
    }
  }
}
