import Crypto
import Foundation
import SSHClient
import TerminalSurface

/// Where the app keeps non-secret state: trusted host public keys,
/// transfer manifests and staged files. tvOS offers no durable local
/// storage, so it uses Caches there (spec §2.3).
enum RoamingStorage {
  static var directory: URL {
    if let override = UITesting.storageDirectory { return override }
    #if os(tvOS)
    let base = URL.cachesDirectory
    #else
    let base = URL.applicationSupportDirectory
    #endif
    return base.appending(path: "RoamingSSH", directoryHint: .isDirectory)
  }

  /// Trusted SSH host keys (public keys only).
  static var knownHostsURL: URL {
    directory.appending(path: "known_hosts.json", directoryHint: .notDirectory)
  }
}

/// Why an SSH connection for a saved host could not be made. Messages
/// carry no secrets.
enum SSHAccessError: Error, Equatable, Sendable {
  /// The user dismissed a password or trust prompt.
  case cancelled
  /// The Keychain key could not be read or created.
  case keyUnavailable
  /// The host presented a key different from the trusted one. Blocked
  /// until the user removes the old key deliberately (spec §5.1).
  case hostKeyChanged
  /// The user did not trust an unknown host key.
  case hostKeyRejected
  /// The presented (or already trusted) key is not one the confirmed
  /// pairing code named. Blocked before any credential was sent.
  case hostKeyMismatch
  case trustStoreUnavailable
  /// The server refused the credential. For key authentication this
  /// carries the `authorized_keys` line to install on the Mac.
  case authenticationFailed(publicKeyLine: String?)
  /// No SSH connection (network, DNS, timeout, refused).
  case unreachable

  var title: String {
    switch self {
    case .cancelled: "Sign-in cancelled"
    case .keyUnavailable: "Key unavailable"
    case .hostKeyChanged: "Host key changed"
    case .hostKeyRejected: "Host key not trusted"
    case .hostKeyMismatch: "Host key doesn't match the code"
    case .trustStoreUnavailable: "Trusted keys unavailable"
    case .authenticationFailed: "Authentication failed"
    case .unreachable: "Mac unreachable over SSH"
    }
  }

  var detail: String {
    switch self {
    case .cancelled: "No credentials were sent."
    case .keyUnavailable:
      "The Keychain key for this host could not be read or created."
    case .hostKeyChanged:
      "The key presented differs from the trusted key, so the connection was blocked. "
        + "Verify the Mac's key before removing the old one."
    case .hostKeyRejected:
      "The connection was closed before any credentials were sent."
    case .hostKeyMismatch:
      "The Mac's SSH key is not one listed in the connection code, so the "
        + "connection was blocked before any credentials were sent. Show the "
        + "code again on the intended Mac."
    case .trustStoreUnavailable:
      "The list of trusted host keys could not be read or written."
    case .authenticationFailed(let line?):
      "Add this public key to ~/.ssh/authorized_keys on the Mac:\n\(line)"
    case .authenticationFailed(nil): "The server rejected the credentials."
    case .unreachable:
      "Check that the Mac is reachable and Remote Login is enabled."
    }
  }
}

/// SSH connection services shared by the terminal, the ordinary-SSH
/// fallback and SFTP: host-key trust with explicit prompts, credentials
/// from memory or the Keychain, and connection setup.
///
/// Secrets stay in memory: passwords in `RoamingAppModel`, keys in the
/// Keychain. Nothing here logs or persists them.
@MainActor
final class SSHAccess {
  private weak var app: RoamingAppModel?
  let trustStore: FileHostTrustStore
  let keyStore = KeychainEd25519KeyStore(service: "dev.swiftty.roaming.ssh-key")

  init(app: RoamingAppModel, trustStore: FileHostTrustStore? = nil) {
    self.app = app
    self.trustStore =
      trustStore ?? FileHostTrustStore(fileURL: RoamingStorage.knownHostsURL)
  }

  /// `expectedHostKeys` are fingerprints from a confirmed pairing code;
  /// the server must present one of them.
  func configuration(
    for host: HostProfile,
    expectedHostKeys: Set<String>? = nil
  ) -> SSHClient.SSHClientConfiguration {
    SSHClient.SSHClientConfiguration(
      host: host.host,
      port: host.port,
      username: host.username,
      expectedHostKeyFingerprints: expectedHostKeys
    )
  }

  /// The credential for `host`: a password from memory or a prompt, or
  /// the Keychain key named by the profile (created on first use).
  func credential(
    for host: HostProfile,
    retry: Bool = false,
    rejectedPassword: String? = nil
  ) async throws(SSHAccessError) -> SSHCredential {
    switch host.auth {
    case .password:
      guard let app, let password = await app.password(
        for: host, retry: retry, rejectedPassword: rejectedPassword
      )
      else { throw .cancelled }
      return .password(password)
    case .keychainKey(let label):
      do {
        return .ed25519(try await keyStore.loadOrCreateKey(label: label))
      } catch { throw .keyUnavailable }
    }
  }

  /// The `authorized_keys` line for a key-authenticated host.
  func publicKeyLine(for host: HostProfile) async -> String? {
    guard case .keychainKey(let label) = host.auth,
      let key = try? await keyStore.loadOrCreateKey(label: label)
    else { return nil }
    return SSHEd25519Key.authorizedKeysLine(
      for: key.publicKey,
      comment: "roaming-ssh"
    )
  }

