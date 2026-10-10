import Foundation
import Network
import ScreenProtocol
import SessionCore
import Synchronization

/// Connection-viability and better-path signals for the client state
/// machine (spec §9). These are hints, combined there with application
/// acknowledgments and foreground state; neither proves the peer is gone.
public protocol RSTPathEvents: AnyObject, Sendable {
  /// Called with the control stream's viability (false: no usable path).
  var onViabilityChange: (@Sendable (Bool) -> Void)? { get set }
  /// Called when a better path is (or is no longer) available; QUIC may
  /// migrate on its own, otherwise the client may reconnect.
  var onBetterPath: (@Sendable (Bool) -> Void)? { get set }
}

/// One RST/1 connection over a Network framework QUIC connection group
/// (spec §7.1): the first client-initiated bidirectional stream carries
/// control records; each snapshot travels on its own server-initiated
/// unidirectional stream, one payload then FIN.
public final class QUICRSTConnection: RSTConnection, RSTPathEvents {
  enum Role: Sendable { case client, server }

  private struct OutboundSnapshot {
    var stream: NWConnection
    var continuation: CheckedContinuation<Void, any Error>?
    var sent = false
  }

  private struct State {
    var control: NWConnection?
    var controlWaiters: [CheckedContinuation<NWConnection, any Error>] = []
    var startedControlReads = false
    var closed = false
    var outbound: [UInt64: OutboundSnapshot] = [:]
    var outboundOrder: [UInt64] = []
    var preCanceled: Set<UInt64> = []
    var inbound: [ObjectIdentifier: NWConnection] = [:]
    /// Server snapshot streams released so far (client side).
    var releasedSnapshotStreams = 0
    var onViabilityChange: (@Sendable (Bool) -> Void)?
    var onBetterPath: (@Sendable (Bool) -> Void)?
    var onTerminated: (@Sendable () -> Void)?
  }

  /// Completed-but-unretired outbound streams kept for possible reset.
  static let maxTrackedOutbound = 8
  /// Application error code for a canceled (superseded) snapshot stream.
  static let snapshotCanceledCode: UInt64 = 0x10
  /// Application error code for a rejected inbound stream.
  static let streamRejectedCode: UInt64 = 0x11

  let role: Role
  let group: NWConnectionGroup
  let queue: DispatchQueue
  private let state = Mutex(State())
  private let mailbox: EventMailbox

  init(role: Role, group: NWConnectionGroup, queue: DispatchQueue) {
    self.role = role
    self.group = group
    self.queue = queue
    self.mailbox = EventMailbox(
      snapshotLimit: RSTLimits.maxInFlightSnapshots + 1
    )
  }

  deinit {
    // A dropped connection must not keep its QUIC connection alive until
    // the idle timeout.
    group.cancel()
  }

  // MARK: Path events

  public var onViabilityChange: (@Sendable (Bool) -> Void)? {
    get { state.withLock { $0.onViabilityChange } }
    set { state.withLock { $0.onViabilityChange = newValue } }
  }

  public var onBetterPath: (@Sendable (Bool) -> Void)? {
    get { state.withLock { $0.onBetterPath } }
    set { state.withLock { $0.onBetterPath = newValue } }
  }

  /// Negotiated ALPN of the connection group, if known.
  public var negotiatedALPN: String? {
    (group.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata)?.negotiatedALPN
  }

  /// Internal hook for the listener's connection accounting.
  func setOnTerminated(_ body: @escaping @Sendable () -> Void) {
    state.withLock { $0.onTerminated = body }
  }

  // MARK: Group wiring

  /// Installs inbound-stream and group-state handlers. Call before the
  /// group starts (server) or right after creating it (client).
  func attachGroupHandlers() {
    group.newConnectionHandler = { [weak self] stream in
      guard let self else {
        stream.cancel()
        return
      }
      self.adopt(inbound: stream)
    }
  }

  /// Group state after `ready` (the connector/listener owns the handshake
  /// phase).
  func groupStateChanged(_ newState: NWConnectionGroup.State) {
    switch newState {
    case let .failed(error): terminate(error: error)
    case .cancelled: terminate(error: nil)
    default: break
    }
  }

  private func adopt(inbound stream: NWConnection) {
    stream.stateUpdateHandler = { [weak self, weak stream] newState in
      guard let self, let stream else { return }
      switch newState {
      case .ready: self.classify(inbound: stream)
      case .failed, .cancelled: self.forget(inbound: stream)
      default: break
      }
    }
    let accepted = state.withLock { s -> Bool in
      guard !s.closed, s.inbound.count < 16 else { return false }
      s.inbound[ObjectIdentifier(stream)] = stream
      return true
    }
    guard accepted else {
      Self.reject(stream)
      return
    }
    stream.start(queue: queue)
  }

