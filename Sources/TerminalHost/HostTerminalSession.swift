#if os(macOS)
import Darwin
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import SwifttyCore
import Synchronization

/// One retained host session (spec §4, §6, §8, §A.5): a PTY and
/// shell process group, the authoritative Swiftty emulator, the input
/// ledger and a tracked nonblocking PTY writer, all coordinated by one
/// serial owner queue.
///
/// The emulator runs in externally fed mode: the owner reads the PTY and
/// feeds the `TerminalSession` itself, so output parsing, terminal
/// replies, input admission and PTY writes happen in one order. Replies
/// raised while parsing (on the terminal's own queue) are collected and
/// join the writer after the parse returns, between operations, never
/// inside an operation's bytes; they are never sent to a client.
///
/// Attachments come and go; losing one never signals the shell. The
/// shell starts on the first successful attachment.
public final class HostTerminalSession: @unchecked Sendable {
  public enum State: String, Sendable, Hashable {
    case reserved, attached, detached, exited, terminated
  }

  /// Thread-safe summary for the registry and diagnostics.
  public struct Status: Sendable {
    public var state: State
    public var pid: pid_t?
    public var columns: Int
    public var rows: Int
    public var exitStatus: Int32?
    public var everAttached: Bool
    public var lastActivity: ContinuousClock.Instant
    /// Seconds since 1970 of `lastActivity`.
    public var lastActivityWall: Double
    public var exitedAt: ContinuousClock.Instant?
  }

  /// Bounded-resource and progress counters (never terminal contents).
  public struct Diagnostics: Sendable, Equatable {
    public var bytesRead: UInt64
    public var historyRows: Int
    public var pendingReplyBytes: Int
    public var pendingInputBytes: Int
    public var lastAppliedInput: UInt64
    public var partialInputSequence: UInt64?
    public var resizeRevision: UInt64
    public var screenRevision: UInt64
    public var attachmentEpoch: UInt64
    public var writerFailed: Bool
  }

  public let id: SessionID
  let queue: DispatchQueue
  private let terminal: TerminalSession
  private let launch: ShellLaunch
  private let writer: any PTYWriting
  private let statusBox: Mutex<Status>
  /// Replies the emulator generated during the current parse.
  private let replyInbox = Mutex<(chunks: [[UInt8]], bytes: Int)>(([], 0))
  private let encodeQueue = DispatchQueue(
    label: "swifttyd.snapshot-encode",
    qos: .utility
  )

  /// Called (on the owner queue) when an attached client asks to
  /// terminate; the registry revokes credentials and tears down.
  var onTerminateRequested: (@Sendable (SessionID) -> Void)?

  static let readBufferSize = 64 * 1024
  static let readBudget = 1 << 20
  /// Pending terminal replies beyond this are dropped (spec A9).
  static let replyByteLimit = 64 * 1024

  // MARK: Owner-queue state

  private enum WriteItem {
    case input(UInt64)
    case reply([UInt8], offset: Int)
  }

  private var pty: HostPTY?
  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var exitSource: DispatchSourceProcess?
  private var ledger: HostInputLedger
  private var writeQueue: [WriteItem] = []
  private var replyBytes = 0
  private var writerFailed = false
  private var attachment: HostAttachment?
  private var epoch: UInt64 = 0
  private var resizeRevision: UInt64 = 0
  private var screenRevision: UInt64 = 0
  private var exitStatus: Int32?
  private var finalScreenRevision: UInt64?
  private var terminated = false
  private var bytesRead: UInt64 = 0
  private var columns: Int
  private var rows: Int
  private let readBuffer: UnsafeMutableRawBufferPointer

