#if os(macOS)
import AppleTransport
import Foundation
import Network
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization

/// The roaming transport of the SwiftMux service (spec.inbox.md §1, §7):
/// the pinned QUIC listener, the bootstrap control socket and the grant
/// registry, all inside the one service process that owns the panes.
/// `swifttyd bootstrap --stdio` (run by sshd) reaches it through the
/// control socket.
public final class RoamingHost: Sendable {
  public let registry: SessionRegistry
  private let control: ControlSocketServer
  private let listener: any RSTListener

  private init(
    registry: SessionRegistry,
    control: ControlSocketServer,
    listener: any RSTListener
  ) {
    self.registry = registry
    self.control = control
    self.listener = listener
  }

  /// Binds the listener first (grants advertise its actual port), then
  /// serves bootstrap requests and sweeps expired grants.
  public static func start(
    service: MuxService,
    configuration config: HostConfiguration,
    policy: RegistryPolicy = RegistryPolicy(),
    launch: @escaping @Sendable () -> LaunchSpec = RoamingHost.defaultLaunch
  ) async throws -> RoamingHost {
    try ControlDirectory.prepare(config.stateDirectoryURL)
    let (listener, certificate) = try makeTransport(config: config)
    let target = Mutex<SessionRegistry?>(nil)
    try await listener.start { connection in
      target.withLock { $0 }?.accept(connection)
    }
    let registry = SessionRegistry(
      service: service,
      identity: HostIdentity(
        endpoint: BootstrapEndpoint(
          host: config.advertisedHost,
          port: listener.port
        ),
        certificate: certificate
      ),
      policy: policy,
      launch: launch
    )
    target.withLock { $0 = registry }
    let bootstrap = BootstrapService(registry: registry)
    let control = try ControlSocketServer(
      directory: config.stateDirectoryURL
    ) { request in await bootstrap.respond(toEnvelope: request) }
    try control.start()
    registry.startSweeping()
    return RoamingHost(registry: registry, control: control, listener: listener)
  }

  /// A login shell with the agent's locale and search path; the shell's
  /// own startup files supply the rest.
  public static func defaultLaunch() -> LaunchSpec {
    let inherited = ProcessInfo.processInfo.environment
    var environment: [String: String] = [:]
    for key in ["PATH", "USER", "LOGNAME", "SHELL", "LANG", "TMPDIR"] {
      if let value = inherited[key] { environment[key] = value }
    }
    environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
    return LaunchSpec(environment: environment)
  }
}

struct IdentityMismatch: Error, CustomStringConvertible {
  var description: String { "host certificate fingerprint mismatch" }
}

/// Creates the QUIC/UDP listener bound to `config.bindAddress`:`port`
/// (ALPN `rst/1`, TLS 1.3, no 0-RTT) and the service-owned TLS
/// certificate it presents. The certificate is independent of the SSH
/// host key and reaches clients only inside SSH-authenticated grants.
func makeTransport(
  config: HostConfiguration
) throws -> (any RSTListener, HostCertificate) {
  let advertised = config.advertisedHost
  let isAddress =
    IPv4Address(advertised) != nil || IPv6Address(advertised) != nil
  let identity = try AppleTransport.HostIdentity.loadOrCreate(
    directory: config.stateDirectoryURL.appendingPathComponent("tls"),
    hostnames: isAddress ? [] : [advertised],
    ipAddresses: isAddress ? [advertised] : []
  )
  let bindAll =
    config.bindAddress == "*" || config.bindAddress == "::"
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
