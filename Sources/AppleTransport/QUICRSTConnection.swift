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

  /// Orders one native write against cancellation without retaining a payload
  /// in an extra queue. Network's send call is nonblocking; its completion
  /// only uses the connection state lock, never this admission lock.
  private final class SnapshotWriteAdmission: Sendable {
    private enum Phase: Sendable { case waiting, started, cancelled }

    private let phase = Mutex(Phase.waiting)

    func perform(_ write: () -> Void) {
      phase.withLock { phase in
        guard phase == .waiting else { return }
        phase = .started
        write()
      }
    }

    /// Closes admission. True when `perform` already submitted the native send.
    func cancel() -> Bool {
      phase.withLock { phase in
        switch phase {
        case .waiting:
          phase = .cancelled
          return false
        case .started:
          phase = .cancelled
          return true
        case .cancelled: return false
        }
      }
    }
  }

  private struct OutboundSnapshot {
    var stream: NWConnection
    let writeAdmission = SnapshotWriteAdmission()
    var continuation: CheckedContinuation<Void, any Error>?
    var sent = false
    /// Cancel once the native send completion runs. Cancelling earlier, while
    /// that send is still inside Network, aborts the whole connection group.
    var resetAfterSend = false
  }

  private struct ControlSend {
    var waiter: CheckedContinuation<NWConnection, any Error>?
    var completion: CheckedContinuation<Void, any Error>?
    var writing = false
  }

  private struct SnapshotReadProgress {
    var callbacks = 0
    var bytes = 0
    var pending = false
    var complete = false
  }

  private struct State {
    var control: NWConnection?
    var controlSends: [UUID: ControlSend] = [:]
    var startedControlReads = false
    var closed = false
    var termination: String?
    var nativeTermination: String?
    var outbound: [UInt64: OutboundSnapshot] = [:]
    var admittedSnapshotSends = 0
    var outboundOrder: [UInt64] = []
    /// Superseded streams whose native send is still outstanding.
    var parkedResets: [ObjectIdentifier: NWConnection] = [:]
    var preCanceled: [UInt64] = []
    var inbound: [ObjectIdentifier: NWConnection] = [:]
    var snapshotReads: [ObjectIdentifier: SnapshotReadProgress] = [:]
    var streamLifecycle: [String] = []
    var beforeInboundStartForTesting: (@Sendable () -> Void)?
    /// Server snapshot streams released so far (client side).
    var releasedSnapshotStreams = 0
    var onViabilityChange: (@Sendable (Bool) -> Void)?
    var onBetterPath: (@Sendable (Bool) -> Void)?
    var onTerminated: (@Sendable () -> Void)?

    mutating func takeControlWaiters() -> [CheckedContinuation<
      NWConnection, any Error
    >] {
      var waiters: [CheckedContinuation<NWConnection, any Error>] = []
      for id in Array(controlSends.keys) {
        if let waiter = controlSends[id]?.waiter {
          waiters.append(waiter)
          controlSends[id]?.waiter = nil
        }
      }
      return waiters
    }

    mutating func takePreCancellation(_ id: UInt64) -> Bool {
      guard let index = preCanceled.firstIndex(of: id) else { return false }
      preCanceled.remove(at: index)
      return true
    }
  }

  /// Completed-but-unretired outbound streams kept for possible reset.
  static let maxTrackedOutbound = 8
  static let maxPendingControlSends = 32

  var hasControlStreamForTesting: Bool { state.withLock { $0.control != nil } }

  var pendingControlSendsForTesting: Int {
    state.withLock { $0.controlSends.count }
  }
  static let maxPendingSnapshotSends = 8

  var admittedSnapshotSendsForTesting: Int {
    state.withLock { $0.admittedSnapshotSends }
  }
  static let maxPreCanceledSnapshots = 64

  var preCanceledSnapshotCount: Int { state.withLock { $0.preCanceled.count } }
  /// Application error code for a canceled (superseded) snapshot stream.
  static let snapshotCanceledCode: UInt64 = 0x10
  /// Application error code for a rejected inbound stream.
  static let streamRejectedCode: UInt64 = 0x11

  let role: Role
  let group: NWConnectionGroup
  let queue: DispatchQueue
  private let state = Mutex(State())
  private let traceSnapshotReads = Atomic(false)
  private let controlWrites = DispatchQueue(label: "rst.quic.control-writes")
  private let mailbox: EventMailbox
  private let limits: NegotiatedLimits

  init(
    role: Role,
    group: NWConnectionGroup,
    queue: DispatchQueue,
    limits: NegotiatedLimits = NegotiatedLimits()
  ) {
    self.role = role
    self.group = group
    self.queue = queue
    self.limits = limits.effective
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
    set {
      let previous = state.withLock { s in
        let previous = s.onViabilityChange
        s.onViabilityChange = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  public var onBetterPath: (@Sendable (Bool) -> Void)? {
    get { state.withLock { $0.onBetterPath } }
    set {
      let previous = state.withLock { s in
        let previous = s.onBetterPath
        s.onBetterPath = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  /// Negotiated ALPN of the connection group, if known.
  public var negotiatedALPN: String? {
    (group.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata)?
      .negotiatedALPN
  }

  /// Internal hook for the listener's connection accounting.
  func setOnTerminated(_ body: @escaping @Sendable () -> Void) {
    let previous = state.withLock { s in
      let previous = s.onTerminated
      s.onTerminated = body
      return previous
    }
    withExtendedLifetime(previous) {}
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
    case let .failed(error): terminate(error: error, source: "group failed")
    case .cancelled: terminate(error: nil, source: "group cancelled")
    default: break
    }
  }

  private func adopt(inbound stream: NWConnection) {
    traceStream(stream, event: "adopt")
    stream.stateUpdateHandler = { [weak self, weak stream] newState in
      guard let self, let stream else { return }
      self.traceStream(stream, event: "state \(newState)")
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
      reject(stream)
      return
    }
    let beforeStart = state.withLock { $0.beforeInboundStartForTesting }
    beforeStart?()
    stream.start(queue: queue)
  }

  func setBeforeInboundStartForTesting(_ body: (@Sendable () -> Void)?) {
    let previous = state.withLock { s in
      let previous = s.beforeInboundStartForTesting
      s.beforeInboundStartForTesting = body
      return previous
    }
    withExtendedLifetime(previous) {}
  }

  private func traceStream(
    _ stream: NWConnection,
    event: @autoclosure () -> String
  ) {
    guard traceSnapshotReads.load(ordering: .relaxed) else { return }
    let timestamp = DispatchTime.now().uptimeNanoseconds
    let metadata =
      stream.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    let detail =
      "\(event()),time=\(timestamp),object=\(ObjectIdentifier(stream)),"
      + "id=\(String(describing: metadata?.streamIdentifier)),"
      + "streamError=\(String(describing: metadata?.streamApplicationErrorCode))"
    state.withLock { s in
      // Keep the first eight events and the latest eight, with no native captures.
      if s.streamLifecycle.count == 16 { s.streamLifecycle.remove(at: 8) }
      s.streamLifecycle.append(String(detail.prefix(256)))
    }
  }

  private func forget(inbound stream: NWConnection) {
    state.withLock {
      _ = $0.inbound.removeValue(forKey: ObjectIdentifier(stream))
      $0.snapshotReads.removeValue(forKey: ObjectIdentifier(stream))
    }
  }

  /// Defers the native reset until this queue turn finishes. Setting the
  /// stream error or cancelling inside a receive or state callback aborts
  /// the connection group with EINVAL.
  private func reject(_ stream: NWConnection) {
    queue.async { self.finishReject(stream) }
  }

  private func finishReject(_ stream: NWConnection) {
    if case .ready = stream.state,
      let metadata = stream.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
    {
      metadata.streamApplicationErrorCode = Self.streamRejectedCode
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
      reject(stream)
      return
    }
    let kind = metadata.streamIdentifier & 0x3
    switch role {
    case .server where kind == 0:
      // First client bidirectional stream becomes the control stream.
      let waiters = state.withLock {
        s -> [CheckedContinuation<NWConnection, any Error>]? in
        guard s.control == nil, !s.closed else { return nil }
        s.inbound.removeValue(forKey: ObjectIdentifier(stream))
        s.control = stream
        return s.takeControlWaiters()
      }
      guard let waiters else {
        forget(inbound: stream)
        reject(stream)
        return
      }
      installControlHandlers(stream)
      for waiter in waiters { waiter.resume(returning: stream) }
      startControlReadsIfReady()
    case .client where kind == 3:
      readSnapshot(
        from: stream,
        into: SnapshotStreamAccumulator(limits: limits)
      )
    default:
      forget(inbound: stream)
      reject(stream)
    }
  }

  /// Client: adopts the locally opened control stream.
  func setClientControl(_ stream: NWConnection) {
    let waiters = state.withLock {
      s -> [CheckedContinuation<NWConnection, any Error>]? in
      guard !s.closed, s.control == nil else { return nil }
      s.control = stream
      return s.takeControlWaiters()
    }
    guard let waiters else {
      stream.cancel();
      return
    }
    installControlHandlers(stream)
    for waiter in waiters { waiter.resume(returning: stream) }
  }

  private func installControlHandlers(_ stream: NWConnection) {
    stream.stateUpdateHandler = { [weak self, weak stream] newState in
      switch newState {
      case let .failed(error):
        if let stream {
          self?.traceStream(stream, event: "control failed \(error)")
        }
        self?.terminate(error: error, source: "control failed")
      case .cancelled:
        if let stream { self?.traceStream(stream, event: "control cancelled") }
        self?.terminate(error: nil, source: "control cancelled")
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

  public var isClosed: Bool { state.withLock { $0.closed } }

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
        self.mailbox.post(
          .control(
            bytes,
            done: { [weak self] in if more { self?.receiveControl(stream) } }
          )
        )
      } else if error == nil, !isComplete {
        self.receiveControl(stream)
      }
      if let error {
        self.traceStream(stream, event: "control receive failed \(error)")
        self.terminate(error: error, source: "control receive failed")
      } else if isComplete {
        // Peer finished the control stream: orderly end of connection.
        self.traceStream(stream, event: "control EOF")
        self.terminate(error: nil, source: "control EOF")
      }
    }
  }

  /// Admits at most 32 control sends, each bounded to one encoded record.
  /// Cancellation returns promptly; an accepted write keeps its credit until
  /// Network finishes processing it and may still reach the peer.
  public func sendControl(_ record: [UInt8]) async throws {
    try await sendControl(record, write: nil)
  }

  /// Test seam for a Network write whose contentProcessed callback is delayed.
  typealias ControlWrite =
    @Sendable (NWConnection, Data, @escaping @Sendable (NWError?) -> Void) ->
    Void

  func sendControl(_ record: [UInt8], write: ControlWrite?) async throws {
    guard record.count <= RSTLimits.maxControlRecordBytes + 4 else {
      throw RSTTransportError.resourceLimit
    }
    guard !Task.isCancelled else { throw RSTTransportError.canceled }
    let id = UUID()
    try state.withLock { s in
      guard !s.closed else { throw RSTTransportError.closed }
      guard s.controlSends.count < Self.maxPendingControlSends else {
        throw RSTTransportError.resourceLimit
      }
      s.controlSends[id] = ControlSend()
    }
    defer {
      state.withLock { s in
        if s.controlSends[id]?.writing == false {
          s.controlSends.removeValue(forKey: id)
        }
      }
    }
    try await withTaskCancellationHandler {
      let stream = try await controlStream(send: id)
      guard !Task.isCancelled else { throw RSTTransportError.canceled }
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let completed: @Sendable (NWError?) -> Void = { [weak self] error in
          self?.finishControlSend(id, error: error)
        }
        let error = state.withLock { s -> RSTTransportError? in
          guard !s.closed else { return .closed }
          guard s.controlSends[id] != nil else { return .canceled }
          s.controlSends[id]?.writing = true
          s.controlSends[id]?.completion = continuation
          // Publish in admission order before cancellation can resume the
          // caller and allow its next write to overtake this accepted record.
          controlWrites.async {
            if let write {
              write(stream, Data(record), completed)
            } else {
              stream.send(
                content: Data(record),
                completion: .contentProcessed(completed)
              )
            }
          }
          return nil
        }
        if let error { continuation.resume(throwing: error) }
      }
    } onCancel: { [weak self] in
      self?.cancelControlSend(id)
    }
  }

  private func controlStream(send id: UUID) async throws -> NWConnection {
    // Server before the client's first control stream arrived.
    try await withCheckedThrowingContinuation { continuation in
      let immediate = state.withLock { s -> Result<NWConnection, any Error>? in
        if s.closed { return .failure(RSTTransportError.closed) }
        guard s.controlSends[id] != nil else {
          return .failure(RSTTransportError.canceled)
        }
        if let control = s.control { return .success(control) }
        s.controlSends[id]?.waiter = continuation
        return nil
      }
      if let immediate { continuation.resume(with: immediate) }
    }
  }

  private func cancelControlSend(_ id: UUID) {
    let canceled = state.withLock { s -> ControlSend? in
      guard let entry = s.controlSends[id] else { return nil }
      if entry.writing {
        // The shared stream's accepted bytes cannot be individually reset.
        // Keep their credit until Network's completion, even if the caller leaves.
        s.controlSends[id]?.completion = nil
      } else {
        s.controlSends.removeValue(forKey: id)
      }
      return entry
    }
    canceled?.waiter?.resume(throwing: RSTTransportError.canceled)
    canceled?.completion?.resume(throwing: RSTTransportError.canceled)
  }

  private func finishControlSend(_ id: UUID, error: NWError?) {
    let entry = state.withLock { $0.controlSends.removeValue(forKey: id) }
    if let error {
      entry?.completion?.resume(throwing: error)
    } else {
      entry?.completion?.resume()
    }
  }

  /// At most eight unfinished sends (including stream creation) are admitted.
  /// Additional sends fail with `resourceLimit`; completed stream history has
  /// a separate bound for later resets.
  public func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {
    try await sendSnapshot(payload, stream: id, beforeRegistration: nil)
  }

  /// Test seam for cancellation while Network creates a stream.
  func sendSnapshot(
    _ payload: [UInt8],
    stream id: UInt64,
    beforeRegistration: (@Sendable () -> Void)?,
    beforeStreamCreation: (@Sendable () async -> Void)? = nil,
    beforeWrite: (@Sendable () -> Void)? = nil,
    write: ControlWrite? = nil
  ) async throws {
    guard role == .server else { throw RSTTransportError.notStarted }
    guard payload.count <= SnapshotStreamAccumulator.hardLimit else {
      throw RSTTransportError.snapshotTooLarge
    }
    guard !Task.isCancelled else { throw RSTTransportError.canceled }
    let canceled = try state.withLock { s -> Bool in
      if s.closed { throw RSTTransportError.closed }
      if s.takePreCancellation(id) { return true }
      guard s.admittedSnapshotSends < Self.maxPendingSnapshotSends else {
        throw RSTTransportError.resourceLimit
      }
      s.admittedSnapshotSends += 1
      return false
    }
    if canceled { throw RSTTransportError.canceled }
    defer { state.withLock { $0.admittedSnapshotSends -= 1 } }
    await beforeStreamCreation?()
    guard !Task.isCancelled else { throw RSTTransportError.canceled }
    guard !state.withLock({ $0.closed }) else { throw RSTTransportError.closed }
    guard
      let stream = NWConnection(
        from: group,
        using: QUICOptions.unidirectionalStream()
      )
    else { throw RSTTransportError.closed }

    beforeRegistration?()

    stream.stateUpdateHandler = { [weak self, weak stream] newState in
      guard let stream else { return }
      self?
        .traceStream(stream, event: "outbound state \(newState),snapshot=\(id)")
      switch newState {
      case let .failed(error):
        self?.finishOutbound(id: id, stream: stream, error: error)
      case .cancelled:
        self?
          .finishOutbound(
            id: id,
            stream: stream,
            error: RSTTransportError.canceled
          )
      default: break
      }
    }
    let previous: OutboundSnapshot?
    do {
      previous = try state.withLock { s in
        guard !s.closed else { throw RSTTransportError.closed }
        guard !s.takePreCancellation(id) else {
          throw RSTTransportError.canceled
        }
        let previous = s.outbound.updateValue(
          OutboundSnapshot(stream: stream),
          forKey: id
        )
        s.outboundOrder.removeAll { $0 == id }
        s.outboundOrder.append(id)
        return previous
      }
    } catch {
      stream.cancel()
      throw error
    }
    if let previous {
      parkOrReset(previous)
      previous.continuation?.resume(throwing: RSTTransportError.canceled)
    }
    stream.start(queue: queue)

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let admission = state.withLock { s -> SnapshotWriteAdmission? in
          guard let entry = s.outbound[id], entry.stream === stream else {
            return nil
          }
          s.outbound[id]?.continuation = continuation
          return entry.writeAdmission
        }
        guard let admission else {
          continuation.resume(throwing: RSTTransportError.canceled)
          return
        }
        beforeWrite?()
        let completed: @Sendable (NWError?) -> Void = {
          [weak self, weak stream] error in
          guard let stream else { return }
          self?.sendCompleted(id: id, stream: stream, error: error)
        }
        let bytes = Data(payload)
        admission.perform {
          traceStream(
            stream,
            event: "outbound write,snapshot=\(id),bytes=\(payload.count)"
          )
          if let write {
            write(stream, bytes, completed)
          } else {
            stream.send(
              content: bytes,
              contentContext: .finalMessage,
              isComplete: true,
              completion: .contentProcessed(completed)
            )
          }
        }
      }
    } onCancel: { [weak self] in
      self?.cancelSnapshot(stream: id, matching: stream)
    }
  }

  var pendingSnapshotSendsForTesting: Int {
    state.withLock { $0.outbound.values.count { $0.continuation != nil } }
  }

  func snapshotStreamForTesting(_ id: UInt64) -> NWConnection? {
    state.withLock { $0.outbound[id]?.stream }
  }

  func enableSnapshotReadDiagnosticsForTesting() {
    traceSnapshotReads.store(true, ordering: .relaxed)
  }

  var snapshotReadBytesForTesting: [Int] {
    state.withLock { $0.snapshotReads.values.map(\.bytes) }
  }

  /// Captures application bookkeeping and native stream state before a
  /// stalled test cancels its send. Read Network properties outside our lock.
  var snapshotDiagnosticsForTesting: String {
    let snapshot = state.withLock { $0 }
    let outbound = snapshot.outbound.sorted { $0.key < $1.key }
      .map { id, entry in
        let metadata =
          entry.stream.metadata(definition: NWProtocolQUIC.definition)
          as? NWProtocolQUIC.Metadata
        return
          "\(id):\(entry.stream.state),nativeID=\(String(describing: metadata?.streamIdentifier)),"
          + "sent=\(entry.sent),waiting=\(entry.continuation != nil)"
      }
    let inbound = snapshot.inbound
      .map { id, stream in
        let metadata =
          stream.metadata(definition: NWProtocolQUIC.definition)
          as? NWProtocolQUIC.Metadata
        let progress = snapshot.snapshotReads[id]
        return
          "\(stream.state),nativeID=\(String(describing: metadata?.streamIdentifier)),"
          + "read=\(String(describing: progress))"
      }
      .sorted()
    let control = snapshot.control.map { String(describing: $0.state) } ?? "nil"
    let metadata =
      snapshot.control?.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    return "closed=\(snapshot.closed),group=\(group.state),control=\(control),"
      + "termination=\(snapshot.termination ?? "none"),"
      + "nativeTermination=\(snapshot.nativeTermination ?? "none"),"
      + "lifecycle=\(snapshot.streamLifecycle),"
      + "admitted=\(snapshot.admittedSnapshotSends),outbound=\(outbound),"
      + "inbound=\(inbound),released=\(snapshot.releasedSnapshotStreams),"
      + "localMaxStreams=\(String(describing: metadata?.localMaxStreamsUnidirectional)),"
      + "remoteMaxStreams=\(String(describing: metadata?.remoteMaxStreamsUnidirectional))"
  }

  private func sendCompleted(id: UInt64, stream: NWConnection, error: NWError?)
  {
    traceStream(
      stream,
      event: "outbound sent,snapshot=\(id),error=\(String(describing: error))"
    )
    let (continuation, evicted, reset) = state.withLock {
      s -> (
        CheckedContinuation<Void, any Error>?, [NWConnection], NWConnection?
      ) in
      let parked = s.parkedResets.removeValue(forKey: ObjectIdentifier(stream))
      guard var entry = s.outbound[id], entry.stream === stream else {
        return (nil, [], parked)
      }
      let c = entry.continuation
      entry.continuation = nil
      if entry.resetAfterSend {
        s.outbound.removeValue(forKey: id)
        s.outboundOrder.removeAll { $0 == id }
        return (nil, Self.evictSentSnapshots(&s), stream)
      }
      entry.sent = true
      s.outbound[id] = entry
      return (c, Self.evictSentSnapshots(&s), parked)
    }
    // Leave the send completion before cancelling. Cancelling on this stack
    // aborts the connection group.
    if let reset { scheduleSnapshotReset(reset) }
    for stream in evicted { queue.async { stream.cancel() } }
    if let error {
      continuation?.resume(throwing: error)
    } else {
      continuation?.resume()
    }
  }

  private func finishOutbound(
    id: UInt64,
    stream: NWConnection,
    error: any Error
  ) {
    let removed = state.withLock { s -> OutboundSnapshot? in
      guard let entry = s.outbound[id], entry.stream === stream else {
        return nil
      }
      s.outbound.removeValue(forKey: id)
      s.outboundOrder.removeAll { $0 == id }
      return entry
    }
    _ = removed?.writeAdmission.cancel()
    if let stream = removed?.stream { queue.async { stream.cancel() } }
    removed?.continuation?.resume(throwing: error)
  }

  /// Abandons a superseded snapshot stream with application error
  /// `snapshotCanceledCode`. Data already handed to QUIC may still reach
  /// the client as a complete payload, which is harmless; a truncated or
  /// reset stream is discarded by the client's exact-length check.
  ///
  /// A stream whose native send has not completed yet is reset from that
  /// send's completion, on a later queue turn. Calling `cancel()` — or
  /// `forceCancel()` — while the send is still inside Network aborts the
  /// connection group (ECONNABORTED / EINVAL on the sibling control stream).
  public func cancelSnapshot(stream id: UInt64) {
    cancelSnapshot(stream: id, matching: nil)
  }

  private func cancelSnapshot(stream id: UInt64, matching stream: NWConnection?)
  {
    guard role == .server else { return }
    let decision = state.withLock { s -> SnapshotReset in
      if let stream, s.outbound[id]?.stream !== stream { return .absent }
      guard var entry = s.outbound[id] else {
        if !s.closed, !s.preCanceled.contains(id) {
          // Keep recent registration races without flushing unrelated
          // cancellations when the history reaches its capacity.
          if s.preCanceled.count == Self.maxPreCanceledSnapshots {
            s.preCanceled.removeFirst()
          }
          s.preCanceled.append(id)
        }
        return .absent
      }
      if entry.resetAfterSend { return .absent }
      let continuation = entry.continuation
      entry.continuation = nil
      if entry.sent {
        s.outbound.removeValue(forKey: id)
        s.outboundOrder.removeAll { $0 == id }
        return .now(entry.stream, continuation)
      }
      entry.resetAfterSend = true
      s.outbound[id] = entry
      return .afterSend(entry.writeAdmission, id, entry.stream, continuation)
    }
    switch decision {
    case .absent: return
    case let .now(stream, continuation):
      continuation?.resume(throwing: RSTTransportError.canceled)
      scheduleSnapshotReset(stream)
    case let .afterSend(admission, id, stream, continuation):
      continuation?.resume(throwing: RSTTransportError.canceled)
      guard !admission.cancel() else { return }
      let pending = state.withLock { s -> NWConnection? in
        guard let entry = s.outbound[id], entry.stream === stream,
          entry.resetAfterSend, !entry.sent
        else { return nil }
        s.outbound.removeValue(forKey: id)
        s.outboundOrder.removeAll { $0 == id }
        return stream
      }
      if let pending { scheduleSnapshotReset(pending) }
    }
  }

  private enum SnapshotReset {
    case absent
    case now(NWConnection, CheckedContinuation<Void, any Error>?)
    case afterSend(
      SnapshotWriteAdmission,
      UInt64,
      NWConnection,
      CheckedContinuation<Void, any Error>?
    )
  }

  private static func evictSentSnapshots(_ state: inout State) -> [NWConnection]
  {
    var evicted: [NWConnection] = []
    while state.outboundOrder.count > Self.maxTrackedOutbound,
      let oldest = state.outboundOrder.first(where: {
        state.outbound[$0]?.sent == true
      })
    {
      state.outboundOrder.removeAll { $0 == oldest }
      if let entry = state.outbound.removeValue(forKey: oldest) {
        evicted.append(entry.stream)
      }
    }
    return evicted
  }

  /// Resets `stream` after the current Network callback returns.
  private func scheduleSnapshotReset(_ stream: NWConnection) {
    queue.async { [weak self] in
      guard let self else {
        stream.cancel()
        return
      }
      let metadata =
        stream.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
      self.traceStream(
        stream,
        event:
          "outbound reset,state=\(stream.state),metadata=\(metadata == nil ? "unavailable" : "available")"
      )
      if case .ready = stream.state, let metadata {
        metadata.streamApplicationErrorCode = Self.snapshotCanceledCode
      }
      stream.cancel()
    }
  }

  /// The previous snapshot id was replaced. Reset it immediately when no
  /// native send is outstanding; otherwise wait for that send's completion.
  private func parkOrReset(_ previous: OutboundSnapshot) {
    let submitted = previous.writeAdmission.cancel()
    if previous.sent || !submitted {
      scheduleSnapshotReset(previous.stream)
      return
    }
    state.withLock { s in
      s.parkedResets[ObjectIdentifier(previous.stream)] = previous.stream
    }
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
        from: group,
        using: QUICOptions.unidirectionalStream()
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
    if traceSnapshotReads.load(ordering: .relaxed) {
      state.withLock { s in
        let id = ObjectIdentifier(stream)
        guard s.inbound[id] != nil else { return }
        s.snapshotReads[id, default: SnapshotReadProgress()].pending = true
      }
    }
    stream.receive(
      minimumIncompleteLength: 1,
      maximumLength: accumulator.nextReadLimit
    ) { [weak self] data, _, isComplete, error in
      guard let self else {
        stream.cancel()
        return
      }
      self.traceStream(
        stream,
        event:
          "receive complete=\(isComplete),bytes=\(data?.count ?? 0),error=\(String(describing: error))"
      )
      if self.traceSnapshotReads.load(ordering: .relaxed) {
        self.state.withLock { s in
          let id = ObjectIdentifier(stream)
          guard s.inbound[id] != nil else { return }
          var progress = s.snapshotReads[id] ?? SnapshotReadProgress()
          progress.callbacks += 1
          progress.bytes += data?.count ?? 0
          progress.pending = false
          progress.complete = isComplete
          s.snapshotReads[id] = progress
        }
      }
      var accumulator = accumulator
      if error != nil {
        // Reset or failed: discard whatever arrived. The stream is already
        // terminated by the peer, so only release it locally. Do that on
        // the next queue turn; cancelling inside this callback aborts the group.
        self.releaseInbound(stream, reject: false)
        return
      }
      if let data, !data.isEmpty {
        do { try accumulator.append(data) } catch {
          self.releaseInbound(stream, reject: true)
          return
        }
      }
      guard isComplete else {
        self.readSnapshot(from: stream, into: accumulator)
        return
      }
      guard let payload = try? accumulator.finish() else {
        self.releaseInbound(stream, reject: true)
        return
      }
      // Keep the stream (and its stream credit) until delivered, so
      // undelivered snapshots stay bounded by the QUIC stream limit.
      self.mailbox.post(
        .snapshot(
          payload,
          done: { [weak self] in
            guard let self else {
              stream.cancel()
              return
            }
            self.releaseInbound(stream, reject: false)
          }
        )
      )
    }
  }

  /// QUIC `MAX_STREAMS` is a cumulative count, and Network framework does
  /// not raise it as streams close: without this the server could open
  /// only `concurrentSnapshotStreams` snapshots per connection. Each
  /// released stream extends the limit by one.
  /// The test hook holds an older update after its limit check, verifying
  /// that Network preserves the larger limit when another return wins.
  func releaseSnapshotCredit(
    beforeUpdateForTesting: (@Sendable () -> Void)? = nil
  ) {
    let (control, released) = state.withLock { s -> (NWConnection?, Int) in
      s.releasedSnapshotStreams += 1
      return (s.control, s.releasedSnapshotStreams)
    }
    guard let control,
      let metadata = control.metadata(definition: NWProtocolQUIC.definition)
        as? NWProtocolQUIC.Metadata
    else { return }
    let limit = released + QUICOptions.concurrentSnapshotStreams
    if metadata.localMaxStreamsUnidirectional < limit {
      beforeUpdateForTesting?()
      metadata.localMaxStreamsUnidirectional = limit
    }
  }

  private func releaseInbound(_ stream: NWConnection, reject: Bool) {
    queue.async { [weak self] in
      guard let self else {
        stream.cancel()
        return
      }
      if reject {
        self.discard(stream)
      } else {
        self.forget(inbound: stream)
        stream.cancel()
      }
      self.releaseSnapshotCredit()
    }
  }

  private func discard(_ stream: NWConnection) {
    forget(inbound: stream)
    finishReject(stream)
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
    terminate(error: nil, graceful: true, source: "local close")
  }

  /// Idempotent teardown: fails waiters and pending sends, cancels the
  /// group (and with it every stream), and delivers `onClosed` once.
  func terminate(
    error: (any Error)?,
    graceful: Bool = false,
    source: String = "external"
  ) {
    let snapshot = state.withLock { s -> State? in
      guard !s.closed else { return nil }
      s.closed = true
      s.termination =
        source + ": " + String(String(describing: error).prefix(256))
      let copy = s
      s.control = nil
      s.controlSends = [:]
      s.outbound = [:]
      s.outboundOrder = []
      s.parkedResets.removeAll()
      s.preCanceled.removeAll()
      s.inbound = [:]
      s.snapshotReads = [:]
      s.beforeInboundStartForTesting = nil
      s.onViabilityChange = nil
      s.onBetterPath = nil
      s.onTerminated = nil
      return copy
    }
    guard let snapshot else { return }
    // Inspect retained native objects outside our lock and before cancelling
    // them. Later callbacks must not replace the first termination record.
    let metadata =
      group.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    let controlMetadata =
      snapshot.control?.metadata(definition: NWProtocolQUIC.definition)
      as? NWProtocolQUIC.Metadata
    let applicationError = metadata?.applicationError
    let groupState = String(String(describing: group.state).prefix(128))
    let controlState = String(
      String(describing: snapshot.control?.state).prefix(128)
    )
    let native =
      "group=\(groupState),control=\(controlState),"
      + "nativeApplicationCode=\(String(describing: applicationError?.code)),"
      + "nativeReason=\(String((applicationError?.reason ?? "none").prefix(256))),"
      + "nativeControlApplicationCode=\(String(describing: controlMetadata?.applicationError.code)),"
      + "nativeControlStreamCode=\(String(describing: controlMetadata?.streamApplicationErrorCode))"
    state.withLock { $0.nativeTermination = native }
    for entry in snapshot.controlSends.values {
      entry.waiter?.resume(throwing: RSTTransportError.closed)
      entry.completion?.resume(throwing: RSTTransportError.closed)
    }
    for entry in snapshot.outbound.values {
      _ = entry.writeAdmission.cancel()
      entry.continuation?.resume(throwing: RSTTransportError.closed)
    }
    for stream in snapshot.parkedResets.values { stream.cancel() }
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
