import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization

#if canImport(Network)
  import NIOTransportServices
#endif

/// Explicit host, port and username profile (spec §2). No OpenSSH
/// configuration is evaluated.
public struct SSHClientConfiguration: Hashable, Sendable, Codable {
  public var host: String
  public var port: Int
  public var username: String
  /// Bound on TCP connect plus key exchange and authentication.
  public var connectTimeout: Duration

  public init(
    host: String,
    port: Int = 22,
    username: String,
    connectTimeout: Duration = .seconds(20)
  ) {
    self.host = host
    self.port = port
    self.username = username
    self.connectTimeout = connectTimeout
  }

  /// Identity host trust is scoped to; `nil` if host or port is invalid.
  public var hostIdentity: HostIdentity? {
    HostIdentity(host: host, port: port)
  }

  var isValidUsername: Bool {
    !username.isEmpty && username.utf8.count <= 256
      && username.unicodeScalars.allSatisfy {
        $0.value >= 0x20 && $0.value != 0x7F
      }
  }
}

/// A user credential. Descriptions are redacted; never log the payload.
public enum SSHCredential: Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  case password(String)
  /// App-managed Ed25519 key (see `Ed25519KeyStore`).
  case ed25519(Curve25519.Signing.PrivateKey)

  public var description: String {
    switch self {
    case .password: "SSHCredential.password(<redacted>)"
    case .ed25519: "SSHCredential.ed25519(<redacted>)"
    }
  }
  public var debugDescription: String { description }
}

/// Offers the single configured credential once; a rejection ends
/// authentication.
final class CredentialOfferDelegate: NIOSSHClientUserAuthenticationDelegate,
  Sendable
{
  let username: String
  /// `nil` offers nothing: host-key verification only.
  let credential: SSHCredential?
  let offered = Mutex(false)
  let exhausted = Mutex(false)

  init(username: String, credential: SSHCredential?) {
    self.username = username
    self.credential = credential
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    let first = offered.withLock { wasOffered in
      defer { wasOffered = true }
      return !wasOffered
    }
    let offer: NIOSSHUserAuthenticationOffer.Offer? =
      switch credential {
      case let .password(password) where availableMethods.contains(.password):
        .password(.init(password: password))
      case let .ed25519(key) where availableMethods.contains(.publicKey):
        .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))
      default: nil
      }
    guard first, let offer else {
      exhausted.withLock { $0 = true }
      nextChallengePromise.fail(SSHClientError.authenticationFailed)
      return
    }
    nextChallengePromise.succeed(
      NIOSSHUserAuthenticationOffer(
        username: username,
        serviceName: "",
        offer: offer
      )
    )
  }
}

/// Completes the authentication promise and closes the connection on
/// any pipeline error. Runs on the connection's event loop.
final class ConnectionEventsHandler: ChannelInboundHandler {
  typealias InboundIn = Any

  private let authenticated: EventLoopPromise<Void>
  private var completed = false
  private var firstError: (any Error)?

  init(authenticated: EventLoopPromise<Void>) {
    self.authenticated = authenticated
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is UserAuthSuccessEvent, !completed {
      completed = true
      authenticated.succeed()
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if firstError == nil { firstError = error }
    context.close(promise: nil)
  }

  func handlerAdded(context: ChannelHandlerContext) {
    // NIOSSHHandler does not forward channelInactive, so observe the
    // close future instead.
    context.channel.closeFuture.assumeIsolated().whenComplete { _ in
      self.connectionClosed()
    }
  }

  private func connectionClosed() {
    if !completed {
      completed = true
      authenticated.fail(firstError ?? SSHClientError.connectionClosed)
    }
  }
}

/// An authenticated SSH connection. Channels (exec, shell, SFTP) are
/// multiplexed over it; closing it closes them all.
///
/// Thread-safe: every NIO object is touched only on its event loop.
public final class SSHConnection: Sendable {
  public let configuration: SSHClientConfiguration
  public let hostIdentity: HostIdentity
  /// OpenSSH `SHA256:` fingerprint of the verified host key.
  public let hostKeyFingerprint: String
  let channel: any Channel

