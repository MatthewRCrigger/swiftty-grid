import Crypto
import Foundation
import SSHClient

/// Why an imported private key was refused (spec.ssh-identity.md §6.2).
/// Messages name the problem only; they never echo file contents.
public enum OpenSSHImportError: Error, Hashable, Sendable {
  case inputTooLarge
  /// Not an armored `openssh-key-v1` private key.
  case unrecognizedFormat
  /// Another private-key format, such as PEM RSA or PKCS #8.
  case unsupportedFormat(String)
  /// A passphrase-protected OpenSSH key. V1 imports unencrypted keys only
  /// and adds no bcrypt compatibility.
  case encryptedKeyUnsupported
  case publicKeyOnly
  case certificate
  case malformed
  case unsupportedKeyCount(Int)
  case unsupportedAlgorithm(String)
  case commentTooLarge
  case invalidPadding
  /// Public and private halves disagree.
  case keyMismatch
  case cancelled

  public var message: String {
    switch self {
    case .inputTooLarge: "The file is larger than 64 KB."
    case .unrecognizedFormat: "This is not an OpenSSH private key."
    case .unsupportedFormat(let name):
      "\(name) keys are not supported. Import an OpenSSH Ed25519 key, or "
        + "generate one here."
    case .encryptedKeyUnsupported:
      "Passphrase-protected keys are not supported. Remove the passphrase "
        + "from a copy with ssh-keygen -p, import that copy, then delete it."
    case .publicKeyOnly:
      "This is a public key. Import the matching private key file."
    case .certificate: "SSH certificates are not supported."
    case .malformed: "The key file is damaged or incomplete."
    case .unsupportedKeyCount(let count):
      "The file holds \(count) keys; import one key at a time."
    case .unsupportedAlgorithm(let name):
      "\(name) keys are not supported; only Ed25519 keys can be imported."
    case .commentTooLarge: "The key's comment is larger than 1 KB."
    case .invalidPadding: "The key file's padding is invalid."
    case .keyMismatch: "The key's public and private halves do not match."
    case .cancelled: "Import cancelled."
    }
  }
}

/// What a key file holds, shown so the user can confirm the algorithm and
/// fingerprint before anything is saved.
public struct OpenSSHKeyInspection: Hashable, Sendable {
  public let algorithm: String
  public let fingerprint: String
  public let comment: String?
}

/// A decoded key, normalized for Keychain storage.
public struct ImportedOpenSSHKey: Sendable {
  public let secret: IdentitySecret
  /// The file's comment, a suggested display name.
  public let comment: String?

  public var fingerprint: String {
    SSHEd25519Key.fingerprint(of: secret.publicKey)
  }

  public var inspection: OpenSSHKeyInspection {
    OpenSSHKeyInspection(
      algorithm: SSHIdentityMetadata.algorithm,
      fingerprint: fingerprint,
      comment: comment
    )
  }
}

/// Bounded import of one unencrypted `openssh-key-v1` Ed25519 key (§6.2).
/// Every length is checked before allocation and the input must be
/// consumed exactly. Encrypted keys are recognized and refused.
public enum OpenSSHKeyImporter {
  public static let maxInputBytes = 64 * 1024
  public static let maxCommentBytes = 1024

  static let magic = Array("openssh-key-v1".utf8) + [0]
  static let beginArmor = "-----BEGIN OPENSSH PRIVATE KEY-----"
  static let endArmor = "-----END OPENSSH PRIVATE KEY-----"
  /// The unencrypted private section is padded to this block size.
  static let blockSize = 8

  /// Decodes synchronously on the caller's thread. Prefer
  /// `OpenSSHImportGate`, which runs off the main actor with bounded
  /// concurrency.
  public static func decode(
    _ input: Data
  ) throws(OpenSSHImportError) -> ImportedOpenSSHKey {
    var bytes = try unarmor(input)
    defer { bytes.resetBytes() }
    guard bytes.count > magic.count, Array(bytes[..<magic.count]) == magic
    else { throw .malformed }
    var reader = SSHWireReader(Array(bytes[magic.count...]))
    defer { reader.reset() }
    guard let cipher = reader.readText(maxLength: 64),
      let kdf = reader.readText(maxLength: 64),
      let kdfOptions = reader.readString(maxLength: 4096)
    else { throw .malformed }
    // Any cipher or KDF means a passphrase-protected key.
    guard cipher == "none", kdf == "none" else {
      throw .encryptedKeyUnsupported
    }
    guard kdfOptions.isEmpty else { throw .malformed }
    guard let count = reader.readUInt32() else { throw .malformed }
    guard count == 1 else {
      throw count == 0 ? .malformed : .unsupportedKeyCount(Int(count))
    }
    guard let blob = reader.readString(maxLength: 1024) else {
      throw .malformed
    }
    let publicKey = try ed25519PublicKey(blob: blob)
    guard var section = reader.readString(maxLength: maxInputBytes),
      reader.isAtEnd
    else { throw .malformed }
    defer { section.resetBytes() }
    guard !section.isEmpty, section.count % blockSize == 0 else {
      throw .invalidPadding
    }
    return try parsePrivateSection(section, publicKey: publicKey)
  }

  // MARK: Armor

