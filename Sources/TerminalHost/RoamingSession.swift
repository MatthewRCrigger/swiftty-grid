#if os(macOS)
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization

/// One roaming session: an RST/1 view of a SwiftMux workspace (spec.inbox.md
/// §1). The SwiftMux service owns the shell, PTY and terminal;
/// this owns only the RST side: the writer and its input ledger, the
/// attachment epoch, and snapshot scheduling for the workspace's active
/// pane.
///
/// Each RST attachment takes the workspace's interactive lease through an
/// in-process SMX client, so the native app and remote clients share one
/// single-writer rule. Detaching releases the lease; the shell keeps
/// running. Never logs tokens, input or terminal contents.
public final class RoamingSession: @unchecked Sendable {
  public enum State: String, Sendable, Hashable {
    case reserved, attached, detached, exited, terminated
  }

  /// Thread-safe summary for the registry and diagnostics.
  public struct Status: Sendable {
    public var state: State
    public var columns: Int
    public var rows: Int
    public var exitStatus: Int32?
    public var everAttached: Bool
    public var lastActivity: ContinuousClock.Instant
    /// Seconds since 1970 of `lastActivity`.
    public var lastActivityWall: Double
    public var exitedAt: ContinuousClock.Instant?
    /// An RST attachment currently holds the workspace lease.
    public var isAttached = false
    /// Every pane of the workspace has exited (from the last layout seen).
    public var allPanesExited = false
  }

  /// Revision high-water marks that a replacement session for the same
  /// workspace must start above, so a warm client's screen store (which
  /// never accepts an older epoch or revision) keeps installing screens.
  public struct Floor: Sendable, Equatable {
    public var epoch: UInt64 = 0
    public var screenRevision: UInt64 = 0
    public var resizeRevision: UInt64 = 0
    public init() {}
  }

  /// Bounded-resource and progress counters (never terminal contents).
  public struct Diagnostics: Sendable, Equatable {
    public var lastAppliedInput: UInt64
    public var pendingInputOperations: Int
    public var resizeRevision: UInt64
    public var screenRevision: UInt64
    public var attachmentEpoch: UInt64
    public var writerFailed: Bool
    public var activePane: PaneID?
  }

  public let id: SessionID
  public var workspace: WorkspaceID { id.workspace }
  let queue: DispatchQueue
  private let service: MuxService
  private let statusBox: Mutex<Status>
  private let encodeQueue = DispatchQueue(
    label: "swiftmux.roaming.snapshot-encode",
    qos: .utility
  )

  /// Called (on the owner queue) when an attached client asks to
  /// terminate; the registry revokes credentials and ends the workspace.
  var onTerminateRequested: (@Sendable (SessionID) -> Void)?

  // MARK: Owner-queue state

  private var ledger: HostInputLedger
  private var attachment: HostAttachment?
  private var mux: MuxLocalSession?
  /// The SMX attachment of `mux`'s lease.
  private var muxAttachment: AttachmentID?
  /// Called once the previous lease is fully released.
  private var afterClose: [() -> Void] = []
  private var closing = false
  private var inputInFlight = false
  /// Increments per attach; only the newest may acquire the lease.
  private var attachGeneration: UInt64 = 0
  /// A refused operation waits for its backoff before resubmission.
  private var retryScheduled = false
  private var epoch: UInt64 = 0
  private var resizeRevision: UInt64 = 0
  private var screenRevision: UInt64 = 0
  private var geometryGeneration: UInt64 = 0
  private var layoutRevision: UInt64 = 0
  private var activePane: PaneID?
  private var exitStatus: Int32?
  private var terminated = false
  private var writerFailed = false
  private var columns: Int
  private var rows: Int
  /// From the attaching credential: a lease held by another frontend may
  /// be taken over (bootstrap `takeover`). Owner queue only.
  private var allowTakeover = false
  /// From the attaching credential: the pane to focus once the lease is
  /// held, and the exact lease generation a takeover may displace.
  private var target: ResumeTarget?

