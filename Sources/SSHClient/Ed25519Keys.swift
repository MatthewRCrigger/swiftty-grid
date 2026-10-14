import Crypto
import Foundation

#if canImport(Security)
import Security
#endif

/// App-managed Ed25519 client keys (spec §2, §5.3).
public enum SSHEd25519Key {
  /// A fresh key from the system CSPRNG.
  public static func generate() -> Curve25519.Signing.PrivateKey {
    Curve25519.Signing.PrivateKey()
  }

  /// OpenSSH `authorized_keys` line: `ssh-ed25519 <base64> [comment]`.
  /// Control characters and newlines in the comment are removed so the
  /// line cannot inject extra entries or options.
  public static func authorizedKeysLine(
    for key: Curve25519.Signing.PublicKey,
    comment: String? = nil
  ) -> String {
    let line = publicKeyLine(key)
    guard let comment else { return line }
    let cleaned = String(
      String.UnicodeScalarView(
        comment.unicodeScalars.filter {
          $0.value >= 0x20 && $0.value != 0x7F
            && !(0x80 ... 0x9F).contains($0.value)
        }
      )
    )
    .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? line : line + " " + cleaned
  }

  /// `ssh-ed25519 <base64 blob>` (RFC 8709: string "ssh-ed25519",
  /// string key).
  static func publicKeyLine(_ key: Curve25519.Signing.PublicKey) -> String {
    var blob = [UInt8]()
    func appendString(_ bytes: [UInt8]) {
      let n = UInt32(bytes.count)
      blob += [
        UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF),
        UInt8(n & 0xFF),
      ]
      blob += bytes
    }
    appendString(Array("ssh-ed25519".utf8))
    appendString(Array(key.rawRepresentation))
    return "ssh-ed25519 " + Data(blob).base64EncodedString()
  }

  /// OpenSSH `SHA256:` fingerprint of the public key.
  public static func fingerprint(of key: Curve25519.Signing.PublicKey) -> String
  { SSHPublicKeyFormat.fingerprint(openSSHPublicKey: publicKeyLine(key)) ?? "" }
}

/// Storage for app-managed Ed25519 private keys.
public protocol Ed25519KeyStore: Sendable {
  /// Loads or atomically creates one key for this label. Concurrent
  /// callers must receive the same stored identity.
  func loadOrCreateKey(
    label: String
  ) async throws -> Curve25519.Signing.PrivateKey
  func loadKey(label: String) async throws -> Curve25519.Signing.PrivateKey?
  func storeKey(
    _ key: Curve25519.Signing.PrivateKey,
    label: String
  ) async throws
  func deleteKey(label: String) async throws
}

/// Volatile key store for tests and previews.
public actor InMemoryEd25519KeyStore: Ed25519KeyStore {
  private var keys: [String: Data] = [:]

  public init() {}

  public func loadOrCreateKey(
    label: String
  ) throws -> Curve25519.Signing.PrivateKey {
    if let key = try loadKey(label: label) { return key }
    let key = SSHEd25519Key.generate()
    storeKey(key, label: label)
    return key
  }

  public func loadKey(label: String) throws -> Curve25519.Signing.PrivateKey? {
    try keys[label]
      .map { try Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
  }

  public func storeKey(_ key: Curve25519.Signing.PrivateKey, label: String) {
    keys[label] = key.rawRepresentation
  }

  public func deleteKey(label: String) { keys[label] = nil }
}

#if canImport(Security)
/// Keychain generic-password items, readable after first unlock on this
/// device only and never synchronized.
public actor KeychainEd25519KeyStore: Ed25519KeyStore {
  public enum KeychainError: Error, Equatable {
    case status(Int32)
    case malformedItem
  }

  public let service: String

  public init(service: String = "swiftty.ssh.ed25519") {
    self.service = service
  }

  private func baseQuery(label: String) -> [String: Any] {
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

  public func loadOrCreateKey(
    label: String
  ) throws -> Curve25519.Signing.PrivateKey {
    if let key = try loadKey(label: label) { return key }
    let key = SSHEd25519Key.generate()
    var query = baseQuery(label: label)
    query[kSecValueData as String] = key.rawRepresentation
    query[kSecAttrAccessible as String] =
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecSuccess { return key }
    // Another store or process may have created it after the lookup.
    // Read that identity instead of replacing it with our candidate.
    if status == errSecDuplicateItem, let existing = try loadKey(label: label) {
      return existing
    }
    throw KeychainError.status(status)
  }

  public func loadKey(label: String) throws -> Curve25519.Signing.PrivateKey? {
    var query = baseQuery(label: label)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError.status(status) }
    guard let data = result as? Data,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    else { throw KeychainError.malformedItem }
    return key
  }

  public func storeKey(
    _ key: Curve25519.Signing.PrivateKey,
    label: String
  ) throws {
    let query = baseQuery(label: label)
    let attributes: [String: Any] = [
      kSecValueData as String: key.rawRepresentation,
      kSecAttrAccessible as String:
        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(
      query as CFDictionary,
      attributes as CFDictionary
    )
    if status == errSecItemNotFound {
      var add = query
      add.merge(attributes) { $1 }
      status = SecItemAdd(add as CFDictionary, nil)
    }
    guard status == errSecSuccess else { throw KeychainError.status(status) }
  }

  public func deleteKey(label: String) throws {
    let status = SecItemDelete(baseQuery(label: label) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.status(status)
    }
  }
}
#endif
