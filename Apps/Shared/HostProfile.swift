import Foundation

/// How a saved host authenticates. A *reference* only: secrets live in
/// the Keychain or are prompted for, never in a `HostProfile`.
public enum AuthMethodReference: Hashable, Sendable, Codable {
  /// Prompt for a password at connect time; nothing is stored here.
  case password
  /// An app-managed Ed25519 key stored in the Keychain under `label`.
  case keychainKey(label: String)

  public var summary: String {
    switch self {
    case .password: "Password"
    case .keychainKey(let label): "Key \u{201C}\(label)\u{201D}"
    }
  }
}

/// A saved SSH host: explicit host, port and username (spec §2), plus a
/// user-chosen nickname. Contains no passwords, private keys, tokens,
/// certificates or session identifiers.
public struct HostProfile: Hashable, Sendable, Codable, Identifiable {
  public enum ValidationError: Error, Hashable, Sendable {
    case emptyNickname
    case invalidHost
    case invalidPort
    case invalidUsername
    case invalidKeyLabel
  }

  public static let maxNicknameLength = 64
  public static let maxHostLength = 253
  public static let maxUsernameLength = 64
  public static let maxKeyLabelLength = 64

  public var id: UUID
  public var nickname: String
  public var host: String
  public var port: Int
  public var username: String
  public var auth: AuthMethodReference

  public init(
    id: UUID = UUID(),
    nickname: String,
    host: String,
    port: Int = 22,
    username: String,
    auth: AuthMethodReference = .password
  ) {
    self.id = id
    self.nickname = nickname
    self.host = host
    self.port = port
    self.username = username
    self.auth = auth
  }

  /// Checks every field. The host and username are passed to SSH as
  /// structured values, never interpolated into a shell command, but are
  /// still restricted to printable, whitespace-free text.
  public func validate() throws(ValidationError) {
    let name = nickname.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, name.count <= Self.maxNicknameLength,
      Self.isPrintable(name, allowSpaces: true)
    else { throw .emptyNickname }
    guard !host.isEmpty, host.utf8.count <= Self.maxHostLength,
      Self.isPrintable(host, allowSpaces: false), !host.hasPrefix("-")
    else { throw .invalidHost }
    guard (1...65_535).contains(port) else { throw .invalidPort }
    guard !username.isEmpty, username.utf8.count <= Self.maxUsernameLength,
      Self.isPrintable(username, allowSpaces: false), !username.hasPrefix("-")
    else { throw .invalidUsername }
    if case .keychainKey(let label) = auth {
      guard !label.isEmpty, label.count <= Self.maxKeyLabelLength,
        Self.isPrintable(label, allowSpaces: true)
      else { throw .invalidKeyLabel }
    }
  }

  public var isValid: Bool { (try? validate()) != nil }

  /// `user@host:port` for display.
  public var endpointSummary: String {
    let hostPart = host.contains(":") ? "[\(host)]" : host
    return port == 22 ? "\(username)@\(hostPart)" : "\(username)@\(hostPart):\(port)"
  }

  static func isPrintable(_ text: String, allowSpaces: Bool) -> Bool {
    text.unicodeScalars.allSatisfy { scalar in
      if scalar == " " { return allowSpaces }
      return !scalar.properties.isWhitespace
        && scalar.properties.generalCategory != .control
        && scalar.properties.generalCategory != .format
    }
  }
}
