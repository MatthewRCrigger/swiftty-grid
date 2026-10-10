import Crypto
import Foundation
import NIOCore
import NIOSSH
import Synchronization

/// The configured host identity and port that trust is scoped to
/// (spec §5.1). Never a resolved IP address unless the user configured
/// one.
public struct HostIdentity: Hashable, Sendable, Codable,
  CustomStringConvertible
{
  /// Lowercased configured host name or address literal.
  public let host: String
  public let port: Int

  /// Returns `nil` for an empty host, whitespace/control characters or a
  /// port outside 1...65535.
  public init?(host: String, port: Int) {
    let normalized = host.lowercased()
    guard !normalized.isEmpty, normalized.utf8.count <= 255,
      (1 ... 65535).contains(port),
      normalized.unicodeScalars.allSatisfy({
        $0.value > 0x20 && $0.value != 0x7F && !$0.properties.isWhitespace
      })
    else { return nil }
    self.host = normalized
    self.port = port
  }

  public var description: String {
    host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
  }
}

/// SSH public-key helpers shared by host trust and key export.
public enum SSHPublicKeyFormat {
  /// OpenSSH fingerprint `SHA256:<unpadded base64>` of the key blob in an
  /// `"<type> <base64>"` public-key line.
  public static func fingerprint(openSSHPublicKey line: String) -> String? {
    guard let blob = keyBlob(openSSHPublicKey: line) else { return nil }
    return fingerprint(blob: blob)
  }

  public static func fingerprint(blob: [UInt8]) -> String {
    let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
    var trimmed = Substring(digest)
    while trimmed.last == "=" { trimmed.removeLast() }
    return "SHA256:" + trimmed
  }

  static func keyBlob(openSSHPublicKey line: String) -> [UInt8]? {
    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2, let data = Data(base64Encoded: String(parts[1]))
    else { return nil }
    return Array(data)
  }

  static func openSSHLine(_ key: NIOSSHPublicKey) -> String {
    String(openSSHPublicKey: key)
  }

  /// Key algorithm name, such as `ssh-ed25519`.
  static func keyType(openSSHPublicKey line: String) -> String {
    String(line.split(separator: " ").first ?? "")
  }
}

/// Trusted SSH host public keys keyed by `HostIdentity`. Stores public
/// keys only.
public protocol HostTrustStore: Sendable {
  /// The trusted OpenSSH public-key line (`"<type> <base64>"`), if any.
  func trustedKey(for host: HostIdentity) async throws -> String?
  /// Records an explicitly approved key. Callers replace an existing key
  /// only after an explicit user decision.
  func setTrustedKey(_ openSSHPublicKey: String, for host: HostIdentity)
    async throws
  func removeTrustedKey(for host: HostIdentity) async throws
}

/// Volatile trust store for tests and "trust once" sessions.
public actor InMemoryHostTrustStore: HostTrustStore {
  private var keys: [HostIdentity: String]

  public init(keys: [HostIdentity: String] = [:]) { self.keys = keys }

  public func trustedKey(for host: HostIdentity) -> String? { keys[host] }

  public func setTrustedKey(_ openSSHPublicKey: String, for host: HostIdentity)
  {
    keys[host] = openSSHPublicKey
  }

  public func removeTrustedKey(for host: HostIdentity) {
    keys[host] = nil
  }
}

/// JSON-file trust store holding public keys only. Writes are atomic;
/// a corrupt or oversized file fails closed rather than being treated
/// as empty.
public actor FileHostTrustStore: HostTrustStore {
  public static let maxFileBytes = 1024 * 1024
  public static let maxEntries = 4096

  struct Entry: Codable, Hashable {
    var host: String
    var port: Int
    var publicKey: String
  }

  struct Contents: Codable {
    var version = 1
    var entries: [Entry] = []
  }

  public enum StoreError: Error, Equatable {
    case corrupt, tooLarge, tooManyEntries
  }

  public let fileURL: URL
  private var cache: [HostIdentity: String]?

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func trustedKey(for host: HostIdentity) throws -> String? {
    try load()[host]
  }

  public func setTrustedKey(_ openSSHPublicKey: String, for host: HostIdentity)
    throws
  {
    var keys = try load()
    keys[host] = openSSHPublicKey
    guard keys.count <= Self.maxEntries else { throw StoreError.tooManyEntries }
    try save(keys)
  }

  public func removeTrustedKey(for host: HostIdentity) throws {
    var keys = try load()
    keys[host] = nil
    try save(keys)
  }

  private func load() throws -> [HostIdentity: String] {
    if let cache { return cache }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      cache = [:]
      return [:]
    }
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fileURL.path
    )
    if let size = attributes[.size] as? Int, size > Self.maxFileBytes {
      throw StoreError.tooLarge
    }
    let data = try Data(contentsOf: fileURL)
    guard data.count <= Self.maxFileBytes else { throw StoreError.tooLarge }
    guard let contents = try? JSONDecoder().decode(Contents.self, from: data),
      contents.version == 1, contents.entries.count <= Self.maxEntries
    else { throw StoreError.corrupt }
    var keys: [HostIdentity: String] = [:]
    for entry in contents.entries {
      guard let id = HostIdentity(host: entry.host, port: entry.port),
        SSHPublicKeyFormat.keyBlob(openSSHPublicKey: entry.publicKey) != nil
      else { throw StoreError.corrupt }
      keys[id] = entry.publicKey
    }
    cache = keys
    return keys
  }

  private func save(_ keys: [HostIdentity: String]) throws {
    var contents = Contents()
    contents.entries = keys.map {
      Entry(host: $0.key.host, port: $0.key.port, publicKey: $0.value)
    }.sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(contents)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: fileURL, options: [.atomic])
    cache = keys
  }
}