  init(
    configuration: SSHClientConfiguration,
    hostIdentity: HostIdentity,
    hostKeyFingerprint: String,
    channel: any Channel
  ) {
    self.configuration = configuration
    self.hostIdentity = hostIdentity
    self.hostKeyFingerprint = hostKeyFingerprint
    self.channel = channel
  }

  /// The default client group: Network.framework on Apple platforms.
  public static var defaultEventLoopGroup: any EventLoopGroup {
    #if canImport(Network)
      NIOTSEventLoopGroup.singleton
    #else
      MultiThreadedEventLoopGroup.singleton
    #endif
  }

  /// Connects, verifies the host key against `trustStore` (asking
  /// `trustDecider` about unknown keys) and only then authenticates.
  ///
  /// - Throws: `SSHClientError.hostKeyChanged` for a mismatching key
  ///   (fails closed), `.hostKeyRejected`, `.authenticationFailed`,
  ///   `.connectTimeout`, or a transport error.
  public static func connect(
    configuration: SSHClientConfiguration,
    credential: SSHCredential,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider,
    eventLoopGroup: (any EventLoopGroup)? = nil
  ) async throws -> SSHConnection {
    let outcome = try await establish(
      configuration: configuration,
      credential: credential,
      trustStore: trustStore,
      trustDecider: trustDecider,
      eventLoopGroup: eventLoopGroup
    )
    guard case let .connected(connection) = outcome else {
      throw SSHClientError.connectionClosed
    }
    return connection
  }

  /// Connects and verifies the host key exactly as `connect` does
  /// (asking `trustDecider` about an unknown key), then disconnects
  /// without offering any credential. Lets a client settle trust before
  /// it asks the user for a password.
  ///
  /// - Returns: the verified key's OpenSSH `SHA256:` fingerprint.
  /// - Throws: the trust errors of `connect`, `.connectTimeout`, or a
  ///   transport error.
  public static func verifyHostKey(
    configuration: SSHClientConfiguration,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider,
    eventLoopGroup: (any EventLoopGroup)? = nil
  ) async throws -> String {
    let outcome = try await establish(
      configuration: configuration,
      credential: nil,
      trustStore: trustStore,
      trustDecider: trustDecider,
      eventLoopGroup: eventLoopGroup
    )
    switch outcome {
    case let .verified(fingerprint):
      return fingerprint
    case let .connected(connection):
      // A server that accepts "none" authentication.
      await connection.close()
      return connection.hostKeyFingerprint
    }
  }

  private enum Outcome {
    case connected(SSHConnection)
    /// Host key verified; no credential offered, connection closed.
    case verified(String)
  }