  init(
    id: SessionID,
    service: MuxService,
    grid: GridSize,
    floor: Floor = Floor(),
    pendingInputLimit: Int = RSTLimits.maxPendingInputBytes
  ) {
    epoch = floor.epoch
    screenRevision = floor.screenRevision
    resizeRevision = floor.resizeRevision
    self.id = id
    self.service = service
    columns = grid.columns
    rows = grid.rows
    ledger = HostInputLedger(byteLimit: pendingInputLimit)
    queue = DispatchQueue(label: "swiftmux.roaming", qos: .userInitiated)
    let now = ContinuousClock.now
    statusBox = Mutex(
      Status(
        state: .reserved,
        columns: grid.columns,
        rows: grid.rows,
        exitStatus: nil,
        everAttached: false,
        lastActivity: now,
        lastActivityWall: Date().timeIntervalSince1970,
        exitedAt: nil
      )
    )
  }

  // MARK: Public surface

  public var status: Status { statusBox.withLock { $0 } }

  public var diagnostics: Diagnostics {
    queue.sync {
      Diagnostics(
        lastAppliedInput: ledger.lastApplied,
        pendingInputOperations: ledger.admitted.count,
        resizeRevision: resizeRevision,
        screenRevision: screenRevision,
        attachmentEpoch: epoch,
        writerFailed: writerFailed,
        activePane: activePane
      )
    }
  }

  /// Where a replacement session must start (see `Floor`).
  public var floor: Floor {
    queue.sync {
      var floor = Floor()
      floor.epoch = epoch
      floor.screenRevision = screenRevision
      floor.resizeRevision = resizeRevision
      return floor
    }
  }

  /// The writer currently authorized for input, if any.
  public var writerID: WriterID? { queue.sync { ledger.writerID } }

  /// Installs `writer` for subsequent input (bootstrap create/resume). A
  /// different writer may take over only when no admitted operation is
  /// incomplete.
  public func authorize(
    writer: WriterID
  ) throws(HostInputLedger.Rejection) {
    let result: Result<Void, HostInputLedger.Rejection> = queue.sync {
      do throws(HostInputLedger.Rejection) {
        if ledger.writerID != writer, !inputInFlight {
          // Operations here are written whole or not at all, and none is
          // with the pane now: the old writer's unsent input is dropped,
          // never replayed for the new one.
          ledger.abandonUnsent()
        }
        try ledger.authorize(writer)
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    try result.get()
  }

  /// An owned export of the active pane's screen (diagnostics and tests).
  public func currentSnapshot() async -> ScreenSnapshot? {
    let (pane, stamp) = queue.sync { (activePane, stamp(epoch: epoch)) }
    guard let pane else { return nil }
    return await withCheckedContinuation { continuation in
      service.inspect(pane: pane, { ScreenExporter.export($0, stamp: stamp) }, completion: {
        continuation.resume(returning: $0)
      })
    }
  }

  /// The service ended the workspace: close any attachment.
  func markTerminated() {
    queue.async { [self] in
      guard !terminated else { return }
      terminated = true
      statusBox.withLock { $0.state = .terminated }
      if let a = attachment {
        a.isCurrent = false
        a.closeAfterFlush()
      }
      attachment = nil
      closeMux {}
    }
  }

  // MARK: Attachment entry points (from HostAttachment)

  func attach(
    _ attachment: HostAttachment,
    writer: WriterID,
    takeover: Bool = false,
    target: ResumeTarget? = nil
  ) async -> AttachOutcome<UInt64> {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        // Owner-queue state: read by `acquireLease` on this queue.
        allowTakeover = takeover || target?.expectedLease != nil
        self.target = target
        attachOnQueue(attachment, writer: writer) {
          continuation.resume(returning: $0)
        }
      }
    }
  }

