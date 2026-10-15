/// Failures surfaced by `SSHConnection` and its channels. Descriptions
/// never contain credentials.
public enum SSHClientError: Error, Equatable, Sendable {
  /// The presented host key differs from the trusted key for this host
  /// identity. Fails closed and blocks automatic reconnection until the
  /// user explicitly replaces the trusted key.
  case hostKeyChanged(host: HostIdentity, expected: String, presented: String)
  /// An unknown host key was not approved by the trust decider.
  case hostKeyRejected(host: HostIdentity, fingerprint: String)
  /// The presented key is not one a confirmed pairing code named. Fails
  /// closed before the trust store or any credential is consulted.
  case hostKeyMismatch(host: HostIdentity, presented: String)
  /// The trust store could not be read or updated.
  case trustStoreUnavailable
  /// The server rejected every offered credential.
  case authenticationFailed
  case connectTimeout
  case execTimeout
  /// Remote session-channel acceptance or PTY/shell setup exceeded its deadline.
  case channelSetupTimeout
  case connectionClosed
  case invalidConfiguration(String)
  /// The server refused a channel or channel request.
  case channelRequestRejected(String)
  case outputLimitExceeded
  case writeTooLarge(Int)
  case invalidGridSize
  /// `runBootstrap` helper path is not an absolute, metacharacter-free
  /// path.
  case invalidHelperPath
  /// Bootstrap stdout was not exactly one valid envelope.
  case bootstrapProtocol(String)
  /// The helper exited without a response. `diagnostics` is bounded
  /// stderr text.
  case bootstrapFailed(exitStatus: Int?, diagnostics: String)

  /// Whether an automatic reconnect loop may retry after this error.
  /// Trust failures always require an explicit user decision.
  public var blocksAutomaticReconnect: Bool {
    switch self {
    case .hostKeyChanged, .hostKeyRejected, .hostKeyMismatch,
      .trustStoreUnavailable, .authenticationFailed, .invalidConfiguration,
      .invalidHelperPath:
      true
    default: false
    }
  }
}
