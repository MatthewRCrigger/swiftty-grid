import Dispatch
import Synchronization

/// Events from an authenticated RST/1 connection. Delivery is serialized
/// per handler; the transport does not read the next control record until
/// `onControl` returns, so a slow consumer applies backpressure instead of
/// growing an unbounded queue.
public struct RSTConnectionHandler: Sendable {
  /// Raw control-stream bytes in order (feed a `ControlRecordReader`).
  public var onControl: @Sendable ([UInt8]) async -> Void
  /// One complete snapshot stream payload (client side), already bounded
  /// by the snapshot limits. Incomplete or canceled streams never arrive.
  public var onSnapshot: @Sendable ([UInt8]) async -> Void
  /// The connection ended; nil for an orderly close.
  public var onClosed: @Sendable ((any Error)?) -> Void

  public init(
    onControl: @escaping @Sendable ([UInt8]) async -> Void,
    onSnapshot: @escaping @Sendable ([UInt8]) async -> Void = { _ in },
    onClosed: @escaping @Sendable ((any Error)?) -> Void
  ) {
    self.onControl = onControl
    self.onSnapshot = onSnapshot
    self.onClosed = onClosed
  }
}

public enum RSTTransportError: Error, Equatable, Sendable {
  case closed
  case canceled
  case snapshotTooLarge
  case notStarted
  case handshake(String)
  case pinMismatch
}

/// One RST/1 connection: a bidirectional control stream plus
/// server-initiated unidirectional snapshot streams (spec §7.1). The QUIC
/// implementation lives in AppleTransport; tests use `InMemoryRSTConnection`.
public protocol RSTConnection: AnyObject, Sendable {
  /// Starts event delivery. Call once.
  func start(_ handler: RSTConnectionHandler)
  /// Writes a control record; returns once the transport accepted it
  /// under its flow control.
  func sendControl(_ record: [UInt8]) async throws
  /// Server: sends one snapshot payload on a new stream followed by FIN.
  /// Throws `RSTTransportError.canceled` if canceled first.
  func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws
  /// Server: cancels a superseded snapshot stream (resets it).
  func cancelSnapshot(stream id: UInt64)
  /// Closes the connection and all streams. Idempotent.
  func close()
}

/// Accepts authenticated RST/1 connections (server side).
public protocol RSTListener: AnyObject, Sendable {
  var port: UInt16 { get }
  func start(
    onConnection: @escaping @Sendable (any RSTConnection) -> Void
  ) async throws
  func stop()
}

/// An in-process connection pair with fault injection, for host/client
/// tests without a network.
public final class InMemoryRSTConnection: RSTConnection, @unchecked Sendable {
  private struct State {
    var handler: RSTConnectionHandler?
    var backlog: [Event] = []
    var closed = false
    var heldSnapshots: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    var holdSnapshots = false
    var canceled: Set<UInt64> = []
  }

  private enum Event {
    case control([UInt8])
    case snapshot([UInt8])
    case closed((any Error)?)
  }

  private let state = Mutex(State())
  private weak var peer: InMemoryRSTConnection?
  private let delivery: DispatchQueue
  /// Strong reference for the server side of a pair kept by the client.
  private var retainedPeer: InMemoryRSTConnection?

  private init(label: String) {
    delivery = DispatchQueue(label: "rst.inmemory.\(label)")
  }

  /// Returns `(client, server)`.
  public static func pair() -> (
    client: InMemoryRSTConnection, server: InMemoryRSTConnection
  ) {
    let client = InMemoryRSTConnection(label: "client")
    let server = InMemoryRSTConnection(label: "server")
    client.peer = server
    server.peer = client
    client.retainedPeer = server
    return (client, server)
  }

  public func start(_ handler: RSTConnectionHandler) {
    let backlog = state.withLock { s -> [Event] in
      s.handler = handler
      defer { s.backlog = [] }
      return s.backlog
    }
    for event in backlog { deliver(event, to: handler) }
  }

  private func enqueue(_ event: Event) {
    let handler = state.withLock { s -> RSTConnectionHandler? in
      if s.handler == nil { s.backlog.append(event) }
      return s.handler
    }
    if let handler { deliver(event, to: handler) }
  }

  private func deliver(_ event: Event, to handler: RSTConnectionHandler) {
    // A serial queue plus a blocking wait keeps events ordered and lets
    // `onControl` exert backpressure as the real transport does.
    delivery.async {
      let done = DispatchSemaphore(value: 0)
      Task {
        switch event {
        case let .control(bytes): await handler.onControl(bytes)
        case let .snapshot(bytes): await handler.onSnapshot(bytes)
        case let .closed(error): handler.onClosed(error)
        }
        done.signal()
      }
      done.wait()
    }
  }

  public func sendControl(_ record: [UInt8]) async throws {
    guard !state.withLock({ $0.closed }), let peer else {
      throw RSTTransportError.closed
    }
    peer.enqueue(.control(record))
  }

  public func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {
    let hold = state.withLock { s -> Bool in
      s.holdSnapshots && !s.closed
    }
    if hold {
      try await withCheckedThrowingContinuation { continuation in
        let canceled = state.withLock { s -> Bool in
          if s.canceled.remove(id) != nil || s.closed { return true }
          s.heldSnapshots[id] = continuation
          return false
        }
        if canceled { continuation.resume(throwing: RSTTransportError.canceled) }
      }
    }
    let canceled = state.withLock { s in
      s.canceled.remove(id) != nil || s.closed
    }
    guard !canceled, let peer else { throw RSTTransportError.canceled }
    peer.enqueue(.snapshot(payload))
  }

  public func cancelSnapshot(stream id: UInt64) {
    let held = state.withLock { s -> CheckedContinuation<Void, any Error>? in
      if let c = s.heldSnapshots.removeValue(forKey: id) { return c }
      s.canceled.insert(id)
      return nil
    }
    held?.resume(throwing: RSTTransportError.canceled)
  }

  /// Test control: hold outgoing snapshots until `releaseSnapshots()`.
  public func setHoldSnapshots(_ hold: Bool) {
    state.withLock { $0.holdSnapshots = hold }
  }

  public func releaseSnapshots() {
    let held = state.withLock { s in
      defer { s.heldSnapshots = [:] }
      return s.heldSnapshots.values
    }
    for c in held { c.resume() }
  }

  public func close() { closeLocally(error: nil, notifyPeer: true) }

  /// Simulates abrupt path loss: both ends observe an error.
  public func sever() {
    closeLocally(error: RSTTransportError.closed, notifyPeer: true)
  }

  private func closeLocally(error: (any Error)?, notifyPeer: Bool) {
    let (wasClosed, held) = state.withLock { s in
      defer {
        s.closed = true
        s.heldSnapshots = [:]
      }
      return (s.closed, Array(s.heldSnapshots.values))
    }
    guard !wasClosed else { return }
    for c in held { c.resume(throwing: RSTTransportError.closed) }
    enqueue(.closed(error))
    if notifyPeer {
      peer?.closeLocally(error: error ?? RSTTransportError.closed, notifyPeer: false)
    }
  }
}