  private func forget(inbound stream: NWConnection) {
    state.withLock { _ = $0.inbound.removeValue(forKey: ObjectIdentifier(stream)) }
  }

  private static func reject(_ stream: NWConnection) {
    if let metadata = stream.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    {
      metadata.streamApplicationErrorCode = streamRejectedCode
    }
    stream.cancel()
  }

  /// RFC 9000 §2.1: the low two bits of a stream ID give initiator (bit 0,
  /// 1 = server) and directionality (bit 1, 1 = unidirectional).
  private func classify(inbound stream: NWConnection) {
    guard
      let metadata = stream.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
    else {
      forget(inbound: stream)
      Self.reject(stream)
      return
    }
    let kind = metadata.streamIdentifier & 0x3
    switch role {
    case .server where kind == 0:
      // First client bidirectional stream becomes the control stream.
      let waiters = state.withLock { s -> [CheckedContinuation<NWConnection, any Error>]? in
        guard s.control == nil, !s.closed else { return nil }
        s.inbound.removeValue(forKey: ObjectIdentifier(stream))
        s.control = stream
        defer { s.controlWaiters = [] }
        return s.controlWaiters
      }
      guard let waiters else {
        forget(inbound: stream)
        Self.reject(stream)
        return
      }
      installControlHandlers(stream)
      for waiter in waiters { waiter.resume(returning: stream) }
      startControlReadsIfReady()
    case .client where kind == 3:
      readSnapshot(from: stream, into: SnapshotStreamAccumulator())
    default:
      forget(inbound: stream)
      Self.reject(stream)
    }
  }

  /// Client: adopts the locally opened control stream.
  func setClientControl(_ stream: NWConnection) {
    state.withLock { $0.control = stream }
    installControlHandlers(stream)
  }

  private func installControlHandlers(_ stream: NWConnection) {
    stream.stateUpdateHandler = { [weak self] newState in
      switch newState {
      case let .failed(error): self?.terminate(error: error)
      case .cancelled: self?.terminate(error: nil)
      default: break
      }
    }
    stream.viabilityUpdateHandler = { [weak self] viable in
      self?.onViabilityChange?(viable)
    }
    stream.betterPathUpdateHandler = { [weak self] better in
      self?.onBetterPath?(better)
    }
  }

  // MARK: RSTConnection

  public func start(_ handler: RSTConnectionHandler) {
    guard mailbox.start(handler) else { return }
    startControlReadsIfReady()
  }

  private func startControlReadsIfReady() {
    guard mailbox.hasHandler else { return }
    let stream = state.withLock { s -> NWConnection? in
      guard let control = s.control, !s.startedControlReads, !s.closed else {
        return nil
      }
      s.startedControlReads = true
      return control
    }
    if let stream { receiveControl(stream) }
  }

