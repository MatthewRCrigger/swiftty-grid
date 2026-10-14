import AppleTransport
import ScreenProtocol

/// Connects to the endpoint in an SSH-delivered grant over QUIC, trusting
/// only the exact certificate the grant carries and, when present, its
/// SPKI pin (spec §5.2; spec.inbox.md §1.8). A mismatch fails the TLS
/// handshake, so the caller's `Attach` (carrying the token) is never sent.
public struct QUICGrantConnector: RSTConnector {
  public var connector: QUICRSTConnector

  public init(connector: QUICRSTConnector = QUICRSTConnector()) {
    self.connector = connector
  }

  public func connect(
    to grant: BootstrapGrant
  ) async throws -> any RSTConnection {
    let pin = try CertificatePin(
      certificateDER: grant.serverCertificateDER,
      sha256: grant.serverCertificateSHA256,
      spkiSHA256: grant.serverSPKISHA256
    )
    return try await connector.connect(
      host: grant.endpoint.host,
      port: grant.endpoint.port,
      pin: pin,
      limits: grant.limits
    )
  }
}