/// Presented to the user when a host key is not yet trusted.
public struct HostTrustRequest: Sendable, Hashable {
  public let host: HostIdentity
  /// Key algorithm, e.g. `ssh-ed25519`.
  public let keyType: String
  /// OpenSSH `SHA256:<base64>` fingerprint.
  public let fingerprint: String
  /// The presented OpenSSH public-key line.
  public let publicKey: String
}

public enum HostTrustDecision: Sendable, Hashable {
  /// Trust and record the key in the store.
  case trustAndRemember
  /// Trust for this connection only.
  case trustOnce
  case reject
}

/// Explicit decision for an unknown host key. The connection waits for
/// the answer; nothing is sent to the server until it arrives.
public protocol HostTrustDecider: Sendable {
  func decide(_ request: HostTrustRequest) async -> HostTrustDecision
}

/// Decider backed by a closure.
public struct ClosureHostTrustDecider: HostTrustDecider {
  let body: @Sendable (HostTrustRequest) async -> HostTrustDecision
  public init(
    _ body: @escaping @Sendable (HostTrustRequest) async -> HostTrustDecision
  ) {
    self.body = body
  }
  public func decide(_ request: HostTrustRequest) async -> HostTrustDecision {
    await body(request)
  }
}

/// Rejects every unknown key; use for automatic reconnection, which must
/// never prompt.
public struct RejectUnknownHostKeys: HostTrustDecider {
  public init() {}
  public func decide(_ request: HostTrustRequest) async -> HostTrustDecision {
    .reject
  }
}

/// NIOSSH host-key callback: completes only after the store/decider
/// approve, so user authentication never starts for an untrusted key.
final class HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate,
  Sendable
{
  let host: HostIdentity
  let store: any HostTrustStore
  let decider: any HostTrustDecider
  /// The first trust failure, reported by `connect` instead of the
  /// generic NIO error.
  let failure = Mutex<SSHClientError?>(nil)
  /// Key accepted during this connection, so a rekey must present the
  /// same key.
  let accepted = Mutex<String?>(nil)

  init(
    host: HostIdentity,
    store: any HostTrustStore,
    decider: any HostTrustDecider
  ) {
    self.host = host
    self.store = store
    self.decider = decider
  }

  func validateHostKey(
    hostKey: NIOSSHPublicKey,
    validationCompletePromise: EventLoopPromise<Void>
  ) {
    let line = SSHPublicKeyFormat.openSSHLine(hostKey)
    if let previous = accepted.withLock({ $0 }) {
      if previous == line {
        validationCompletePromise.succeed()
      } else {
        fail(
          .hostKeyChanged(
            host: host,
            expected: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: previous)
              ?? "",
            presented: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: line)
              ?? ""
          ),
          validationCompletePromise
        )
      }
      return
    }
    Task { [self] in
      do {
        let result = try await evaluate(line)
        if let result {
          fail(result, validationCompletePromise)
        } else {
          accepted.withLock { $0 = line }
          validationCompletePromise.succeed()
        }
      } catch {
        fail(.trustStoreUnavailable, validationCompletePromise)
      }
    }
  }

  /// Returns the failure, or `nil` when the key is trusted.
  private func evaluate(_ line: String) async throws -> SSHClientError? {
    let presented = SSHPublicKeyFormat.fingerprint(openSSHPublicKey: line) ?? ""
    if let trusted = try await store.trustedKey(for: host) {
      guard trusted == line else {
        return .hostKeyChanged(
          host: host,
          expected: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: trusted)
            ?? "",
          presented: presented
        )
      }
      return nil
    }
    let request = HostTrustRequest(
      host: host,
      keyType: SSHPublicKeyFormat.keyType(openSSHPublicKey: line),
      fingerprint: presented,
      publicKey: line
    )
    switch await decider.decide(request) {
    case .trustAndRemember:
      // Re-check: a concurrent connection may have recorded another key.
      if let trusted = try await store.trustedKey(for: host), trusted != line {
        return .hostKeyChanged(
          host: host,
          expected: SSHPublicKeyFormat.fingerprint(openSSHPublicKey: trusted)
            ?? "",
          presented: presented
        )
      }
      try await store.setTrustedKey(line, for: host)
      return nil
    case .trustOnce:
      return nil
    case .reject:
      return .hostKeyRejected(host: host, fingerprint: presented)
    }
  }

  private func fail(_ error: SSHClientError, _ promise: EventLoopPromise<Void>)
  {
    failure.withLock { if $0 == nil { $0 = error } }
    promise.fail(error)
  }
}
