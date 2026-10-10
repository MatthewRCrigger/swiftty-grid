import AppleTransport
import ScreenProtocol

/// Connects to the endpoint in an SSH-delivered grant over QUIC, trusting
/// only the exact certificate the grant carries (spec §5.2).
public struct QUICGrantConnector: RSTConnector {
  public var connector: QUICRSTConnector

  public init(connector: QUICRSTConnector = QUICRSTConnector()) {
    self.connector = connector
  }

  public func connect(to grant: BootstrapGrant) async throws -> any RSTConnection {
    let pin = try CertificatePin(
      certificateDER: grant.serverCertificateDER,
      sha256: grant.serverCertificateSHA256
    )
    return try await connector.connect(
      host: grant.endpoint.host,
      port: grant.endpoint.port,
      pin: pin
    )
  }
}
