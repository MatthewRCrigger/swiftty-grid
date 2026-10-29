import Crypto
import Foundation

#if canImport(Security)
import Security
#endif

/// Read-and-retire access to version-1 label-addressed keys, for migration
/// only (§9). There is deliberately no create operation.
public protocol LegacyKeySource: Sendable {
  func read(label: String) async throws(IdentitySecretError) -> IdentitySecret
  /// Deleting an absent item succeeds.
  func delete(label: String) async throws(IdentitySecretError)
}

/// Volatile legacy keys for migration tests.
public actor InMemoryLegacyKeySource: LegacyKeySource {
  private var keys: [String: Curve25519.Signing.PrivateKey]
  public var failures: [IdentitySecretError] = []
  public private(set) var deleted: [String] = []

  public init(keys: [String: Curve25519.Signing.PrivateKey] = [:]) {
    self.keys = keys
  }

  public func inject(_ error: IdentitySecretError) { failures.append(error) }
  public func contains(_ label: String) -> Bool { keys[label] != nil }

  public func read(label: String) throws(IdentitySecretError) -> IdentitySecret
  {
    if !failures.isEmpty { throw failures.removeFirst() }
    guard let key = keys[label] else { throw .notFound }
    return IdentitySecret(key)
  }

  public func delete(label: String) throws(IdentitySecretError) {
    if !failures.isEmpty { throw failures.removeFirst() }
    keys[label] = nil
    deleted.append(label)
  }
}

#if canImport(Security)
/// The version-1 store: service `dev.chr33s.swiftty.ssh-key`, account the
/// exact label, never synchronizable, default (legacy) access scope. Reads
/// no other service and never Shell's access group.
public actor KeychainLegacyKeySource: LegacyKeySource {
  public static let legacyService = "dev.chr33s.swiftty.ssh-key"
  public let service: String

  public init(service: String = KeychainLegacyKeySource.legacyService) {
    self.service = service
  }

  private func query(label: String) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: label,
      kSecAttrSynchronizable as String: false,
    ]
    #if os(macOS)
    query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }

  public func read(label: String) throws(IdentitySecretError) -> IdentitySecret
  {
    var read = query(label: label)
    read[kSecReturnData as String] = true
    read[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(read as CFDictionary, &result)
    guard status == errSecSuccess else {
      throw KeychainIdentitySecretStore.error(status)
    }
    guard let data = result as? Data,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    else { throw .malformed }
    return IdentitySecret(key)
  }

  public func delete(label: String) throws(IdentitySecretError) {
    let status = SecItemDelete(query(label: label) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainIdentitySecretStore.error(status)
    }
  }
}
#endif
