import Foundation
import ScreenProtocol
import SessionCore
import SwifttyCore

/// The direct-client RST/1 state machine (spec §8, §9): the single
/// serialized owner of one roaming session's attachment, input queue and
/// screen store.
///
///     idle -> sshBootstrap -> attaching -> active
///     active -> suspect -> reconnecting -> attaching -> active
///     active -> backgroundDetached -> attaching -> active
///     any -> sessionExited / sessionLost / userClosed
///
/// Input is accepted only while `active`, which requires a complete
/// current snapshot of the present attachment. Refused input is reported,
/// never queued offline or echoed. Submitted operations survive warm
/// reconnects and are retried with their original sequence numbers under
/// the new epoch; they are never replayed into a different session.
///
/// Bearer tokens stay in this actor's memory and are never logged or
/// exposed through `status`.
public actor RoamingClient {
  typealias Instant = ContinuousClock.Instant

  struct DecodedScreen: Sendable {
    var snapshot: ScreenSnapshot
    var frame: PresentationFrame
  }

  enum AttachOutcome: Sendable {
    case active
    case unreachable
    case closed
    case timedOut
    case rejected(RSTErrorCode)
    case protocolViolation
    case cancelled
  }

  enum RefreshOutcome { case granted, retry, stop }

  let bootstrapper: any RemoteBootstrapper
  let connector: any RSTConnector
  let sink: (any PresentationSink)?
  let configuration: RoamingClientConfiguration
  let timing: SurfaceTiming

  // Session.
  private var lifecycle = ClientLifecycle()
  private var grant: BootstrapGrant?
  private var queue: ClientInputQueue?
  private var store: RemoteScreenStore?
  private var needsFreshGrant = false
  private var exitStatus: Int32?

  // Connection; every handler is scoped to `connectionGeneration`.
  private var connection: (any RSTConnection)?
  private var connectionGeneration: UInt64 = 0
  private var reader = ControlRecordReader()
  private var epoch: UInt64?
  private var earlySnapshot: DecodedScreen?
  private var outbox: [[UInt8]] = []
  private var pumpGeneration: UInt64?

  // Attachment attempts: at most one at a time.
  private var connectTask: Task<Void, Never>?
  private var connectTaskID: UInt64 = 0
  private var attachWaiter: CheckedContinuation<AttachOutcome, Never>?
  private var attachTimeoutTask: Task<Void, Never>?
  private var backoff: ReconnectBackoff
  private var random = SystemRandomNumberGenerator()
  private var failedAttempts = 0

  // Liveness.
  private var liveness = LivenessPolicy()
  private var livenessTask: Task<Void, Never>?
  private var lastHeardAt: Instant
  private var lastSentAt: Instant
  private var inputAwaitingSince: Instant?
  private var probeSentAt: Instant?
  private var ping: (nonce: UInt64, sentAt: Instant)?
  private var nextNonce: UInt64 = 1

  // Input and grid.
  private var resendFrom: UInt64?
  private var resizeRevision: UInt64 = 0
  private var desiredGrid: GridSize?
  private var requestedGrid: GridSize?

  // Detach / terminate.
  private var closeWaiter: CheckedContinuation<Void, Never>?
  private var closeTimeoutTask: Task<Void, Never>?

  // Status.
  private var currentStatus = RoamingStatus()
  private var statusHandler: (@Sendable (RoamingStatus) -> Void)?
  private var lastFailure: RoamingFailure?
  private var lastScreenAt: Date?
  private var refusedInputCount = 0

  public init(
    bootstrapper: any RemoteBootstrapper,
    connector: any RSTConnector,
    sink: (any PresentationSink)? = nil,
    configuration: RoamingClientConfiguration = .init(),
    timing: SurfaceTiming = .system
  ) {
    self.bootstrapper = bootstrapper
    self.connector = connector
    self.sink = sink
    self.configuration = configuration
    self.timing = timing
    backoff = ReconnectBackoff(jitter: configuration.backoffJitter)
    let now = timing.now()
    lastHeardAt = now
    lastSentAt = now
  }

  // MARK: Public interface

  /// Current status: no secrets, safe for UI and the companion bridge.
  public var status: RoamingStatus { currentStatus }

  public var state: ClientConnectionState { lifecycle.state }

  /// Called on this actor after every status change. Must not block.
  public func setStatusHandler(_ handler: (@Sendable (RoamingStatus) -> Void)?) {
    statusHandler = handler
    handler?(currentStatus)
  }

  /// Bootstraps through SSH (`create`, or `resume` after a cold launch)
  /// and begins attaching. Returns once credentials were granted; the
  /// attachment proceeds in the background and becomes `active` after the
  /// first complete screen. May be called again after a failed bootstrap.
  public func start(_ target: RoamingTarget) async throws(RoamingClientError) {
    let state = lifecycle.state
    guard state == .idle || (state == .sshBootstrap && grant == nil) else {
      throw .invalidState(state)
    }
    move(to: .sshBootstrap)
    let request: BootstrapRequest
    switch target {
    case let .create(grid):
      desiredGrid = desiredGrid ?? grid
      request = BootstrapRequest(operation: .create, initialGrid: grid)
    case let .resume(id):
      request = BootstrapRequest(
        operation: .resume,
        sessionID: id,
        initialGrid: desiredGrid
      )
    case let .reveal(id, revealed):
      request = BootstrapRequest(
        operation: .resume,
        sessionID: id,
        initialGrid: desiredGrid,
        target: revealed
      )
    }
    let response: BootstrapResponse
    do {
      response = try await bootstrapper.bootstrap(request)
    } catch {
      let failure = Self.failure(for: error)
      noteFailure(failure)
      throw Self.clientError(for: failure)
    }
    guard lifecycle.state == .sshBootstrap, grant == nil else {
      throw .invalidState(lifecycle.state)
    }
    switch response {
    case let .granted(granted):
      guard Self.isUsable(granted),
        target.sessionID.map({ $0 == granted.sessionID }) ?? true
      else {
        noteFailure(.protocolViolation)
        throw .protocolViolation
      }
      grant = granted
      queue = ClientInputQueue(writerID: granted.writerID)
      store = RemoteScreenStore(sessionID: granted.sessionID)
      if desiredGrid == nil { desiredGrid = granted.initialGrid }
      publish()
    case .failure(.unknownSession):
      enterFinal(.sessionLost)
      throw .sessionLost
    case .failure(.sessionExited):
      enterFinal(.sessionExited)
      throw .sessionExited
    case let .failure(code):
      noteFailure(.bootstrapRejected(code))
      throw .rejected(code)
    case .sessions, .terminated, .metadata:
      noteFailure(.protocolViolation)
      throw .protocolViolation
    }
    startLiveness()
    ensureConnecting(delayFirst: false)
  }

  /// Submits semantic input. Accepted only while `active`.
  @discardableResult
  public func submit(_ input: SurfaceInput) -> SurfaceInputResult {
    let state = lifecycle.state
    guard state == .active, var queue, let epoch, connection != nil else {
      refusedInputCount += 1
      publish()
      return .refused(state.isTerminal ? .closed : .notActive(state))
    }
    let entry: ClientInputQueue.Entry
    do {
      entry = try queue.enqueue(input.operation)
    } catch .full {
      return .refused(.backpressure)
    } catch {
      return .refused(.invalid)
    }
    self.queue = queue
    sendInput(entry, epoch: epoch)
    publish()
    return .accepted(sequence: entry.sequence)
  }

  /// Requests a grid from local view geometry. Sent as a `.resize`
  /// operation with an increasing resize revision once active; the
  /// displayed grid changes only with the host's snapshots.
  public func proposeGrid(columns: Int, rows: Int) {
    let grid = GridSize(columns: columns, rows: rows)
    guard grid.isValid else { return }
    desiredGrid = grid
    maybeSendGrid()
    publish()
  }

  /// Scene backgrounded or unavailable: stop input, attempt a bounded
  /// detach, then stop networking (spec §9).
  public func enterBackground() async {
    let state = lifecycle.state
    guard !state.isTerminal, state != .idle, state != .backgroundDetached
    else { return }
    cancelConnecting()
    let gen = connectionGeneration
    let attachedEpoch = connection != nil ? epoch : nil
    if !move(to: .backgroundDetached) {
      // sshBootstrap cannot detach; stop networking and resume later.
      dropConnection()
      publish()
      return
    }
    if let attachedEpoch {
      send(.detach(epoch: attachedEpoch))
      await waitForClose()
    }
    if connectionGeneration == gen { dropConnection() }
    publish()
  }

  /// Scene foregrounded: reconnect as needed; input waits for a complete
  /// current screen.
  public func enterForeground() {
    switch lifecycle.state {
    case .backgroundDetached:
      if needsFreshGrant || tokenExpired {
        move(to: .sshBootstrap)
      } else {
        move(to: .attaching)
      }
      ensureConnecting(delayFirst: false)
    case .sshBootstrap, .reconnecting, .attaching:
      if grant != nil { ensureConnecting(delayFirst: false) }
    case .active, .suspect:
      sendProbe()
    default: break
    }
    publish()
  }

  /// Recovery from system sleep; also a user-initiated retry.
  public func wake() { enterForeground() }

  /// A network path change: probe the connection. Not evidence that it
  /// failed (spec §9).
  public func pathChanged() {
    switch lifecycle.state {
    case .active: sendProbe()
    case .reconnecting: backoff.reset()
    default: break
    }
    publish()
  }

  /// Explicit close: `Detach` keeps the host shell, `Terminate` destroys
  /// it. Bounded by `detachDeadline`. Idempotent.
  public func close(_ mode: RoamingCloseMode = .detach) async {
    let state = lifecycle.state
    guard state != .userClosed else { return }
    cancelConnecting()
    if state.isTerminal {
      dropConnection()
      stopLiveness()
      return
    }
    let gen = connectionGeneration
    let attachedEpoch = connection != nil ? epoch : nil
    let sessionID = grant?.sessionID
    move(to: .userClosed)
    stopLiveness()
    if let attachedEpoch {
      send(
        mode == .detach
          ? .detach(epoch: attachedEpoch) : .terminate(epoch: attachedEpoch)
      )
      await waitForClose()
    } else if mode == .terminate, let sessionID {
      await terminateThroughSSH(sessionID)
    }
    if connectionGeneration == gen { dropConnection() }
    publish()
  }

  // MARK: Connecting

  private var wantsConnection: Bool {
    switch lifecycle.state {
    case .sshBootstrap, .attaching, .reconnecting: grant != nil
    default: false
    }
  }

  private var tokenExpired: Bool {
    guard let grant else { return false }
    let margin = Double(configuration.tokenRefreshMargin.components.seconds)
    return timing.wallClock() >= grant.tokenExpiresAt - margin
  }

  private func ensureConnecting(delayFirst: Bool) {
    guard connectTask == nil, wantsConnection else { return }
    connectTaskID &+= 1
    let id = connectTaskID
    connectTask = Task { await self.connectLoop(delayFirst: delayFirst, id: id) }
  }

  private func cancelConnecting() {
    connectTask?.cancel()
    connectTask = nil
    connectTaskID &+= 1
    finishAttach(.cancelled)
  }

  private func connectLoop(delayFirst: Bool, id: UInt64) async {
    defer { if connectTaskID == id { connectTask = nil } }
    var delay = delayFirst
    while !Task.isCancelled, connectTaskID == id, wantsConnection {
      if delay {
        let seconds = backoff.nextDelay(using: &random)
        publish()
        do {
          try await timing.sleep(.milliseconds(Int64(seconds * 1000)))
        } catch { return }
        guard !Task.isCancelled, connectTaskID == id, wantsConnection else {
          return
        }
      }
      delay = true
      if needsFreshGrant || tokenExpired {
        switch await refreshGrant() {
        case .granted: break
        case .retry: continue
        case .stop: return
        }
        guard !Task.isCancelled, connectTaskID == id, wantsConnection else {
          return
        }
      }
      guard let grant else { return }
      let outcome = await attachOnce(grant)
      guard connectTaskID == id else { return }
      switch outcome {
      case .active, .cancelled:
        return
      case let .rejected(code):
        dropConnection()
        switch code {
        case .unknownSession, .wrongInstance:
          enterFinal(.sessionLost)
          return
        case .sessionExited:
          enterFinal(.sessionExited)
          return
        case .expired, .unauthorized:
          needsFreshGrant = true
        default: break
        }
        attemptFailed(.attachRejected(code))
      case .unreachable: attemptFailed(.unreachable)
      case .closed: attemptFailed(.connectionLost)
      case .timedOut: attemptFailed(.attachTimedOut)
      case .protocolViolation: attemptFailed(.protocolViolation)
      }
    }
  }

  private func attemptFailed(_ failure: RoamingFailure) {
    dropConnection()
    failedAttempts += 1
    // Repeated failures may mean the helper restarted: ask SSH, which
    // distinguishes "unreachable" from "session no longer exists".
    if failedAttempts % 3 == 0 { needsFreshGrant = true }
    noteFailure(failure)
    move(to: .reconnecting)
  }

  /// One connect + `Attach` + first current snapshot.
  private func attachOnce(_ grant: BootstrapGrant) async -> AttachOutcome {
    move(to: .attaching)
    guard lifecycle.state == .attaching else { return .cancelled }
    let gen = connectionGeneration
    let conn: any RSTConnection
    do {
      conn = try await connector.connect(to: grant)
    } catch {
      return .unreachable
    }
    guard !Task.isCancelled, lifecycle.state == .attaching,
      connectionGeneration == gen
    else {
      conn.close()
      return .cancelled
    }
    adopt(conn)
    // The connector returns only after the authenticated handshake, so
    // the capability is sent to the pinned peer only.
    send(
      .attach(
        .init(
          sessionID: grant.sessionID,
          serverInstanceID: grant.serverInstanceID,
          writerID: queue?.writerID ?? grant.writerID,
          applicationToken: grant.applicationToken
        )
      )
    )
    let attachGen = connectionGeneration
    let timeout = configuration.attachTimeout
    let timing = timing
    return await withCheckedContinuation { continuation in
      attachWaiter = continuation
      attachTimeoutTask = Task { [weak self] in
        do { try await timing.sleep(timeout) } catch { return }
        await self?.attachTimedOut(generation: attachGen)
      }
    }
  }

  private func attachTimedOut(generation: UInt64) {
    guard generation == connectionGeneration else { return }
    finishAttach(.timedOut)
  }

  private func finishAttach(_ outcome: AttachOutcome) {
    attachTimeoutTask?.cancel()
    attachTimeoutTask = nil
    guard let waiter = attachWaiter else { return }
    attachWaiter = nil
    waiter.resume(returning: outcome)
  }

  /// Fresh credentials through SSH `resume`, keeping the writer identity
  /// while this process still holds its input queue.
  private func refreshGrant() async -> RefreshOutcome {
    guard let sessionID = grant?.sessionID else { return .stop }
    move(to: .sshBootstrap)
    let request = BootstrapRequest(
      operation: .resume,
      sessionID: sessionID,
      writerID: queue?.writerID,
      initialGrid: desiredGrid
    )
    let response: BootstrapResponse
    do {
      response = try await bootstrapper.bootstrap(request)
    } catch {
      let failure = Self.failure(for: error)
      noteFailure(failure)
      switch failure {
      // A changed host key or failed login blocks automatic retries.
      case .hostKeyRejected, .authenticationFailed: return .stop
      default: return .retry
      }
    }
    guard wantsConnection else { return .stop }
    switch response {
    case let .granted(granted):
      guard Self.isUsable(granted), granted.sessionID == sessionID else {
        noteFailure(.protocolViolation)
        return .retry
      }
      if var queue, granted.writerID != queue.writerID {
        let abandoned = queue.entries.count
        queue.resetWriter(granted.writerID)
        self.queue = queue
        if abandoned > 0 { noteFailure(.pendingInputAbandoned(count: abandoned)) }
      }
      grant = granted
      needsFreshGrant = false
      return .granted
    case .failure(.unknownSession):
      enterFinal(.sessionLost)
      return .stop
    case .failure(.sessionExited):
      enterFinal(.sessionExited)
      return .stop
    case let .failure(code):
      noteFailure(.bootstrapRejected(code))
      return .retry
    case .sessions, .terminated, .metadata:
      noteFailure(.protocolViolation)
      return .retry
    }
  }

  private func terminateThroughSSH(_ sessionID: SessionID) async {
    let bootstrapper = bootstrapper
    let timing = timing
    let deadline = configuration.detachDeadline
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        _ = try? await bootstrapper.bootstrap(
          BootstrapRequest(operation: .terminate, sessionID: sessionID)
        )
      }
      group.addTask { try? await timing.sleep(deadline) }
      await group.next()
      group.cancelAll()
    }
  }

  // MARK: Connection plumbing

  private func adopt(_ conn: any RSTConnection) {
    connectionGeneration &+= 1
    let gen = connectionGeneration
    connection = conn
    reader = ControlRecordReader()
    outbox = []
    pumpGeneration = nil
    epoch = nil
    earlySnapshot = nil
    ping = nil
    probeSentAt = nil
    inputAwaitingSince = nil
    resendFrom = nil
    let now = timing.now()
    lastHeardAt = now
    lastSentAt = now
    conn.start(
      RSTConnectionHandler(
        onControl: { [weak self] bytes in
          await self?.handleControl(bytes, generation: gen)
        },
        onSnapshot: { [weak self] bytes in
          // Decode, validate and map off the actor and the UI executor.
          let decoded = Self.decode(bytes)
          await self?.handleSnapshot(decoded, generation: gen)
        },
        onClosed: { [weak self] _ in
          Task { await self?.connectionClosed(generation: gen) }
        }
      )
    )
  }

  private func dropConnection() {
    if let connection {
      connectionGeneration &+= 1
      connection.close()
    }
    connection = nil
    outbox = []
    pumpGeneration = nil
    epoch = nil
    earlySnapshot = nil
    ping = nil
    probeSentAt = nil
    inputAwaitingSince = nil
    resumeCloseWaiter()
  }

  private func connectionClosed(generation: UInt64) {
    guard generation == connectionGeneration else { return }
    if attachWaiter != nil {
      finishAttach(.closed)
      return
    }
    resumeCloseWaiter()
    switch lifecycle.state {
    case .active, .suspect: reconnect(after: .connectionLost)
    default: dropConnection()
    }
    publish()
  }

  private func reconnect(after failure: RoamingFailure) {
    dropConnection()
    noteFailure(failure)
    move(to: .reconnecting)
    ensureConnecting(delayFirst: true)
  }

  /// Bounded, ordered control-record output: one pump per connection.
  private func send(_ message: ControlMessage) {
    guard let conn = connection else { return }
    guard let record = try? ControlRecord.encode(message) else { return }
    guard outbox.count < configuration.maxOutboundRecords else {
      connectionFailed(.connectionLost)
      return
    }
    outbox.append(record)
    lastSentAt = timing.now()
    let gen = connectionGeneration
    guard pumpGeneration != gen else { return }
    pumpGeneration = gen
    Task { await self.pump(conn, generation: gen) }
  }

  private func pump(_ conn: any RSTConnection, generation gen: UInt64) async {
    while gen == connectionGeneration, !outbox.isEmpty {
      let record = outbox.removeFirst()
      do {
        try await conn.sendControl(record)
      } catch {
        if pumpGeneration == gen { pumpGeneration = nil }
        connectionClosed(generation: gen)
        return
      }
    }
    if pumpGeneration == gen { pumpGeneration = nil }
  }

  private func connectionFailed(_ failure: RoamingFailure) {
    if attachWaiter != nil {
      finishAttach(failure == .protocolViolation ? .protocolViolation : .closed)
    } else if lifecycle.state == .active || lifecycle.state == .suspect {
      reconnect(after: failure)
    } else {
      dropConnection()
    }
  }

  // MARK: Receiving

  private func handleControl(_ bytes: [UInt8], generation: UInt64) {
    guard generation == connectionGeneration else { return }
    let messages: [ControlMessage]
    do {
      messages = try reader.append(bytes)
    } catch {
      connectionFailed(.protocolViolation)
      publish()
      return
    }
    heard()
    for message in messages {
      guard generation == connectionGeneration else { break }
      handle(message)
    }
    publish()
  }

  private func heard() {
    lastHeardAt = timing.now()
    if lifecycle.state == .suspect, epoch != nil {
      probeSentAt = nil
      move(to: .active)
    }
  }

  private func handle(_ message: ControlMessage) {
    switch message {
    case let .attached(attached):
      handleAttached(attached)
    case let .inputAck(e, sequence):
      guard e == epoch, var queue else { return }
      queue.acknowledge(through: sequence)
      self.queue = queue
      inputAwaitingSince = queue.isEmpty ? nil : timing.now()
      if resendFrom != nil { resendRefused() }
      maybeSendGrid()
    case let .pong(e, nonce):
      guard e == epoch, let ping, ping.nonce == nonce else { return }
      liveness.sample(timing.now() - ping.sentAt)
      self.ping = nil
      probeSentAt = nil
    case let .ping(e, nonce):
      guard e == epoch else { return }
      send(.pong(epoch: e, nonce: nonce))
    case let .sessionExited(e, status, _):
      guard e == epoch else { return }
      exitStatus = status
      // Keep the connection: the final screen may still arrive.
      enterFinal(.sessionExited, keepConnection: true)
    case let .detached(e), let .terminated(e):
      guard e == epoch else { return }
      resumeCloseWaiter()
    case let .error(error):
      handleError(error)
    case .attach, .input, .screenAck, .detach, .terminate:
      // Client-to-server messages are never valid from the host.
      connectionFailed(.protocolViolation)
    }
  }

  private func handleAttached(_ attached: ControlMessage.Attached) {
    guard attachWaiter != nil, epoch == nil, var queue, var store else {
      connectionFailed(.protocolViolation)
      return
    }
    guard attached.writerID == queue.writerID,
      attached.lastFullyAppliedInputSequence < queue.nextSequence
    else {
      finishAttach(.protocolViolation)
      return
    }
    epoch = attached.attachmentEpoch
    store.fence(epoch: attached.attachmentEpoch)
    self.store = store
    resizeRevision = max(resizeRevision, attached.resizeRevision)
    // Retry what the host has not applied: original identifiers, new
    // epoch. Admitted partial operations continue at the host.
    let retry = queue.reconcile(serverApplied: attached.lastFullyAppliedInputSequence)
    self.queue = queue
    for entry in retry { sendInput(entry, epoch: attached.attachmentEpoch) }
    if let early = earlySnapshot {
      earlySnapshot = nil
      install(early)
    }
  }

  private func handleError(_ error: ControlMessage.RSTError) {
    if attachWaiter != nil {
      finishAttach(.rejected(error.code))
      return
    }
    switch error.code {
    case .inputBackpressure, .inputGap:
      let from = error.sequence ?? queue?.entries.first?.sequence
      if let from { resendFrom = min(resendFrom ?? from, from) }
    case .unknownSession, .wrongInstance:
      enterFinal(.sessionLost)
    case .sessionExited:
      enterFinal(.sessionExited, keepConnection: true)
    case .expired, .unauthorized:
      needsFreshGrant = true
      reconnect(after: .attachRejected(error.code))
    default:
      // Reattachment reconciles input from the host's ledger.
      reconnect(after: .attachRejected(error.code))
    }
  }

  private func handleSnapshot(_ decoded: DecodedScreen?, generation: UInt64) {
    guard generation == connectionGeneration else { return }
    heard()
    guard let decoded else {
      noteFailure(.snapshotRejected)
      publish()
      return
    }
    if epoch == nil {
      // Snapshot stream overtook `Attached`; keep only the newest.
      earlySnapshot = decoded
      return
    }
    install(decoded)
    publish()
  }

  private func install(_ decoded: DecodedScreen) {
    guard var store, let epoch else { return }
    switch store.install(decoded.snapshot) {
    case .installed:
      self.store = store
      send(.screenAck(epoch: epoch, screenRevision: decoded.snapshot.screenRevision))
      resizeRevision = max(resizeRevision, decoded.snapshot.resizeRevision)
      lastScreenAt = Date(timeIntervalSince1970: timing.wallClock())
      sink?.install(decoded.frame)
      if attachWaiter != nil, decoded.snapshot.attachmentEpoch == epoch {
        // A complete current screen: input may resume.
        move(to: .active)
        backoff.reset()
        failedAttempts = 0
        lastFailure = nil
        finishAttach(.active)
        maybeSendGrid()
      }
    case .stale:
      break
    case .rejected:
      noteFailure(.snapshotRejected)
    }
  }

  nonisolated static func decode(_ bytes: [UInt8]) -> DecodedScreen? {
    guard let snapshot = try? SnapshotFrame.decode(bytes) else { return nil }
    return DecodedScreen(snapshot: snapshot, frame: PresentationMapper.map(snapshot))
  }

  // MARK: Input

  private func sendInput(_ entry: ClientInputQueue.Entry, epoch: UInt64) {
    send(
      .input(
        .init(
          attachmentEpoch: epoch,
          sequence: entry.sequence,
          operation: entry.operation
        )
      )
    )
    if inputAwaitingSince == nil { inputAwaitingSince = timing.now() }
  }

  /// Resends from the refused sequence once the host made progress.
  private func resendRefused() {
    guard let from = resendFrom, let epoch, let queue else { return }
    resendFrom = nil
    for entry in queue.entries where entry.sequence >= from {
      sendInput(entry, epoch: epoch)
    }
  }

  private func maybeSendGrid() {
    guard lifecycle.state == .active, let desired = desiredGrid, let epoch,
      var queue, let screen = store?.current
    else { return }
    let reference =
      requestedGrid ?? GridSize(columns: screen.columns, rows: screen.rows)
    guard desired != reference else { return }
    let revision = max(resizeRevision, screen.resizeRevision) + 1
    let operation = InputOperation.resize(
      columns: desired.columns,
      rows: desired.rows,
      resizeRevision: revision
    )
    // When full, retried after the next acknowledgment.
    guard let entry = try? queue.enqueue(operation) else { return }
    self.queue = queue
    resizeRevision = revision
    requestedGrid = desired
    sendInput(entry, epoch: epoch)
  }

  // MARK: Liveness

  private func startLiveness() {
    guard livenessTask == nil else { return }
    let tick = configuration.livenessTick
    let timing = timing
    livenessTask = Task { [weak self] in
      while true {
        do { try await timing.sleep(tick) } catch { return }
        guard let self, await self.tick() else { return }
      }
    }
  }

  private func stopLiveness() {
    livenessTask?.cancel()
    livenessTask = nil
  }

  /// Heartbeats and staleness (spec §9). Returns false once finished.
  private func tick() -> Bool {
    let state = lifecycle.state
    if state.isTerminal { return false }
    guard connection != nil, epoch != nil else { return true }
    let now = timing.now()
    let timeout = liveness.staleTimeout
    switch state {
    case .active:
      let start = [inputAwaitingSince, probeSentAt].compactMap { $0 }.min()
      if let start, liveness.isStale(awaitingResponseFor: now - max(start, lastHeardAt)) {
        noteFailure(.stale)
        move(to: .suspect)
        sendProbe()
      } else if ping == nil,
        now - max(lastSentAt, lastHeardAt) >= configuration.heartbeatInterval
      {
        sendPing()
      } else if let from = resendFrom, queue?.entries.first?.sequence == from {
        // Nothing earlier is pending at the host: resend now.
        resendRefused()
      }
    case .suspect:
      if let sent = probeSentAt, now - sent > timeout {
        reconnect(after: .stale)
      } else if probeSentAt == nil {
        sendProbe()
      }
    default: break
    }
    publish()
    return true
  }

  private func sendPing() {
    guard let epoch else { return }
    let nonce = nextNonce
    nextNonce &+= 1
    ping = (nonce, timing.now())
    send(.ping(epoch: epoch, nonce: nonce))
  }

  /// A ping whose response is awaited for staleness.
  private func sendProbe() {
    guard epoch != nil, connection != nil else { return }
    probeSentAt = timing.now()
    sendPing()
  }

  // MARK: Closing

  private func waitForClose() async {
    let deadline = configuration.detachDeadline
    let timing = timing
    await withCheckedContinuation { continuation in
      closeWaiter = continuation
      closeTimeoutTask = Task { [weak self] in
        try? await timing.sleep(deadline)
        await self?.resumeCloseWaiter()
      }
    }
  }

  private func resumeCloseWaiter() {
    closeTimeoutTask?.cancel()
    closeTimeoutTask = nil
    guard let waiter = closeWaiter else { return }
    closeWaiter = nil
    waiter.resume()
  }

  private func enterFinal(
    _ state: ClientConnectionState,
    keepConnection: Bool = false
  ) {
    cancelConnecting()
    if !keepConnection { dropConnection() }
    move(to: state)
    stopLiveness()
    publish()
  }

  // MARK: State and status

  @discardableResult
  private func move(to next: ClientConnectionState) -> Bool {
    do {
      try lifecycle.transition(to: next)
    } catch {
      return false
    }
    publish()
    return true
  }

  private func noteFailure(_ failure: RoamingFailure) {
    lastFailure = failure
    publish()
  }

  private func publish() {
    let next = RoamingStatus(
      state: lifecycle.state,
      sessionID: grant?.sessionID,
      lastScreenAt: lastScreenAt,
      screenRevision: store?.current?.screenRevision,
      pendingInputCount: queue?.entries.count ?? 0,
      refusedInputCount: refusedInputCount,
      title: store?.current?.title ?? "",
      exitStatus: exitStatus,
      lastFailure: lastFailure,
      reconnectAttempt: backoff.attempt
    )
    guard next != currentStatus else { return }
    currentStatus = next
    statusHandler?(next)
  }

  private static func isUsable(_ grant: BootstrapGrant) -> Bool {
    grant.protocol == RSTLimits.protocolName && grant.initialGrid.isValid
  }

  private static func failure(for error: any Error) -> RoamingFailure {
    switch error as? RemoteBootstrapError {
    case .hostKeyRejected: .hostKeyRejected
    case .authenticationFailed: .authenticationFailed
    case .protocolViolation: .protocolViolation
    case .unreachable, nil: .unreachable
    }
  }

  private static func clientError(for failure: RoamingFailure) -> RoamingClientError {
    switch failure {
    case .hostKeyRejected: .hostKeyRejected
    case .authenticationFailed: .authenticationFailed
    case .protocolViolation: .protocolViolation
    default: .unreachable
    }
  }
}

extension RoamingTarget {
  var sessionID: SessionID? {
    switch self {
    case let .resume(id), let .reveal(id, _): id
    case .create: nil
    }
  }
}