  public init(
    id: SessionID = .random(),
    grid: GridSize,
    launch: ShellLaunch = .loginShell(),
    writer: any PTYWriting = DarwinPTYWriter(),
    palette: Palette = .standard,
    pendingInputLimit: Int = RSTLimits.maxPendingInputBytes
  ) {
    self.id = id
    self.launch = launch
    self.writer = writer
    columns = min(max(grid.columns, 1), RSTLimits.maxColumns)
    rows = min(max(grid.rows, 1), RSTLimits.maxRows)
    ledger = HostInputLedger(byteLimit: pendingInputLimit)
    queue = DispatchQueue(label: "swifttyd.session", qos: .userInitiated)
    // No history: the host keeps current state, not a replay log (§4).
    var configuration = SessionConfiguration()
    configuration.scrollbackLimitBytes = 0
    configuration.scrollbackLimitRows = 0
    configuration.palette = palette
    terminal = TerminalSession(
      columns: columns,
      rows: rows,
      configuration: configuration
    )
    readBuffer = .allocate(byteCount: Self.readBufferSize, alignment: 16)
    let now = ContinuousClock.now
    statusBox = Mutex(
      Status(
        state: .reserved,
        pid: nil,
        columns: columns,
        rows: rows,
        exitStatus: nil,
        everAttached: false,
        lastActivity: now,
        lastActivityWall: Date().timeIntervalSince1970,
        exitedAt: nil
      )
    )
    terminal.onTerminalReply = { [weak self] bytes in
      self?.collectReply(bytes)
    }
  }

  deinit {
    readSource?.cancel()
    if let writeSource { writeSource.cancel() }
    exitSource?.cancel()
    readBuffer.deallocate()
  }

  // MARK: Public surface

  public var status: Status { statusBox.withLock { $0 } }