  /// A connection after host-key verification (prompting for an unknown
  /// key) and authentication. A rejected password is asked for once more.
  /// With `expectedHostKeys` (a confirmed pairing code), a presented or
  /// already trusted key outside that set blocks before any credential.
  func connect(
    _ host: HostProfile,
    interactive: Bool = true,
    expectedHostKeys: Set<String>? = nil
  ) async throws(SSHAccessError) -> SSHConnection {
    if !interactive, case .password = host.auth { throw .cancelled }
    try await settleTrust(
      for: host,
      interactive: interactive,
      expectedHostKeys: expectedHostKeys
    )
    var retry = false
    var rejectedPassword: String?
    while true {
      let credential = try await credential(
        for: host, retry: retry, rejectedPassword: rejectedPassword
      )
      do {
        return try await connect(
          host,
          credential: credential,
          interactive: interactive,
          expectedHostKeys: expectedHostKeys
        )
      } catch .authenticationFailed(let line) {
        guard case .password = host.auth, !retry else {
          throw .authenticationFailed(publicKeyLine: line)
        }
        retry = true
        if case let .password(password) = credential { rejectedPassword = password }
      }
    }
  }

  /// Settles an unknown host key before any credential is asked for, so
  /// the user never types a password for a server they have not trusted
  /// (spec §5.1). The probe connection offers no credential.
  private func settleTrust(
    for host: HostProfile,
    interactive: Bool,
    expectedHostKeys: Set<String>? = nil
  ) async throws(SSHAccessError) {
    guard let identity = configuration(for: host).hostIdentity else { return }
    let known: String?
    do { known = try await trustStore.trustedKey(for: identity) } catch {
      throw .trustStoreUnavailable
    }
    if let known {
      // A pairing code never replaces or overrides a trusted key: one that
      // the code does not name blocks without contacting the server.
      if let expectedHostKeys,
        !expectedHostKeys.contains(
          SSHPublicKeyFormat.fingerprint(openSSHPublicKey: known) ?? ""
        )
      {
        throw .hostKeyMismatch
      }
      // Without a code, a known key is checked during sign-in, before any
      // credential is offered. With one, the presented key is checked
      // against both the code and the store before a credential is even
      // asked for.
      guard expectedHostKeys != nil else { return }
    } else {
      guard interactive else { throw .hostKeyRejected }
    }
    do {
      _ = try await SSHConnection.verifyHostKey(
        configuration: configuration(
          for: host,
          expectedHostKeys: expectedHostKeys
        ),
        trustStore: trustStore,
        trustDecider: interactive
          ? trustDecider(for: host, matchesPairingCode: expectedHostKeys != nil)
          : RejectUnknownHostKeys() as any HostTrustDecider
      )
    } catch let error as SSHClientError {
      throw await map(error, host: host)
    } catch is CancellationError {
      throw .cancelled
    } catch { throw .unreachable }
  }

  /// Asks the user about an unknown key for `host`. With a pairing code,
  /// the verifier asks only after the key matched it.
  private func trustDecider(
    for host: HostProfile,
    matchesPairingCode: Bool = false
  ) -> ClosureHostTrustDecider {
    ClosureHostTrustDecider { [weak app] request in
      guard let app else { return .reject }
      let prompt = TrustPrompt(
        host: host,
        kind: .unknownKey,
        keyAlgorithm: request.keyType,
        fingerprint: request.fingerprint,
        matchesPairingCode: matchesPairingCode
      )
      return await app.requestTrust(prompt) == .trust
        ? .trustAndRemember : .reject
    }
  }

  /// Connects with `credential`, asking the user about an unknown key.
  func connect(
    _ host: HostProfile,
    credential: SSHCredential,
    interactive: Bool = true,
    expectedHostKeys: Set<String>? = nil
  ) async throws(SSHAccessError) -> SSHConnection {
    let decider: any HostTrustDecider =
      interactive
      ? trustDecider(for: host, matchesPairingCode: expectedHostKeys != nil)
      : RejectUnknownHostKeys()
    do {
      return try await SSHConnection.connect(
        configuration: configuration(
          for: host,
          expectedHostKeys: expectedHostKeys
        ),
        credential: credential,
        trustStore: trustStore,
        trustDecider: decider
      )
    } catch let error as SSHClientError {
      throw await map(error, host: host, interactive: interactive, credential: credential)
    } catch is CancellationError {
      throw .cancelled
    } catch { throw .unreachable }
  }

  /// The bootstrap endpoint for automatic roaming (re)connects. The host
  /// key must already be trusted: reconnects never prompt.
  func endpoint(for host: HostProfile, credential: SSHCredential) -> SSHEndpoint
  {
    SSHEndpoint(
      configuration: configuration(for: host),
      credential: credential,
      trustStore: trustStore,
      trustDecider: RejectUnknownHostKeys()
    )
  }

  private func map(
    _ error: SSHClientError,
    host: HostProfile,
    interactive: Bool = true,
    credential: SSHCredential? = nil
  ) async -> SSHAccessError {
    switch error {
    case let .hostKeyChanged(_, _, presented):
      // Shown, never accepted: a changed key always blocks.
      if interactive, let app {
        let prompt = TrustPrompt(
          host: host,
          kind: .changedKey,
          keyAlgorithm: "Presented key",
          fingerprint: presented
        )
        app.notifyChangedKey(prompt)
      }
      return .hostKeyChanged
    case .hostKeyRejected: return .hostKeyRejected
    case .hostKeyMismatch: return .hostKeyMismatch
    case .trustStoreUnavailable: return .trustStoreUnavailable
    case .authenticationFailed:
      if let credential, case let .password(password) = credential {
        app?.forgetRejectedPassword(password, for: host)
      }
      return .authenticationFailed(
        publicKeyLine: await publicKeyLine(for: host)
      )
    default: return .unreachable
    }
  }
}
