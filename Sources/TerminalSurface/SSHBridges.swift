import Foundation
import NIOCore
import ScreenProtocol
import SSHClient
import Synchronization

/// Fixed installed helper path (spec §5.1). Never interpolated from input.
public let defaultHelperPath = "/usr/local/libexec/swifttyd"

/// How to reach and authenticate to the Mac over SSH.
public struct SSHEndpoint: Sendable {
  public var configuration: SSHClient.SSHClientConfiguration
  public var credential: SSHCredential
  public var trustStore: any HostTrustStore
  /// Asked only for an unknown key. Automatic reconnects should use
  /// `RejectUnknownHostKeys` so they never prompt.
  public var trustDecider: any HostTrustDecider
  public var helperPath: String

  public init(
    configuration: SSHClient.SSHClientConfiguration,
    credential: SSHCredential,
    trustStore: any HostTrustStore,
    trustDecider: any HostTrustDecider = RejectUnknownHostKeys(),
    helperPath: String = defaultHelperPath
  ) {
    self.configuration = configuration
    self.credential = credential
    self.trustStore = trustStore
    self.trustDecider = trustDecider
    self.helperPath = helperPath
  }

  func connect(
    eventLoopGroup: (any EventLoopGroup)?
  ) async throws -> SSHConnection {
    try await SSHConnection.connect(
      configuration: configuration,
      credential: credential,
      trustStore: trustStore,
      trustDecider: trustDecider,
      eventLoopGroup: eventLoopGroup
    )
  }
}

/// Runs `swifttyd bootstrap --stdio` on a fresh SSH connection per
/// request, so every grant follows a host-key check and authentication.
public struct SSHBootstrapper: RemoteBootstrapper {
  public var endpoint: SSHEndpoint
  public var eventLoopGroup: (any EventLoopGroup)?

  public init(endpoint: SSHEndpoint, eventLoopGroup: (any EventLoopGroup)? = nil) {
    self.endpoint = endpoint
    self.eventLoopGroup = eventLoopGroup
  }

  public func bootstrap(
    _ request: BootstrapRequest
  ) async throws -> BootstrapResponse {
    let connection: SSHConnection
    do {
      connection = try await endpoint.connect(eventLoopGroup: eventLoopGroup)
    } catch {
      throw Self.map(error)
    }
    do {
      let response = try await connection.runBootstrap(
        helperPath: endpoint.helperPath,
        request: request
      )
      await connection.close()
      return response
    } catch {
      await connection.close()
      throw Self.map(error)
    }
  }

  static func map(_ error: any Error) -> RemoteBootstrapError {
    guard let error = error as? SSHClientError else { return .unreachable }
    switch error {
    case .hostKeyChanged, .hostKeyRejected, .trustStoreUnavailable:
      return .hostKeyRejected
    case .authenticationFailed: return .authenticationFailed
    case .bootstrapProtocol, .bootstrapFailed, .invalidHelperPath,
      .outputLimitExceeded:
      return .protocolViolation
    default: return .unreachable
    }
  }
}

/// `TerminalByteChannel` over an interactive SSH shell channel.
public final class SSHShellByteChannel: TerminalByteChannel, @unchecked Sendable {
  private struct State {
    var handler: TerminalChannelHandler?
    var backlog: [SSHShellEvent] = []
    var exitStatus: TerminalChannelExit?
    var finished = false
  }

  private let state = Mutex(State())
  private var channel: SSHShellChannel?

  private init() {}

  /// Opens a PTY shell. Output is held until `start` and credit arrive.
  public static func open(
    on connection: SSHConnection,
    columns: Int,
    rows: Int
  ) async throws -> SSHShellByteChannel {
    let adapter = SSHShellByteChannel()
    adapter.channel = try await connection.openShell(
      columns: columns,
      rows: rows,
      initialReadCredit: 0
    ) { [weak adapter] event in adapter?.receive(event) }
    return adapter
  }

  private func receive(_ event: SSHShellEvent) {
    let handler = state.withLock { s -> TerminalChannelHandler? in
      if s.handler == nil { s.backlog.append(event) }
      return s.handler
    }
    if let handler { dispatch(event, to: handler) }
  }

  private func dispatch(_ event: SSHShellEvent, to handler: TerminalChannelHandler) {
    switch event {
    case let .output(bytes): handler.onOutput(bytes)
    case let .exitStatus(code):
      state.withLock { $0.exitStatus = .exited(Int32(truncatingIfNeeded: code)) }
    case let .exitSignal(name):
      state.withLock { $0.exitStatus = .signaled(name) }
    case .closed:
      let exit = state.withLock { s -> TerminalChannelExit? in
        guard !s.finished else { return nil }
        s.finished = true
        return s.exitStatus ?? .disconnected
      }
      if let exit { handler.onExit(exit) }
    }
  }

  public func start(_ handler: TerminalChannelHandler) {
    let backlog = state.withLock { s -> [SSHShellEvent] in
      s.handler = handler
      defer { s.backlog = [] }
      return s.backlog
    }
    for event in backlog { dispatch(event, to: handler) }
  }

  public func grantCredit(_ bytes: Int) { channel?.grantReadCredit(bytes) }

  public func write(_ bytes: [UInt8]) async throws {
    guard let channel else { throw SSHClientError.connectionClosed }
    var offset = 0
    let limit = 64 * 1024
    while offset < bytes.count {
      let end = min(offset + limit, bytes.count)
      try await channel.write(Array(bytes[offset ..< end]))
      offset = end
    }
  }

  public func resize(columns: Int, rows: Int) async throws {
    try await channel?.resize(columns: columns, rows: rows)
  }

  public func close() async { await channel?.close() }
}