  static func unarmor(_ input: Data) throws(OpenSSHImportError) -> [UInt8] {
    guard input.count <= maxInputBytes else { throw .inputTooLarge }
    guard let text = String(data: input, encoding: .utf8) else {
      throw .unrecognizedFormat
    }
    let lines = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard let first = lines.first else { throw .unrecognizedFormat }
    if first != beginArmor {
      throw classifyForeign(first: first, lineCount: lines.count)
    }
    guard lines.count >= 3, lines.last == endArmor,
      lines.dropFirst().dropLast().allSatisfy({ !$0.hasPrefix("-----") })
    else { throw .malformed }
    let body = lines.dropFirst().dropLast().joined()
    guard let data = Data(base64Encoded: body) else { throw .malformed }
    return Array(data)
  }

  private static func classifyForeign(
    first: String,
    lineCount: Int
  ) -> OpenSSHImportError {
    switch first {
    case "-----BEGIN RSA PRIVATE KEY-----": return .unsupportedFormat("PEM RSA")
    case "-----BEGIN EC PRIVATE KEY-----": return .unsupportedFormat("PEM EC")
    case "-----BEGIN DSA PRIVATE KEY-----": return .unsupportedFormat("PEM DSA")
    case "-----BEGIN PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----":
      return .unsupportedFormat("PKCS #8")
    case "---- BEGIN SSH2 PUBLIC KEY ----": return .publicKeyOnly
    default: break
    }
    let type = first.split(separator: " ").first.map(String.init) ?? ""
    if lineCount == 1, type.hasSuffix("-cert-v01@openssh.com") {
      return .certificate
    }
    if lineCount == 1,
      type.hasPrefix("ssh-") || type.hasPrefix("ecdsa-")
        || type.hasPrefix("sk-")
    {
      return .publicKeyOnly
    }
    return .unrecognizedFormat
  }

  private static func ed25519PublicKey(
    blob: [UInt8]
  ) throws(OpenSSHImportError) -> Curve25519.Signing.PublicKey {
    var reader = SSHWireReader(blob)
    guard let type = reader.readText(maxLength: 128) else { throw .malformed }
    guard type == SSHIdentityMetadata.algorithm else {
      throw type.contains("-cert-") ? .certificate : .unsupportedAlgorithm(type)
    }
    guard let key = SSHIdentityMetadata.ed25519Key(blob: blob) else {
      throw .malformed
    }
    return key
  }

  // MARK: Private section

  static func parsePrivateSection(
    _ plain: [UInt8],
    publicKey: Curve25519.Signing.PublicKey
  ) throws(OpenSSHImportError) -> ImportedOpenSSHKey {
    var reader = SSHWireReader(plain)
    defer { reader.reset() }
    guard let check1 = reader.readUInt32(), let check2 = reader.readUInt32(),
      check1 == check2
    else { throw .malformed }
    guard let type = reader.readText(maxLength: 128) else { throw .malformed }
    guard type == SSHIdentityMetadata.algorithm else {
      throw .unsupportedAlgorithm(type)
    }
    guard let publicBytes = reader.readString(maxLength: 32),
      publicBytes.count == 32,
      var privateBytes = reader.readString(maxLength: 64),
      privateBytes.count == 64
    else { throw .malformed }
    defer { privateBytes.resetBytes() }
    guard let commentLength = reader.peekLength() else { throw .malformed }
    guard commentLength <= maxCommentBytes else { throw .commentTooLarge }
    guard let commentBytes = reader.readString(maxLength: maxCommentBytes)
    else { throw .malformed }
    let padding = reader.readRest()
    guard padding.count < blockSize,
      padding.enumerated().allSatisfy({ $0.element == UInt8($0.offset + 1) })
    else { throw .invalidPadding }
    let key: Curve25519.Signing.PrivateKey
    do {
      key = try Curve25519.Signing.PrivateKey(
        rawRepresentation: privateBytes[..<32]
      )
    } catch { throw .malformed }
    let derived = Array(key.publicKey.rawRepresentation)
    guard publicBytes == derived, Array(privateBytes[32...]) == derived,
      Array(publicKey.rawRepresentation) == derived
    else { throw .keyMismatch }
    let comment = String(bytes: commentBytes, encoding: .utf8)
    return ImportedOpenSSHKey(
      secret: IdentitySecret(key),
      comment: comment?.isEmpty == false ? comment : nil
    )
  }
}

/// Runs imports off the main actor, one at a time (§6.2). A cancelled
/// import reports `.cancelled` and its result is discarded, so nothing is
/// persisted from it.
public actor OpenSSHImportGate {
  public static let shared = OpenSSHImportGate()

  public init() {}

  public func decode(
    _ input: Data
  ) throws(OpenSSHImportError) -> ImportedOpenSSHKey {
    guard !Task.isCancelled else { throw .cancelled }
    let key = try OpenSSHKeyImporter.decode(input)
    guard !Task.isCancelled else { throw .cancelled }
    return key
  }
}

extension SSHWireReader {
  /// A UTF-8 string field.
  mutating func readText(maxLength: Int) -> String? {
    let start = offset
    guard let bytes = readString(maxLength: maxLength),
      let text = String(bytes: bytes, encoding: .utf8)
    else {
      rewind(to: start)
      return nil
    }
    return text
  }

  /// The next string's declared length, without consuming it.
  func peekLength() -> Int? {
    var copy = self
    return copy.readUInt32().map(Int.init)
  }
}

extension Array where Element == UInt8 {
  /// Best-effort clearing of an owned buffer; not a guarantee that no other
  /// copy exists (§7.2).
  mutating func resetBytes() {
    withUnsafeMutableBytes {
      _ = memset_s($0.baseAddress, $0.count, 0, $0.count)
    }
  }
}
