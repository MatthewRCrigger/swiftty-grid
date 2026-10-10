import Foundation
import Network
import ScreenProtocol
import Security
import SessionCore
import Synchronization

/// Opens pinned RST/1 QUIC connections (client side; every direct-client
/// platform). The server is authenticated solely by the exact certificate
/// delivered through SSH (`CertificatePin`); system trust is never used.
///
/// `connect` returns only after the TLS 1.3 handshake has completed with
/// the pinned certificate, ALPN `rst/1` was negotiated, early data was not
/// accepted, and the control stream is open. No application byte is sent
/// by the transport itself, so the caller's `Attach` is necessarily the
/// first application data and travels under 1-RTT keys.
public struct QUICRSTConnector: Sendable {
  public var alpn: String
  public var handshakeTimeout: Duration
  /// QUIC idle timeout; keep above the 20 s application heartbeat.
  public var idleTimeout: Duration

  public init(
    alpn: String = RSTLimits.alpn,
    handshakeTimeout: Duration = .seconds(10),
    idleTimeout: Duration = .seconds(60)
  ) {
    self.alpn = alpn
    self.handshakeTimeout = handshakeTimeout
    self.idleTimeout = idleTimeout
  }

  /// Connects and returns an `RSTConnection`; it also conforms to
  /// `RSTPathEvents`.
  public func connect(
    host: String,
    port: UInt16,
    pin: CertificatePin
  ) async throws -> any RSTConnection {
    try await connectQUIC(host: host, port: port, pin: pin)
  }

  /// Same as `connect`, returning the concrete connection type.
  public func connectQUIC(
    host: String,
    port: UInt16,
    pin: CertificatePin
  ) async throws -> QUICRSTConnection {
    guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
      throw RSTTransportError.handshake("invalid port")
    }
    let queue = DispatchQueue(label: "rst.quic.client")
    let waiter = OneShot()
    let verdict = PinVerdict {
      waiter.resolve(RSTTransportError.pinMismatch)
    }
    let quic = QUICOptions.client(
      pin: pin, alpn: alpn, idleTimeout: idleTimeout,
      verdict: verdict, queue: queue
    )
    let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
    let group = NWConnectionGroup(
      with: NWMultiplexGroup(to: endpoint),
      using: QUICOptions.parameters(quic)
    )
    let connection = QUICRSTConnection(role: .client, group: group, queue: queue)
    connection.attachGroupHandlers()

    group.stateUpdateHandler = { [weak connection] newState in
      switch newState {
      case .ready:
        waiter.resolve(nil)
      case let .waiting(error):
        // Retrying cannot fix a TLS failure (pin, ALPN, version).
        if case .tls = error { waiter.resolve(error) }
      case let .failed(error):
        waiter.resolve(error)
      case .cancelled:
        waiter.resolve(RSTTransportError.canceled)
      case .setup:
        break
      @unknown default:
        break
      }
      connection?.groupStateChanged(newState)
    }

    do {
      try await waiter.wait(timeout: handshakeTimeout) { group.start(queue: queue) }
      // Fail closed: "ready" counts only if our verify block approved it.
      guard verdict.accepted else { throw RSTTransportError.pinMismatch }
      let metadata = group.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
      guard let metadata, metadata.negotiatedALPN == alpn else {
        throw RSTTransportError.handshake("ALPN not negotiated")
      }
      guard
        !sec_protocol_metadata_get_early_data_accepted(
          metadata.securityProtocolMetadata
        )
      else { throw RSTTransportError.handshake("early data accepted") }

      guard let control = NWConnection(from: group) else {
        throw RSTTransportError.handshake("no control stream")
      }
      let streamWaiter = OneShot()
      control.stateUpdateHandler = { newState in
        switch newState {
        case .ready: streamWaiter.resolve(nil)
        case let .failed(error): streamWaiter.resolve(error)
        case .cancelled: streamWaiter.resolve(RSTTransportError.canceled)
        default: break
        }
      }
      try await streamWaiter.wait(timeout: handshakeTimeout) {
        control.start(queue: queue)
      }
      connection.setClientControl(control)
      if case .ready = control.state {} else {
        throw RSTTransportError.handshake("control stream closed")
      }
      return connection
    } catch {
      connection.close()
      group.cancel()
      if verdict.rejection != nil { throw RSTTransportError.pinMismatch }
      if let error = error as? RSTTransportError { throw error }
      throw RSTTransportError.handshake(String(describing: error))
    }
  }
}

/// A single-resolution latch bridging Network callbacks to async code,
/// with a deadline and task-cancellation support.
final class OneShot: Sendable {
  private struct State {
    var result: Result<Void, any Error>?
    var continuation: CheckedContinuation<Void, any Error>?
  }

  private let state = Mutex(State())

  /// Resolves once; nil means success. Later calls are ignored.
  func resolve(_ error: (any Error)?) {
    let continuation = state.withLock { s -> CheckedContinuation<Void, any Error>? in
      guard s.result == nil else { return nil }
      s.result = error.map { .failure($0) } ?? .success(())
      defer { s.continuation = nil }
      return s.continuation
    }
    if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }

  /// Runs `begin`, then waits for resolution or the deadline.
  func wait(
    timeout: Duration,
    begin: () -> Void
  ) async throws {
    let timer = Task { [self] in
      try? await Task.sleep(for: timeout)
      if !Task.isCancelled {
        resolve(RSTTransportError.handshake("timed out"))
      }
    }
    defer { timer.cancel() }
    begin()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let done = state.withLock { s -> Result<Void, any Error>? in
          if let result = s.result { return result }
          s.continuation = continuation
          return nil
        }
        if let done { continuation.resume(with: done) }
      }
    } onCancel: { [self] in
      resolve(RSTTransportError.canceled)
    }
  }
}