  private static func establish(
    configuration: SSHClientConfiguration,
    credential: SSHCredential?,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider,
    eventLoopGroup: (any EventLoopGroup)?
  ) async throws -> Outcome {
    guard let identity = configuration.hostIdentity else {
      throw SSHClientError.invalidConfiguration("host or port")
    }
    guard configuration.isValidUsername else {
      throw SSHClientError.invalidConfiguration("username")
    }
    let verifier = HostKeyVerifier(
      host: identity,
      store: trustStore,
      decider: trustDecider
    )
    let auth = CredentialOfferDelegate(
      username: configuration.username,
      credential: credential
    )
    let loop = (eventLoopGroup ?? defaultEventLoopGroup).next()
    let authenticated = loop.makePromise(of: Void.self)
    let timeout = TimeAmount(configuration.connectTimeout)

    let initializer: @Sendable (any Channel) -> EventLoopFuture<Void> = {
      channel in
      channel.eventLoop.makeCompletedFuture {
        var client = NIOSSH.SSHClientConfiguration(
          userAuthDelegate: auth,
          serverAuthDelegate: verifier
        )
        // Smallest RFC 4253 packet size: bounds the per-channel receive
        // window (64 packets) that backs shell read credit.
        client.maximumPacketSize = 32 * 1024
        let ssh = NIOSSHHandler(
          role: .client(client),
          allocator: channel.allocator,
          inboundChildChannelInitializer: nil
        )
        try channel.pipeline.syncOperations.addHandler(ssh)
        try channel.pipeline.syncOperations.addHandler(
          ConnectionEventsHandler(authenticated: authenticated)
        )
      }
    }

    let channel: any Channel
    do {
      channel = try await connectChannel(
        loop: loop,
        host: configuration.host,
        port: configuration.port,
        timeout: timeout,
        initializer: initializer
      )
    } catch {
      authenticated.fail(error)
      if case ChannelError.connectTimeout = error {
        throw SSHClientError.connectTimeout
      }
      throw error
    }

    let timedOut = Mutex(false)
    let timer = loop.scheduleTask(in: timeout) {
      timedOut.withLock { $0 = true }
      channel.close(promise: nil)
    }
    do {
      try await authenticated.futureResult.get()
      timer.cancel()
    } catch {
      timer.cancel()
      channel.close(promise: nil)
      if let trust = verifier.failure.withLock({ $0 }) { throw trust }
      if credential == nil, let line = verifier.accepted.withLock({ $0 }),
        let fingerprint = SSHPublicKeyFormat.fingerprint(openSSHPublicKey: line)
      {
        return .verified(fingerprint)
      }
      if auth.exhausted.withLock({ $0 }) {
        throw SSHClientError.authenticationFailed
      }
      if timedOut.withLock({ $0 }) { throw SSHClientError.connectTimeout }
      throw error
    }

    let fingerprint = verifier.accepted.withLock { $0 }.flatMap {
      SSHPublicKeyFormat.fingerprint(openSSHPublicKey: $0)
    }
    guard let fingerprint else {
      // Authentication cannot succeed without a verified host key.
      channel.close(promise: nil)
      throw SSHClientError.connectionClosed
    }
    return .connected(
      SSHConnection(
        configuration: configuration,
        hostIdentity: identity,
        hostKeyFingerprint: fingerprint,
        channel: channel
      )
    )
  }

  private static func connectChannel(
    loop: any EventLoop,
    host: String,
    port: Int,
    timeout: TimeAmount,
    initializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
  ) async throws -> any Channel {
    #if canImport(Network)
      if let bootstrap = NIOTSConnectionBootstrap(validatingGroup: loop) {
        return try await bootstrap
          .connectTimeout(timeout)
          .channelInitializer(initializer)
          .connect(host: host, port: port)
          .get()
      }
    #endif
    guard let bootstrap = ClientBootstrap(validatingGroup: loop) else {
      throw SSHClientError.invalidConfiguration("event loop group")
    }
    return try await bootstrap
      .connectTimeout(timeout)
      .channelOption(.socketOption(.tcp_nodelay), value: 1)
      .channelInitializer(initializer)
      .connect(host: host, port: port)
      .get()
  }

  public var isActive: Bool { channel.isActive }

  /// Completes when the connection closes for any reason.
  public var closeFuture: EventLoopFuture<Void> { channel.closeFuture }

  /// Closes the connection and every channel on it. Idempotent.
  public func close() async {
    channel.close(promise: nil)
    try? await channel.closeFuture.get()
  }

  /// Opens a session channel. `initialize` runs on the event loop and
  /// installs the channel's handlers.
  func openSessionChannel(
    _ initialize: @escaping @Sendable (any Channel) throws -> Void
  ) async throws -> any Channel {
    let channel = self.channel
    let promise = channel.eventLoop.makePromise(of: (any Channel).self)
    channel.eventLoop.execute {
      do {
        let ssh = try channel.pipeline.syncOperations.handler(
          type: NIOSSHHandler.self
        )
        ssh.createChannel(promise, channelType: .session) { child, _ in
          child.eventLoop.makeCompletedFuture { try initialize(child) }
        }
      } catch {
        promise.fail(error)
      }
    }
    do {
      return try await promise.futureResult.get()
    } catch let error as NIOSSHError where error.type == .channelSetupRejected {
      throw SSHClientError.channelRequestRejected("session")
    } catch let error as NIOSSHError
      where error.type == .creatingChannelAfterClosure
    {
      throw SSHClientError.connectionClosed
    }
  }
}

extension TimeAmount {
  init(_ duration: Duration) {
    let (seconds, attoseconds) = duration.components
    let nanos = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    self = .nanoseconds(
      nanos.overflow ? .max : nanos.partialValue + attoseconds / 1_000_000_000
    )
  }
}