  public var diagnostics: Diagnostics {
    queue.sync {
      Diagnostics(
        bytesRead: bytesRead,
        historyRows: terminal.withState { $0.retainedHistoryRows },
        pendingReplyBytes: replyBytes,
        pendingInputBytes: ledger.pendingBytes,
        lastAppliedInput: ledger.lastApplied,
        partialInputSequence: ledger.partialSequence,
        resizeRevision: resizeRevision,
        screenRevision: screenRevision,
        attachmentEpoch: epoch,
        writerFailed: writerFailed
      )
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
        try ledger.authorize(writer)
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    try result.get()
  }

  /// An owned export of the current screen (diagnostics and tests).
  public func currentSnapshot() -> ScreenSnapshot {
    queue.sync { capture(epoch: epoch) }
  }

  /// Starts the shell if it has not started yet. Normally triggered by
  /// the first successful attachment.
  public func start() throws {
    let result: Result<Void, any Error> = queue.sync {
      Result { try startIfNeeded() }
    }
    try result.get()
  }

  /// Closes the PTY and terminates the process group with bounded
  /// escalation: SIGHUP, then SIGTERM, then SIGKILL, each phase lasting at
  /// most `grace`. Idempotent; returns when the group is gone or the last
  /// deadline passed.
  public func terminate(grace: Duration = .seconds(2)) async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        terminateOnQueue(grace: grace) { continuation.resume() }
      }
    }
  }

  // MARK: Attachment entry points (from HostAttachment)

  func attach(
    _ attachment: HostAttachment,
    writer: WriterID
  ) async -> AttachOutcome<UInt64> {
    await onQueue { [self] in attachOnQueue(attachment, writer: writer) }
  }

  func receive(_ message: ControlMessage, from attachment: HostAttachment) async
  {
    await onQueue { [self] in handle(message, from: attachment) }
  }

  func detach(_ attachment: HostAttachment) {
    queue.async { [self] in detachOnQueue(attachment) }
  }

  private func onQueue<T: Sendable>(
    _ body: @escaping @Sendable () -> T
  ) async -> T {
    await withCheckedContinuation { continuation in
      queue.async { continuation.resume(returning: body()) }
    }
  }

  // MARK: Lifecycle (owner queue)

  private func startIfNeeded() throws {
    guard pty == nil, exitStatus == nil else { return }
    guard !terminated else { throw HostSessionError.terminated }
    let pty = try HostPTY.spawn(launch, columns: columns, rows: rows)
    self.pty = pty

    let read = DispatchSource.makeReadSource(
      fileDescriptor: pty.master,
      queue: queue
    )
    read.setEventHandler { [weak self] in self?.readAvailable() }
    // The descriptors stay open until every source has finished canceling.
    read.setCancelHandler { withExtendedLifetime(pty) {} }
    read.resume()
    readSource = read

    let exit = DispatchSource.makeProcessSource(
      identifier: pty.pid,
      eventMask: .exit,
      queue: queue
    )
    exit.setEventHandler { [weak self] in self?.childExited() }
    exit.resume()
    exitSource = exit
    statusBox.withLock { $0.pid = pty.pid }
  }

  private func attachOnQueue(
    _ attachment: HostAttachment,
    writer: WriterID
  ) -> AttachOutcome<UInt64> {
    guard !terminated else { return .failure(.unknownSession) }
    guard ledger.writerID == writer else { return .failure(.unauthorized) }
    do {
      try startIfNeeded()
    } catch {
      return .failure(.internalError)
    }
    epoch += 1
    let previous = self.attachment
    self.attachment = attachment
    attachment.epoch = epoch
    attachment.writerID = writer
    attachment.scheduler.reset()
    attachment.exitNoticeSent = false
    // Fence: the previous connection is closed and its later input is
    // rejected because it is no longer the current attachment.
    if let previous, previous !== attachment { previous.fence() }
    touch(state: exitStatus == nil ? .attached : .exited, attached: true)
    attachment.send(
      .attached(
        .init(
          attachmentEpoch: epoch,
          writerID: writer,
          lastFullyAppliedInputSequence: ledger.lastApplied,
          partialInputSequence: ledger.partialSequence,
          resizeRevision: resizeRevision
        )
      )
    )
    pumpSnapshots(attachment)
    return .success(epoch)
  }

  private func detachOnQueue(_ attachment: HostAttachment) {
    attachment.isCurrent = false
    guard self.attachment === attachment else { return }
    self.attachment = nil
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
      // The unwritten suffix continues; its acknowledgment follows.
      break
    case let .rejected(rejection):
      a.send(.error(.init(RSTErrorCode(rejection), sequence: sequence)))
    case .admit:
      guard !writerFailed else {
        a.send(.error(.init(.internalError, sequence: sequence)))
        return
      }
      let bytes = encode(input.operation)
      ledger.record(sequence, operation: input.operation, bytes: bytes)
      writeQueue.append(.input(sequence))
      pumpWriter()
    }
  }

  /// Encodes once with the authoritative modes and keyboard flags.
  private func encode(_ operation: InputOperation) -> [UInt8] {
    let input: TerminalInput
    switch operation {
    case let .committedText(text): input = .text(text)
    case let .paste(text): input = .paste(text)
    case let .key(key): input = .key(Self.keyEvent(key))
    case .resize: return []
    }
    var out: [UInt8] = []
    terminal.withState { state in
      _ = InputEncoder.encode(
        input,
        modes: state.modes,
        keyboardFlags: state.keyboardFlags,
        into: &out
      )
    }
    return out
  }

  static func keyEvent(_ key: SemanticKey) -> KeyEvent {
    var modifiers: KeyModifiers = []
    if key.modifiers.contains(.shift) { modifiers.insert(.shift) }
    if key.modifiers.contains(.alt) { modifiers.insert(.alt) }
    if key.modifiers.contains(.control) { modifiers.insert(.control) }
    let mapped: Key
    var text: String?
    switch key.name {
    case let .character(scalar):
      mapped = .character(scalar)
      text = String(Character(scalar))
    case .enter: mapped = .enter
    case .tab: mapped = .tab
    case .backspace: mapped = .backspace
    case .escape: mapped = .escape
    case .up: mapped = .up
    case .down: mapped = .down
    case .left: mapped = .left
    case .right: mapped = .right
    case .home: mapped = .home
    case .end: mapped = .end
    case .pageUp: mapped = .pageUp
    case .pageDown: mapped = .pageDown
    case .insert: mapped = .insert
    case .delete: mapped = .delete
    case let .function(n): mapped = .function(n)
    }
    return KeyEvent(mapped, modifiers: modifiers, text: text)
  }

  // MARK: PTY output (owner queue)

  private func readAvailable() {
    guard let pty else { return }
    var budget = Self.readBudget
    var fed = false
    while budget > 0 {
      let n = Darwin.read(pty.master, readBuffer.baseAddress, readBuffer.count)
      if n > 0 {
        let bytes = Array(
          UnsafeRawBufferPointer(rebasing: readBuffer[0 ..< n])
        )
        bytesRead &+= UInt64(n)
        terminal.feed(bytes)
        fed = true
        budget -= n
        continue
      }
      if n < 0, errno == EINTR { continue }
      if n < 0, errno == EAGAIN { break }
      // EOF or EIO: no slave remains.
      readSource?.cancel()
      readSource = nil
      break
    }
    if fed {
      takeReplies()
      contentChanged()
    }
  }

  /// Runs on the terminal's queue during `feed`/`mutate`.
  private func collectReply(_ bytes: [UInt8]) {
    replyInbox.withLock { inbox in
      guard inbox.bytes + bytes.count <= Self.replyByteLimit else { return }
      inbox.chunks.append(bytes)
      inbox.bytes += bytes.count
    }
  }

  /// Moves replies raised by the last parse into the ordered writer.
  private func takeReplies() {
    let chunks = replyInbox.withLock { inbox in
      defer { inbox = ([], 0) }
      return inbox.chunks
    }
    guard !chunks.isEmpty else { return }
    for chunk in chunks where !chunk.isEmpty {
      guard replyBytes + chunk.count <= Self.replyByteLimit else { continue }
      replyBytes += chunk.count
      writeQueue.append(.reply(chunk, offset: 0))
    }
    pumpWriter()
  }

  private func contentChanged() {
    guard let a = attachment, a.isCurrent else { return }
    a.scheduler.markDirty()
    pumpSnapshots(a)
  }

  private func childExited() {
    guard let pty, exitStatus == nil else { return }
    readAvailable()
    // Darwin posts NOTE_EXIT just before the child becomes waitable.
    let status = reapChild(pty.pid, blocking: true) ?? -1
    readAvailable()
    exitSource?.cancel()
    exitSource = nil
    exitStatus = status
    terminal.programExited()
    let now = ContinuousClock.now
    statusBox.withLock { s in
      guard s.state != .terminated else { return }
      s.state = .exited
      s.exitStatus = status
      s.exitedAt = now
    }
    // Admitted input that never completed is not acknowledged.
    if let a = attachment, a.isCurrent {
      a.scheduler.markDirty()
      pumpSnapshots(a)
    }
  }

  // MARK: Ordered PTY writer (owner queue)

  private func pumpWriter() {
    guard let pty, !writerFailed else { return }
    while let item = writeQueue.first {
      switch item {
      case let .reply(bytes, offset):
        let result = bytes.withUnsafeBytes { raw in
          writer.write(fd: pty.master, UnsafeRawBufferPointer(rebasing: raw[offset...]))
        }
        switch result {
        case let .wrote(n):
          if offset + n >= bytes.count {
            writeQueue.removeFirst()
            replyBytes -= bytes.count
          } else {
            writeQueue[0] = .reply(bytes, offset: offset + n)
          }
        case .wouldBlock:
          armWriteSource()
          return
        case .failed:
          writerFailure()
          return
        }
      case let .input(sequence):
        guard let next = ledger.nextWrite, next.sequence == sequence else {
          writeQueue.removeFirst()  // cannot happen: ledger and queue agree
          continue
        }
        if next.bytes.isEmpty {
          if let head = ledger.admitted.first,
            case let .resize(c, r, revision) = head.operation
          {
            applyResize(columns: c, rows: r, revision: revision, pty: pty)
          }
          writeQueue.removeFirst()
          if let done = ledger.completeHead() { acknowledge(done) }
          continue
        }
        let result = next.bytes.withUnsafeBytes {
          writer.write(fd: pty.master, $0)
        }
        switch result {
        case let .wrote(n):
          let accepted = min(n, next.bytes.count)
          if accepted > 0, let done = ledger.wrote(accepted) {
            writeQueue.removeFirst()
            acknowledge(done)
          }
        case .wouldBlock:
          armWriteSource()
          return
        case .failed:
          writerFailure()
          return
        }
      }
    }
    disarmWriteSource()
  }

  private func acknowledge(_ sequence: UInt64) {
    guard let a = attachment, a.isCurrent else { return }
    a.send(.inputAck(epoch: a.epoch, sequence: sequence))
  }

  /// An I/O error is never reported as success: pending input stays
  /// unacknowledged and new input is refused.
  private func writerFailure() {
    writerFailed = true
    disarmWriteSource()
    if let a = attachment, a.isCurrent {
      a.send(
        .error(.init(.internalError, sequence: ledger.admitted.first?.sequence))
      )
    }
  }

  private func applyResize(
    columns c: Int,
    rows r: Int,
    revision: UInt64,
    pty: HostPTY
  ) {
    // Emulator first so the application's redraw after SIGWINCH is
    // parsed at the new size.
    terminal.mutate { $0.resize(columns: c, rows: r) }
    _ = pty.resize(columns: c, rows: r)
    columns = c
    rows = r
    resizeRevision = max(resizeRevision + 1, revision)
    statusBox.withLock { s in
      s.columns = c
      s.rows = r
    }
    takeReplies()
    contentChanged()
  }

  private func armWriteSource() {
    guard writeSource == nil, let pty else { return }
    let source = DispatchSource.makeWriteSource(
      fileDescriptor: pty.master,
      queue: queue
    )
    source.setEventHandler { [weak self] in self?.pumpWriter() }
    source.setCancelHandler { withExtendedLifetime(pty) {} }
    source.resume()
    writeSource = source
  }

  private func disarmWriteSource() {
    writeSource?.cancel()
    writeSource = nil
  }

  // MARK: Snapshots (owner queue)

  /// Exports the current screen under a new revision.
  private func capture(epoch: UInt64) -> ScreenSnapshot {
    screenRevision += 1
    let stamp = ScreenExporter.Stamp(
      sessionID: id,
      attachmentEpoch: epoch,
      screenRevision: screenRevision,
      resizeRevision: resizeRevision,
      lastFullyAppliedInputSequence: ledger.lastApplied
    )
    return terminal.withState { ScreenExporter.export($0, stamp: stamp) }
  }

  private func pumpSnapshots(_ a: HostAttachment) {
    guard a === attachment, a.isCurrent else { return }
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
      let snapshot = capture(epoch: a.epoch)
      a.nextStreamID += 1
      let stream = a.nextStreamID
      a.scheduler.started(stream: stream, revision: snapshot.screenRevision)
      if let status = exitStatus, !a.exitNoticeSent {
        a.exitNoticeSent = true
        finalScreenRevision = snapshot.screenRevision
        a.send(
          .sessionExited(
            epoch: a.epoch,
            status: status,
            finalScreenRevision: snapshot.screenRevision
          )
        )
      }
      transmit(snapshot, stream: stream, to: a)
    }
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

  // MARK: Termination (owner queue)

  private func terminateOnQueue(
    grace: Duration,
    completion: @escaping @Sendable () -> Void
  ) {
    guard !terminated else {
      completion()
      return
    }
    terminated = true
    statusBox.withLock { $0.state = .terminated }
    if let a = attachment {
      a.isCurrent = false
      a.closeAfterFlush()
    }
    attachment = nil
    readSource?.cancel()
    readSource = nil
    disarmWriteSource()
    exitSource?.cancel()
    exitSource = nil
    writeQueue = []
    replyBytes = 0
    guard let pty else {
      completion()
      return
    }
    // Close the PTY: the descriptors close once canceled sources finish.
    self.pty = nil
    let pid = pty.pid
    killpg(pid, SIGHUP)
    kill(pid, SIGHUP)
    escalate(
      pid: pid,
      phase: 0,
      deadline: .now() + grace.dispatchInterval,
      grace: grace,
      completion: completion
    )
  }

  private static let escalation: [Int32] = [SIGHUP, SIGTERM, SIGKILL]

  private func escalate(
    pid: pid_t,
    phase: Int,
    deadline: DispatchTime,
    grace: Duration,
    completion: @escaping @Sendable () -> Void
  ) {
    if exitStatus == nil, let status = reapChild(pid, blocking: false) {
      exitStatus = status
      statusBox.withLock { $0.exitStatus = status }
    }
    if killpg(pid, 0) != 0, errno == ESRCH {
      completion()
      return
    }
    if DispatchTime.now() >= deadline {
      let next = phase + 1
      guard next < Self.escalation.count else {
        completion()  // Best effort: the last deadline passed.
        return
      }
      killpg(pid, Self.escalation[next])
      if exitStatus == nil { kill(pid, Self.escalation[next]) }
      escalate(
        pid: pid,
        phase: next,
        deadline: .now() + grace.dispatchInterval,
        grace: grace,
        completion: completion
      )
      return
    }
    queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [self] in
      escalate(
        pid: pid,
        phase: phase,
        deadline: deadline,
        grace: grace,
        completion: completion
      )
    }
  }
}

/// Host session failures that are not wire errors.
public enum HostSessionError: Error, Equatable, Sendable {
  case terminated
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
