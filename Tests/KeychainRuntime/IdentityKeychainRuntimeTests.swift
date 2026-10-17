import Foundation
import SSHClient
import SSHIdentity
import Security
import XCTest

/// spec.ssh-identity.md SEC-02 on a signed host: exact accessibility,
/// synchronization flags, service/account/group scoping and the
/// missing-entitlement failure, against the real data-protection Keychain.
final class IdentityKeychainRuntimeTests: XCTestCase {
  private var service = ""

  override func setUp() async throws {
    service = "swiftty.identity.runtime." + UUID().uuidString
  }

  override func tearDown() async throws {
    // Remove anything this test's unique service created, either policy.
    for sync in [false, true] {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrSynchronizable as String: sync,
      ]
      #if os(macOS)
      query[kSecUseDataProtectionKeychain as String] = true
      #endif
      SecItemDelete(query as CFDictionary)
    }
  }

  /// The app's default access group, as the Keychain reports it.
  private func defaultAccessGroup() async throws -> String {
    let probe = KeychainIdentitySecretStore(service: service, accessGroup: nil)
    let id = UUID()
    let attributes = try await attributes(
      of: probe,
      id: id,
      policy: .deviceOnly
    )
    try await probe.delete(id: id, policy: .deviceOnly)
    return try XCTUnwrap(attributes[kSecAttrAccessGroup as String] as? String)
  }

  private func attributes(
    of store: KeychainIdentitySecretStore,
    id: UUID,
    policy: IdentityStoragePolicy
  ) async throws -> [String: Any] {
    try await store.add(
      IdentitySecret(SSHEd25519Key.generate()),
      id: id,
      policy: policy
    )
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id.uuidString.lowercased(),
      kSecAttrSynchronizable as String: policy == .iCloudKeychain,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    #if os(macOS)
    query[kSecUseDataProtectionKeychain as String] = true
    #endif
    var result: CFTypeRef?
    XCTAssertEqual(
      SecItemCopyMatching(query as CFDictionary, &result),
      errSecSuccess
    )
    return try XCTUnwrap(result as? [String: Any])
  }

  func testPoliciesUseExactAttributesAndScoping() async throws {
    let group = try await defaultAccessGroup()
    let store = KeychainIdentitySecretStore(
      service: service,
      accessGroup: group
    )
    for (policy, accessible) in [
      (
        IdentityStoragePolicy.deviceOnly,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
      ), (.iCloudKeychain, kSecAttrAccessibleWhenUnlocked),
    ] {
      let id = UUID()
      let attributes = try await attributes(of: store, id: id, policy: policy)
      XCTAssertEqual(
        attributes[kSecAttrAccessible as String] as? String,
        accessible as String
      )
      XCTAssertEqual(
        (attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue,
        policy == .iCloudKeychain
      )
      XCTAssertEqual(
        attributes[kSecAttrAccessGroup as String] as? String,
        group
      )
      XCTAssertEqual(
        attributes[kSecAttrAccount as String] as? String,
        id.uuidString.lowercased()
      )
      // The other policy is a separate namespace.
      let other: IdentityStoragePolicy =
        policy == .deviceOnly ? .iCloudKeychain : .deviceOnly
      do {
        _ = try await store.read(id: id, policy: other)
        XCTFail("read across policies")
      } catch { XCTAssertEqual(error, .notFound) }
      let listed = try await store.storedIdentities(policy: policy)
      XCTAssertEqual(listed, [id])
      try await store.delete(id: id, policy: policy)
      do {
        _ = try await store.read(id: id, policy: policy)
        XCTFail("deleted item still readable")
      } catch { XCTAssertEqual(error, .notFound) }
    }
  }

  func testCreateNeverOverwrites() async throws {
    let store = KeychainIdentitySecretStore(service: service, accessGroup: nil)
    let id = UUID()
    let first = IdentitySecret(SSHEd25519Key.generate())
    try await store.add(first, id: id, policy: .deviceOnly)
    do {
      try await store.add(
        IdentitySecret(SSHEd25519Key.generate()),
        id: id,
        policy: .deviceOnly
      )
      XCTFail("duplicate add succeeded")
    } catch { XCTAssertEqual(error, .duplicate) }
    let kept = try await store.read(id: id, policy: .deviceOnly)
    XCTAssertEqual(
      kept.publicKey.rawRepresentation,
      first.publicKey.rawRepresentation
    )
  }

  func testAnUnentitledAccessGroupFailsDistinctly() async throws {
    let store = KeychainIdentitySecretStore(
      service: service,
      accessGroup: "ZZZZZZZZZZ.dev.example.not-entitled"
    )
    do {
      try await store.add(
        IdentitySecret(SSHEd25519Key.generate()),
        id: UUID(),
        policy: .deviceOnly
      )
      XCTFail("add to an unentitled group succeeded")
    } catch { XCTAssertEqual(error, .missingEntitlement) }
  }

  func testLegacyItemsAreReadAndRetiredButNeverCreated() async throws {
    let legacy = KeychainEd25519KeyStore(service: service)
    let key = SSHEd25519Key.generate()
    try await legacy.storeKey(key, label: "phone")
    let source = KeychainLegacyKeySource(service: service)
    let read = try await source.read(label: "phone")
    XCTAssertEqual(
      read.publicKey.rawRepresentation,
      key.publicKey.rawRepresentation
    )
    do {
      _ = try await source.read(label: "absent")
      XCTFail("absent legacy label was readable")
    } catch { XCTAssertEqual(error, .notFound) }
    try await source.delete(label: "phone")
    let gone = try await legacy.loadKey(label: "phone")
    XCTAssertNil(gone)
  }
}