  func receive(_ message: ControlMessage, from attachment: HostAttachment) async
  {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        handle(message, from: attachment)
        continuation.resume()
      }
    }
  }

  func detach(_ attachment: HostAttachment) {
    queue.async { [self] in detachOnQueue(attachment) }
  }

  // MARK: Attach (owner queue)

  private func attachOnQueue(
    _ a: HostAttachment,
    writer: WriterID,
    completion: @escaping (AttachOutcome<UInt64>) -> Void
  ) {
    guard !terminated else { return completion(.failure(.unknownSession)) }
    guard ledger.writerID == writer else {
      return completion(.failure(.unauthorized))
    }
    // Fence: the previous connection closes and its later input is
    // rejected because it is no longer the current attachment. Its lease
    // is released (after any in-flight input) before this one asks.
    if let previous = attachment, previous !== a {
      previous.fence()
      attachment = nil
    }
    // Only the newest attach may acquire: one queued behind an earlier
    // close is superseded and fails instead of orphaning a lease.
    attachGeneration &+= 1
    let generation = attachGeneration
    closeMux { [self] in
      guard generation == attachGeneration else {
        return completion(.failure(.staleEpoch))
      }
      acquireLease(a, writer: writer, generation: generation, completion: completion)
    }
  }

  private func acquireLease(
    _ a: HostAttachment,
    writer: WriterID,
    generation: UInt64,
    completion: @escaping (AttachOutcome<UInt64>) -> Void
  ) {
    guard !terminated else { return completion(.failure(.unknownSession)) }
    let session = MuxLocalSession(queue: queue)
    // Fails this attach without touching a newer one's client.
    let failAttach = { [self] (code: RSTErrorCode) in
      if mux === session {
        closeMux {}
      } else {
        session.close()
      }
      completion(.failure(code))
    }
    let leaseGranted = { [self] (attachment: AttachmentID, ws: WorkspaceSnapshot) in
      guard mux === session, generation == attachGeneration else {
        // Superseded while acquiring: give the lease back.
        session.close()
        return completion(.failure(.staleEpoch))
      }
      self.leaseGranted(a, writer: writer, attachment: attachment, ws, completion)
    }
    session.onEvent = { [weak self, weak session] event in
      guard let self, let session, self.mux === session else { return }
      self.muxEvent(event)
    }
    session.onPaneChanged = { [weak self, weak session] pane in
      guard let self, let session, self.mux === session else { return }
      if pane == self.activePane { self.contentChanged() }
    }
    session.onClosed = { [weak self, weak session] _ in
      guard let self, let session, self.mux === session else { return }
      self.leaseLost(reason: .internalError)
    }
    if let stale = mux {
      // Never two in-process clients for one session.
      mux = nil
      muxAttachment = nil
      stale.close()
    }
    mux = session
    session.connect(to: service, frontend: .native, remote: true)
    let target = WorkspaceSelector.id(workspace)
    session.request(.attach(target)) { [self] result in
      switch result {
      case let .success(.attached(attachment, ws)):
        leaseGranted(attachment, ws)
      case let .failure(error) where error.code == .leaseHeld && allowTakeover:
        // Explicitly requested at bootstrap: name the lease being
        // displaced so a newer holder is never taken over by accident.
        session.request(.listWorkspaces) { [self] list in
          guard case let .success(.workspaces(summaries)) = list,
            let summary = summaries.first(where: { $0.id == workspace })
          else { return failAttach(.unknownSession) }
          // A link names the lease the user agreed to displace; a plain
          // takeover names the one just listed.
          let expected = self.target?.expectedLease ?? summary.leaseGeneration
          session.request(
            .takeover(target, expectedLease: expected)
          ) { [self] result in
            guard case let .success(.attached(attachment, ws)) = result else {
              return failAttach(.writerBusy)
            }
            leaseGranted(attachment, ws)
          }
        }
      case let .failure(error):
        failAttach(Self.code(error))
      case .success:
        failAttach(.internalError)
      }
    }
  }

  private static func code(_ error: MuxError) -> RSTErrorCode {
    switch error.code {
    case .leaseHeld, .alreadyAttached: .writerBusy
    case .notFound: .unknownSession
    case .quiescing: .limitExceeded
    default: .internalError
    }
  }

  private func leaseGranted(
    _ a: HostAttachment,
    writer: WriterID,
    attachment smx: AttachmentID,
    _ ws: WorkspaceSnapshot,
    _ completion: (AttachOutcome<UInt64>) -> Void
  ) {
    muxAttachment = smx
    mux?.resetInput()
    apply(ws)
    if let pane = target?.pane, pane != activePane,
      ws.panes.contains(where: { $0.id == pane })
    {
      // Show the pane an attention link named; layout events follow.
      mux?.request(.focusPane(pane)) { _ in }
    }
    epoch += 1
    attachment = a
    a.epoch = epoch
    a.writerID = writer
    a.scheduler.reset()
    a.exitNoticeSent = false
    touch(state: exitStatus == nil ? .attached : .exited, attached: true)
    statusBox.withLock { $0.isAttached = true }
    a.send(
      .attached(
        .init(
          attachmentEpoch: epoch,
          writerID: writer,
          lastFullyAppliedInputSequence: ledger.lastApplied,
          partialInputSequence: nil,
          resizeRevision: resizeRevision
        )
      )
    )
    completion(.success(epoch))
    pumpInput()
    a.scheduler.markDirty()
    pumpSnapshots(a)
  }

  private func detachOnQueue(_ a: HostAttachment) {
    a.isCurrent = false
    guard attachment === a else { return }
    attachment = nil
    touch(state: exitStatus == nil && !terminated ? .detached : nil)
    statusBox.withLock { $0.isAttached = false }
    closeMux {}
  }

  /// Releases the lease after any in-flight input is answered: input
  /// sent to the service is applied (FIFO), so its outcome must be
  /// recorded before the connection goes away.
  private func closeMux(then next: @escaping () -> Void) {
    afterClose.append(next)
    guard mux != nil else { return drainAfterClose() }
    closing = true
    guard !inputInFlight else { return }
    let closed = mux
    mux = nil
    muxAttachment = nil
    closing = false
    closed?.close()
    drainAfterClose()
  }

  private func drainAfterClose() {
    let pending = afterClose
    afterClose = []
    for next in pending { next() }
  }

  /// The service ended the lease without being asked (another frontend
  /// took over, or the workspace ended).
  private func leaseLost(reason code: RSTErrorCode) {
    // Input the service admitted before releasing the lease was answered
    // first (FIFO); anything later was refused, so nothing is uncertain.
    let lost = mux
    mux = nil
    muxAttachment = nil
    inputInFlight = false
    lost?.close()
    statusBox.withLock { $0.isAttached = false }
    guard let a = attachment else { return }
    attachment = nil
    a.isCurrent = false
    a.fail(code)
    touch(state: exitStatus == nil && !terminated ? .detached : nil)
  }

  private func touch(state: State? = nil, attached: Bool = false) {
    let now = ContinuousClock.now
    let wall = Date().timeIntervalSince1970
    statusBox.withLock { s in
      if s.state == .terminated { return }
      if let state { s.state = state }
      if attached { s.everAttached = true }
      s.lastActivity = now
      s.lastActivityWall = wall
    }
  }

  // MARK: Service events (owner queue)

  private func muxEvent(_ event: MuxEvent) {
    switch event {
    case let .layout(ws): apply(ws)
    case let .paneExited(pane, status, _):
      guard pane == activePane else { return }
      exited(status)
    case .detached:
      // Ask whether the workspace still exists rather than parse text.
      mux?.request(.listWorkspaces) { [self] result in
        if case let .success(.workspaces(list)) = result,
          !list.contains(where: { $0.id == workspace })
        {
          markTerminatedOnQueue()
        } else {
          leaseLost(reason: .writerBusy)
        }
      }
    default: break
    }
  }

  private func markTerminatedOnQueue() {
    terminated = true
    statusBox.withLock { $0.state = .terminated }
    if let a = attachment {
      a.send(.terminated(epoch: a.epoch))
      a.isCurrent = false
      a.closeAfterFlush()
    }
    attachment = nil
    let lost = mux
    mux = nil
    muxAttachment = nil
    lost?.close()
  }

  /// Follows the workspace's active pane.
  private func apply(_ ws: WorkspaceSnapshot) {
    guard ws.id == workspace, ws.layoutRevision >= layoutRevision else {
      return
    }
    layoutRevision = ws.layoutRevision
    let allExited = !ws.panes.isEmpty && ws.panes.allSatisfy { $0.exitStatus != nil }
    statusBox.withLock { $0.allPanesExited = allExited }
    let pane = ws.activeTabSnapshot?.activePane
    let summary = pane.flatMap { ws.pane($0) }
    if let summary {
      columns = summary.columns
      rows = summary.rows
      statusBox.withLock { s in
        s.columns = summary.columns
        s.rows = summary.rows
      }
    }
    if pane != activePane {
      activePane = pane
      exitStatus = nil
      if let status = summary?.exitStatus {
        exited(status)
      } else {
        // The shown pane is live again: the session is no longer exited.
        statusBox.withLock { s in
          guard s.state == .exited else { return }
          s.state = attachment == nil ? .detached : .attached
          s.exitStatus = nil
          s.exitedAt = nil
        }
      }
      contentChanged()
    } else if let status = summary?.exitStatus, exitStatus == nil {
      exited(status)
    }
  }

  private func exited(_ status: Int32) {
    guard exitStatus == nil else { return }
    exitStatus = status
    if !inputInFlight {
      // Admitted but never written: the pane is gone, so retire it.
      for done in ledger.discard(through: ledger.lastAdmitted) {
        acknowledge(done)
      }
    }
    let now = ContinuousClock.now
    statusBox.withLock { s in
      guard s.state != .terminated else { return }
      s.state = .exited
      s.exitStatus = status
      s.exitedAt = now
    }
    contentChanged()
  }

  private func contentChanged() {
    guard let a = attachment, a.isCurrent else { return }
    a.scheduler.markDirty()
    pumpSnapshots(a)
  }

  // MARK: Control messages (owner queue)

  private func handle(_ message: ControlMessage, from a: HostAttachment) {
    guard a === attachment, a.isCurrent else {
      // A fenced attachment: nothing it sends takes effect.
      if case let .input(input) = message {
        a.send(.error(.init(.staleEpoch, sequence: input.sequence)))
      }
      return
    }
    guard let messageEpoch = message.epoch, messageEpoch == a.epoch else {
      if case let .input(input) = message {
        a.send(.error(.init(.staleEpoch, sequence: input.sequence)))
      } else {
        a.send(.error(.init(.staleEpoch)))
      }
      return
    }
    touch()
    switch message {
    case let .input(input):
      admit(input, from: a)
    case let .screenAck(_, revision):
      for stream in a.scheduler.acknowledged(revision: revision) {
        a.connection.cancelSnapshot(stream: stream)
      }
      pumpSnapshots(a)
    case let .ping(_, nonce):
      a.send(.pong(epoch: a.epoch, nonce: nonce))
    case .detach:
      a.send(.detached(epoch: a.epoch))
      detachOnQueue(a)
      a.closeAfterFlush()
    case .terminate:
      a.send(.terminated(epoch: a.epoch))
      detachOnQueue(a)
      a.closeAfterFlush()
      onTerminateRequested?(id)
    default:
      // Server-to-client messages and repeated attaches are violations.
      a.fail(.malformed)
      detachOnQueue(a)
    }
  }

  private func admit(_ input: ControlMessage.Input, from a: HostAttachment) {
    let sequence = input.sequence
    guard exitStatus == nil, !terminated else {
      a.send(.error(.init(.sessionExited, sequence: sequence)))
      return
    }
    guard let writer = a.writerID else { return }
    switch ledger.classify(
      writer: writer,
      sequence: sequence,
      operation: input.operation
    ) {
    case .alreadyApplied:
      a.send(.inputAck(epoch: a.epoch, sequence: sequence))
    case .inProgress:
      // Still queued for the pane; its acknowledgment follows.
      break
    case let .rejected(rejection):
      a.send(.error(.init(RSTErrorCode(rejection), sequence: sequence)))
    case .admit:
      guard !writerFailed else {
        a.send(.error(.init(.internalError, sequence: sequence)))
        return
      }
      // The pane encodes with its authoritative modes when written; the
      // bound is reserved meanwhile so admission stays bounded.
      ledger.reserve(sequence, operation: input.operation)
      pumpInput()
    }
  }

  /// Submits the ledger's head to the pane, one operation at a time, so
  /// a refused operation can be retried without reordering.
  private func pumpInput() {
    guard !inputInFlight, !writerFailed, exitStatus == nil, !retryScheduled,
      let mux, mux.isOpen, let smx = muxAttachment,
      let pane = activePane, let head = ledger.admitted.first
    else { return }
    inputInFlight = true
    let done: (MuxError?) -> Void = { [weak self] error in
      self?.inputAnswered(head.sequence, error)
    }
    switch head.operation {
    case let .committedText(text):
      mux.input(.input(.text(text)), attachment: smx, pane: pane, done)
    case let .paste(text):
      mux.input(.input(.paste(text)), attachment: smx, pane: pane, done)
    case let .key(key):
      let (name, modifiers) = Self.muxKey(key)
      mux.input(.input(.key(name, modifiers)), attachment: smx, pane: pane, done)
    case let .resize(c, r, revision):
      geometryGeneration += 1
      let batch = GeometryBatch(
        layoutRevision: layoutRevision,
        generation: geometryGeneration,
        entries: [.init(pane: pane, columns: c, rows: r)]
      )
      mux.request(.setGeometry(batch)) { [weak self] result in
        guard let self else { return }
        if case .success = result {
          self.columns = c
          self.rows = r
          self.resizeRevision = max(self.resizeRevision + 1, revision)
          self.statusBox.withLock { s in
            s.columns = c
            s.rows = r
          }
        }
        if case let .failure(error) = result {
          done(error)
        } else {
          done(nil)
        }
      }
    }
  }

  private func inputAnswered(_ sequence: UInt64, _ error: MuxError?) {
    inputInFlight = false
    defer {
      // The shown pane exited while this was in flight (`exited` could
      // not retire then): nothing left may reach another pane.
      if exitStatus != nil, ledger.hasPending {
        for done in ledger.discard(through: ledger.lastAdmitted) {
          acknowledge(done)
        }
      }
    }
    var pumpAfterAnswer = false
    // The answer is recorded first, even when the lease is about to be
    // released: an operation the pane took must complete in the ledger,
    // or the next attachment would send it again.
    defer {
      if closing {
        closeMux {}
      } else if pumpAfterAnswer {
        // Next operation on a later turn: a synchronous answer never
        // recurses through `pumpInput`.
        queue.async { [weak self] in self?.pumpInput() }
      }
    }
    guard let error else {
      if let done = ledger.completeHead() { acknowledge(done) }
      pumpAfterAnswer = true
      return
    }
    switch error.code {
    case .resourceLimit, .staleGeometry, .staleRevision:
      // Nothing was written; retry after the pane drains or the layout
      // settles, never in a tight loop.
      guard !closing else { break }
      retryScheduled = true
      queue.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
        self?.retryScheduled = false
        self?.pumpInput()
      }
    case .connectionLost, .notAttached, .staleAttachment:
      // The lease ended; the head stays admitted for the next attachment,
      // which resumes pumping.
      break
    case .paneExited, .notFound:
      // The target pane is gone: everything admitted for it is retired,
      // never delivered to whichever pane is shown next.
      for done in ledger.discard(through: ledger.lastAdmitted) {
        acknowledge(done)
      }
    default:
      // A refusal of this one operation (e.g. malformed for the pane):
      // retire it and continue; the writer stays usable.
      for done in ledger.discard(through: sequence) { acknowledge(done) }
      pumpAfterAnswer = true
    }
  }

  private func acknowledge(_ sequence: UInt64) {
    guard let a = attachment, a.isCurrent else { return }
    a.send(.inputAck(epoch: a.epoch, sequence: sequence))
  }

  static func muxKey(_ key: SemanticKey) -> (MuxKey, MuxKeyModifiers) {
    var modifiers: MuxKeyModifiers = []
    if key.modifiers.contains(.shift) { modifiers.insert(.shift) }
    if key.modifiers.contains(.alt) { modifiers.insert(.alt) }
    if key.modifiers.contains(.control) { modifiers.insert(.control) }
    let name: MuxKey =
      switch key.name {
      case let .character(scalar): .character(scalar.value)
      case .enter: .enter
      case .tab: .tab
      case .backspace: .backspace
      case .escape: .escape
      case .up: .up
      case .down: .down
      case .left: .left
      case .right: .right
      case .home: .home
      case .end: .end
      case .pageUp: .pageUp
      case .pageDown: .pageDown
      case .insert: .insert
      case .delete: .delete
      case let .function(n): .function(n)
      }
    return (name, modifiers)
  }

  // MARK: Snapshots (owner queue)

  private func stamp(epoch: UInt64) -> ScreenExporter.Stamp {
    ScreenExporter.Stamp(
      sessionID: id,
      attachmentEpoch: epoch,
      screenRevision: screenRevision,
      resizeRevision: resizeRevision,
      lastFullyAppliedInputSequence: ledger.lastApplied
    )
  }

  private func pumpSnapshots(_ a: HostAttachment) {
    guard a === attachment, a.isCurrent, let pane = activePane else { return }
    let now = ContinuousClock.now
    switch a.scheduler.next(now: now) {
    case .idle:
      return
    case let .wait(until):
      guard !a.timerArmed else { return }
      a.timerArmed = true
      let delay = now.duration(to: until)
      queue.asyncAfter(deadline: .now() + delay.dispatchInterval) {
        [weak self, a] in
        a.timerArmed = false
        self?.pumpSnapshots(a)
      }
    case let .capture(cancel):
      if let cancel { a.connection.cancelSnapshot(stream: cancel) }
      screenRevision += 1
      let stamp = stamp(epoch: a.epoch)
      a.nextStreamID += 1
      let stream = a.nextStreamID
      a.scheduler.started(stream: stream, revision: stamp.screenRevision)
      let exit = exitStatus
      // Exported in the pane's order, so every byte parsed before this
      // point (including final output after exit) is included.
      service.inspect(pane: pane, { ScreenExporter.export($0, stamp: stamp) }, completion: {
        [weak self] snapshot in
        self?.queue.async {
          self?.captured(snapshot, stream: stream, exit: exit, to: a)
        }
      })
    }
  }

  private func captured(
    _ snapshot: ScreenSnapshot?,
    stream: UInt64,
    exit: Int32?,
    to a: HostAttachment
  ) {
    guard a === attachment, a.isCurrent else { return }
    guard let snapshot else {
      a.scheduler.failed(stream: stream)
      return
    }
    if let exit, !a.exitNoticeSent {
      a.exitNoticeSent = true
      a.send(
        .sessionExited(
          epoch: a.epoch,
          status: exit,
          finalScreenRevision: snapshot.screenRevision
        )
      )
    }
    transmit(snapshot, stream: stream, to: a)
  }

  /// Encodes off the owner queue, then sends on a new snapshot stream.
  private func transmit(
    _ snapshot: ScreenSnapshot,
    stream: UInt64,
    to a: HostAttachment
  ) {
    encodeQueue.async { [weak self] in
      guard let payload = try? SnapshotFrame.encode(snapshot) else { return }
      Task {
        do {
          try await a.connection.sendSnapshot(payload, stream: stream)
        } catch {
          guard let self else { return }
          self.queue.async {
            guard a === self.attachment, a.isCurrent else { return }
            a.scheduler.failed(stream: stream)
            if (error as? RSTTransportError) != .closed {
              self.pumpSnapshots(a)
            }
          }
        }
      }
    }
  }
}

extension Duration {
  var dispatchInterval: DispatchTimeInterval {
    let (seconds, attoseconds) = components
    let nanos = seconds.multipliedReportingOverflow(by: 1_000_000_000)
    guard !nanos.overflow, seconds >= 0 else {
      return seconds < 0 ? .nanoseconds(0) : .never
    }
    return .nanoseconds(Int(nanos.partialValue + attoseconds / 1_000_000_000))
  }
}
#endif
