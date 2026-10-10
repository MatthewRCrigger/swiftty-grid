#if os(macOS)
import AppleTransport
import Foundation
import Network
import ScreenProtocol
import TerminalHost

struct IdentityMismatch: Error, CustomStringConvertible {
  var description: String { "host certificate fingerprint mismatch" }
}

// MARK: - Transport factory

/// Creates the QUIC/UDP listener bound to `config.bindAddress`:`port`
/// (ALPN `rst/1`, TLS 1.3, no 0-RTT) and the agent-owned TLS certificate it
/// presents. The certificate is independent of the SSH host key and is
/// delivered to clients only inside SSH-authenticated bootstrap grants.
///
/// This is the single place the network transport is constructed.
func makeTransport(
  config: HostConfiguration
) throws -> (any RSTListener, HostCertificate) {
  let advertised = config.advertisedHost
  let isAddress = IPv4Address(advertised) != nil || IPv6Address(advertised) != nil
  let identity = try AppleTransport.HostIdentity.loadOrCreate(
    directory: config.stateDirectoryURL.appendingPathComponent("tls"),
    hostnames: isAddress ? [] : [advertised],
    ipAddresses: isAddress ? [advertised] : []
  )
  let bindAll = config.bindAddress == "*" || config.bindAddress == "::"
    || config.bindAddress == "0.0.0.0"
  let listener = QUICRSTListener(
    identity: identity,
    configuration: QUICRSTListener.Configuration(
      host: bindAll ? nil : config.bindAddress,
      port: config.port
    )
  )
  guard
    let certificate = HostCertificate(
      der: identity.certificateDER,
      sha256Hex: identity.certificateSHA256
    )
  else { throw IdentityMismatch() }
  return (listener, certificate)
}
#endif
