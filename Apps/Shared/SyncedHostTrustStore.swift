import Foundation
import SSHClient

/// Forwards to the file trust store and records each local decision in
/// the connection snapshot, so opt-in trust sync can publish it
/// (spec.ssh-identity.md §8.1). Trust semantics are unchanged: a changed
/// key still blocks, and nothing here replaces a pinned key.
actor SyncedHostTrustStore: HostTrustStore {
  let base: FileHostTrustStore
  private weak var app: RoamingAppModel?

  init(base: FileHostTrustStore, app: RoamingAppModel) {
    self.base = base
    self.app = app
  }

  func trustedKey(for host: HostIdentity) async throws -> String? {
    try await base.trustedKey(for: host)
  }

  func setTrustedKey(
    _ openSSHPublicKey: String,
    for host: HostIdentity
  ) async throws {
    try await base.setTrustedKey(openSSHPublicKey, for: host)
    await record(openSSHPublicKey, for: host)
  }

  func trustKeyIfAbsent(
    _ openSSHPublicKey: String,
    for host: HostIdentity
  ) async throws -> String {
    let stored = try await base.trustKeyIfAbsent(openSSHPublicKey, for: host)
    if stored == openSSHPublicKey { await record(stored, for: host) }
    return stored
  }

  func removeTrustedKey(for host: HostIdentity) async throws {
    try await base.removeTrustedKey(for: host)
    await MainActor.run { [weak app] in
      _ = app?
        .commitConnections {
          $0.recordLocalTrustRemoval(host: host.host, port: host.port)
        }
    }
  }

  private func record(_ key: String, for host: HostIdentity) async {
    let fingerprint =
      SSHPublicKeyFormat.fingerprint(openSSHPublicKey: key) ?? ""
    await MainActor.run { [weak app] in
      guard let app, app.connections.settings.trustSync else { return }
      _ = app.commitConnections {
        $0.recordLocalTrust(
          host: host.host,
          port: host.port,
          publicKey: key,
          fingerprint: fingerprint
        )
      }
    }
  }
}