  /// One read at a time; the next is issued only after `onControl` for
  /// these bytes returns.
  private func receiveControl(_ stream: NWConnection) {
    stream.receive(
      minimumIncompleteLength: 1,
      maximumLength: RSTLimits.maxControlRecordBytes
    ) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data, !data.isEmpty {
        let bytes = [UInt8](data)
        let more = error == nil && !isComplete
        self.mailbox.post(.control(bytes, done: { [weak self] in
          if more { self?.receiveControl(stream) }
        }))
      } else if error == nil, !isComplete {
        self.receiveControl(stream)
      }
      if let error {
        self.terminate(error: error)
      } else if isComplete {
        // Peer finished the control stream: orderly end of connection.
        self.terminate(error: nil)
      }
    }
  }

  public func sendControl(_ record: [UInt8]) async throws {
    let stream = try await controlStream()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      stream.send(
        content: Data(record),
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      )
    }
  }

  private func controlStream() async throws -> NWConnection {
    if let ready = try state.withLock({ s -> NWConnection? in
      if s.closed { throw RSTTransportError.closed }
      return s.control
    }) {
      return ready
    }
    // Server before the client's first control bytes arrived.
    return try await withCheckedThrowingContinuation { continuation in
      let immediate = state.withLock { s -> Result<NWConnection, any Error>? in
        if s.closed { return .failure(RSTTransportError.closed) }
        if let control = s.control { return .success(control) }
        s.controlWaiters.append(continuation)
        return nil
      }
      if let immediate { continuation.resume(with: immediate) }
    }
  }

  public func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {
    guard role == .server else { throw RSTTransportError.notStarted }
    guard payload.count <= SnapshotStreamAccumulator.hardLimit else {
      throw RSTTransportError.snapshotTooLarge
    }
    let canceled = try state.withLock { s -> Bool in
      if s.closed { throw RSTTransportError.closed }
      return s.preCanceled.remove(id) != nil
    }
    if canceled { throw RSTTransportError.canceled }
    guard
      let stream = NWConnection(
        from: group, using: QUICOptions.unidirectionalStream()
      )
    else { throw RSTTransportError.closed }

    stream.stateUpdateHandler = { [weak self] newState in
      switch newState {
      case let .failed(error):
        self?.finishOutbound(id: id, stream: stream, error: error)
      case .cancelled:
        self?.finishOutbound(
          id: id, stream: stream, error: RSTTransportError.canceled
        )
      default: break
      }
    }
    let registered = state.withLock { s -> Bool in
      guard !s.closed else { return false }
      if let old = s.outbound[id] { old.stream.cancel() }
      s.outbound[id] = OutboundSnapshot(stream: stream)
      s.outboundOrder.removeAll { $0 == id }
      s.outboundOrder.append(id)
      return true
    }
    guard registered else { throw RSTTransportError.closed }
    stream.start(queue: queue)

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let live = state.withLock { s -> Bool in
          guard s.outbound[id]?.stream === stream else { return false }
          s.outbound[id]?.continuation = continuation
          return true
        }
        guard live else {
          continuation.resume(throwing: RSTTransportError.canceled)
          return
        }
        stream.send(
          content: Data(payload),
          contentContext: .finalMessage,
          isComplete: true,
          completion: .contentProcessed { [weak self] error in
            self?.sendCompleted(id: id, stream: stream, error: error)
          }
        )
      }
    } onCancel: { [weak self] in
      self?.cancelSnapshot(stream: id)
    }
  }

  private func sendCompleted(
    id: UInt64, stream: NWConnection, error: NWError?
  ) {
    let (continuation, evicted) = state.withLock {
      s -> (CheckedContinuation<Void, any Error>?, [NWConnection]) in
      guard var entry = s.outbound[id], entry.stream === stream else {
        return (nil, [])
      }
      let c = entry.continuation
      entry.continuation = nil
      entry.sent = true
      s.outbound[id] = entry
      // Bound the streams kept around for a possible later reset.
      var evicted: [NWConnection] = []
      while s.outboundOrder.count > Self.maxTrackedOutbound,
        let oldest = s.outboundOrder.first(where: { s.outbound[$0]?.sent == true })
      {
        s.outboundOrder.removeAll { $0 == oldest }
        if let e = s.outbound.removeValue(forKey: oldest) {
          evicted.append(e.stream)
        }
      }
      return (c, evicted)
    }
    _ = evicted  // Released, not reset: their data is already queued.
    if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }

  private func finishOutbound(
    id: UInt64, stream: NWConnection, error: any Error
  ) {
    let continuation = state.withLock {
      s -> CheckedContinuation<Void, any Error>? in
      guard let entry = s.outbound[id], entry.stream === stream else {
        return nil
      }
      s.outbound.removeValue(forKey: id)
      s.outboundOrder.removeAll { $0 == id }
      return entry.continuation
    }
    continuation?.resume(throwing: error)
  }

  /// Abandons a superseded snapshot stream with application error
  /// `snapshotCanceledCode`. Data already handed to QUIC may still reach
  /// the client as a complete payload, which is harmless; a truncated or
  /// reset stream is discarded by the client's exact-length check.
  ///
  /// Uses `cancel()`, not `forceCancel()`: on macOS 27 forcibly canceling
  /// a stream with queued data intermittently aborted the whole QUIC
  /// connection (ECONNABORTED on the control stream) in loopback tests,
  /// while `cancel()` with a stream error code stops the transfer.
  public func cancelSnapshot(stream id: UInt64) {
    guard role == .server else { return }
    let entry = state.withLock { s -> OutboundSnapshot? in
      guard let entry = s.outbound.removeValue(forKey: id) else {
        if !s.closed {
          // Canceled before `sendSnapshot` registered it; bounded by the
          // scheduler's stream ids.
          if s.preCanceled.count >= 64 { s.preCanceled.removeAll() }
          s.preCanceled.insert(id)
        }
        return nil
      }
      s.outboundOrder.removeAll { $0 == id }
      return entry
    }
    guard let entry else { return }
    if let metadata = entry.stream.metadata(
      definition: NWProtocolQUIC.definition
    ) as? NWProtocolQUIC.Metadata {
      metadata.streamApplicationErrorCode = Self.snapshotCanceledCode
    }
    entry.stream.cancel()
    entry.continuation?.resume(throwing: RSTTransportError.canceled)
  }

  /// Test hook: opens a server unidirectional stream and writes `bytes`
  /// verbatim, with or without FIN, bypassing every sender-side check.
  /// Returns the stream so a test can reset it.
  func sendRawStreamForTesting(
    _ bytes: [UInt8],
    finish: Bool
  ) async throws -> NWConnection {
    guard
      let stream = NWConnection(
        from: group, using: QUICOptions.unidirectionalStream()
      )
    else { throw RSTTransportError.closed }
    stream.start(queue: queue)
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      stream.send(
        content: Data(bytes),
        contentContext: finish ? .finalMessage : .defaultMessage,
        isComplete: finish,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
      )
    }
    return stream
  }

  // MARK: Inbound snapshots (client)

  private func readSnapshot(
    from stream: NWConnection,
    into accumulator: SnapshotStreamAccumulator
  ) {
    stream.receive(
      minimumIncompleteLength: 1,
      maximumLength: accumulator.nextReadLimit
    ) { [weak self] data, _, isComplete, error in
      guard let self else {
        stream.cancel()
        return
      }
      var accumulator = accumulator
      if error != nil {
        // Reset or failed: discard whatever arrived. The stream is already
        // terminated by the peer, so only release it locally.
        self.forget(inbound: stream)
        stream.cancel()
        self.releaseSnapshotCredit()
        return
      }
      if let data, !data.isEmpty {
        do {
          try accumulator.append(data)
        } catch {
          self.discard(stream)
          self.releaseSnapshotCredit()
          return
        }
      }
      guard isComplete else {
        self.readSnapshot(from: stream, into: accumulator)
        return
      }
      guard let payload = try? accumulator.finish() else {
        self.discard(stream)
        self.releaseSnapshotCredit()
        return
      }
      // Keep the stream (and its stream credit) until delivered, so
      // undelivered snapshots stay bounded by the QUIC stream limit.
      self.mailbox.post(.snapshot(payload, done: { [weak self] in
        self?.forget(inbound: stream)
        stream.cancel()
        self?.releaseSnapshotCredit()
      }))
    }
  }

  /// QUIC `MAX_STREAMS` is a cumulative count, and Network framework does
  /// not raise it as streams close: without this the server could open
  /// only `concurrentSnapshotStreams` snapshots per connection. Each
  /// released stream extends the limit by one.
  private func releaseSnapshotCredit() {
    let (control, released) = state.withLock { s -> (NWConnection?, Int) in
      s.releasedSnapshotStreams += 1
      return (s.control, s.releasedSnapshotStreams)
    }
    guard
      let control,
      let metadata = control.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
    else { return }
    let limit = released + QUICOptions.concurrentSnapshotStreams
    if metadata.localMaxStreamsUnidirectional < limit {
      metadata.localMaxStreamsUnidirectional = limit
    }
  }

  private func discard(_ stream: NWConnection) {
    forget(inbound: stream)
    Self.reject(stream)
  }

  // MARK: Lifecycle

  /// Grace period for an orderly close to reach the peer before the
  /// connection group is canceled.
  static let closeGrace: DispatchTimeInterval = .milliseconds(500)

  /// Orderly close: finishes the control stream (FIN) so the peer sees an
  /// explicit end, then cancels the group once that FIN was handed to
  /// QUIC (bounded by `closeGrace`). Canceling the group alone does not
  /// reliably notify the peer before its idle timeout.
  public func close() {
    terminate(error: nil, graceful: true)
  }

  /// Idempotent teardown: fails waiters and pending sends, cancels the
  /// group (and with it every stream), and delivers `onClosed` once.
  func terminate(error: (any Error)?, graceful: Bool = false) {
    let snapshot = state.withLock { s -> State? in
      guard !s.closed else { return nil }
      s.closed = true
      let copy = s
      s.controlWaiters = []
      s.outbound = [:]
      s.outboundOrder = []
      s.inbound = [:]
      s.onViabilityChange = nil
      s.onBetterPath = nil
      s.onTerminated = nil
      return copy
    }
    guard let snapshot else { return }
    for waiter in snapshot.controlWaiters {
      waiter.resume(throwing: RSTTransportError.closed)
    }
    for entry in snapshot.outbound.values {
      entry.continuation?.resume(throwing: RSTTransportError.closed)
    }
    if graceful, let control = snapshot.control, case .ready = control.state {
      let group = self.group
      control.send(
        content: nil,
        contentContext: .finalMessage,
        isComplete: true,
        completion: .contentProcessed { [queue] _ in
          // Let the FIN leave before the group (and the stream) goes.
          queue.asyncAfter(deadline: .now() + .milliseconds(50)) {
            group.cancel()
          }
        }
      )
      queue.asyncAfter(deadline: .now() + Self.closeGrace) { group.cancel() }
    } else {
      group.cancel()
    }
    mailbox.post(.closed(error))
    snapshot.onTerminated?()
  }
}
