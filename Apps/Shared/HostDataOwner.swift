import Foundation
import SSHClient

/// Durable ownership of saved workspaces and local transfer data. Credentials
/// can rotate without changing the remote user's data; names and revisions are
/// not owners.
struct HostDataOwner: Codable, Hashable, Sendable {
  let hostID: UUID
  let account: String?
  let hostname: String
  let port: Int
  let username: String

  init(_ selection: HostConnectionSelection) {
    self.init(host: selection.host, account: selection.context.scope)
  }

  init(host: HostProfile, account: String?) {
    hostID = host.id
    self.account = account
    hostname = HostIdentity(host: host.host, port: host.port)?.host ?? host.host
    port = host.port
    username = host.username
  }

  func hasSameEndpoint(as other: Self) -> Bool {
    hostID == other.hostID && hostname == other.hostname && port == other.port
      && username == other.username
  }
}
