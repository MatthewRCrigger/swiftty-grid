import Darwin
import Dispatch
import Foundation
import MuxAttention
import SwiftMuxExport
import SwiftMuxProtocol
import SwifttyEngine
import Synchronization

/// Events a pane reports to the service, on the pane queue.
enum PaneEvent: Sendable {
  case title(String)
  case bell
  case workingDirectory(String)
  /// OSC 7501 changes in stream order, under the terminal epoch they
  /// happened in. Always delivered before `finished`.
  case status(TerminalEpochID, [StatusChange])
  /// Process exited and output drained (or the drain bound elapsed).
  case finished(status: Int32, forced: Bool)
}

/// One PTY, its process lifecycle and its authoritative terminal. Every
/// operation runs on `queue` in order: output parsing, input writes,
/// replies, resizes and frame capture.
final class PaneRuntime: @unchecked Sendable {
  let id: PaneID
  let workspace: WorkspaceID
  let queue: DispatchQueue
  let limits: MuxLimits
  /// This pane's share of the service's logical history budget.
  let historyBytes: Int

  /// Admitted, unwritten input bytes; shared with the service for
  /// admission decisions.
  let outstandingInput = Mutex(0)
  /// Set when a change notification is posted; cleared by the service.
  let changePosted = Atomic(false)

  private struct ResizeRequest: Sendable {
    let columns: Int
    let rows: Int
    let generation: UInt64
  }

  private struct ResizeState: Sendable {
    var pending: ResizeRequest?
    var scheduled = false
  }

  private let resizes = Mutex(ResizeState())

  // Set once before use, read on `queue`.
  var onChange: (@Sendable () -> Void)?
  var onEvent: (@Sendable (PaneEvent) -> Void)?

  // MARK: Queue-owned state

  private var state: TerminalState
  private var parser = Parser()
  private var writer: PaneWriter
  private let observePaneIO: (@Sendable (PaneID, PaneIOObservation) -> Void)?
  private var master: Int32 = -1
  private var slave: Int32 = -1
  private(set) var pid: pid_t = 0
  private var readSource: DispatchSourceRead?
  private var readSourceActive = false
  private var processingRead = false
  private var replyExitPoll: DispatchSourceTimer?
  /// Unparsed bytes in readBuffer, held while reply capacity is exhausted.
  private var bufferedRead = 0 ..< 0
  private var childIsExiting = false
  private var writeSource: DispatchSourceWrite?
  private var writeActive = false
  private var exitSource: DispatchSourceProcess?
  private var exitPoll: DispatchSourceTimer?
  private let readBuffer: UnsafeMutableRawBufferPointer
  private var exitStatus: Int32?
  private var finished = false
  private var forcedTermination = false
  private var terminating = false
  private var naturalDrainDeadline: DispatchTime?
  private var terminationDeadline: DispatchTime?
  private var groupKillSent = false
  private var drainTimer: DispatchWorkItem?
  /// Every committed state change advances this.
  private(set) var revision: UInt64 = 0
  private(set) var geometryGeneration: UInt64 = 0
  private(set) var viewportRevision: UInt64 = 0
  private var title = ""
  /// New on creation and on every full reset (RIS).
  private var terminalEpoch = TerminalEpochID()
  /// Status changes journaled per publish; past it the inbox resyncs
  /// from the records (intermediate transitions are then lost).
  static let statusJournalLimit = 4096

  static let drainBound: DispatchTimeInterval = .seconds(1)
  static let terminateGrace: DispatchTimeInterval = .seconds(2)

  init(
    id: PaneID,
    workspace: WorkspaceID,
    columns: Int,
    rows: Int,
    historyBytes: Int,
    innerTerm: String = SMX.fallbackInnerTerm,
    limits: MuxLimits,
    observingIO: (@Sendable (PaneID, PaneIOObservation) -> Void)? = nil,
  ) {
    self.id = id
    self.workspace = workspace
    self.limits = limits
    observePaneIO = observingIO
    queue = DispatchQueue(
      label: "swiftmux.pane.\(id.short)",
      qos: .userInitiated,
    )
    self.historyBytes = historyBytes
    state = TerminalState(
      columns: columns,
      rows: rows,
      scrollbackLimitBytes: historyBytes,
      scrollbackLimitRows: limits.historyRowsPerPane,
    )
    // The inner identity matches the TERM panes run under; enhanced
    // keyboard reporting and clipboard writes are not offered.
    state.terminalVersion =
      "swmux \(SMX.build.split(separator: "-").last ?? "")"
    state.terminfoName = innerTerm
    state.keyboardProtocolEnabled = false
    state.clipboardWritesAdvertised = false
    // OSC 7501 feeds the attention inbox, hidden or not.
    state.programStatusEnabled = true
    state.programStatusCapacity = limits.statusRecordsPerPane
    state.programStatusJournalLimit = Self.statusJournalLimit
    writer = PaneWriter(replyReserve: limits.replyReserveBytes)
    readBuffer = .allocate(byteCount: limits.readTurnBytes, alignment: 16)
  }

  deinit {
    // Weak source callbacks cannot run once deinitialization starts.
    // Transfer exclusive reaping without retaining the service or PTY.
    exitSource?.cancel()
    exitPoll?.cancel()
    replyExitPoll?.cancel()
    if pid > 0, exitStatus == nil {
      kill(-pid, SIGHUP)
      kill(pid, SIGHUP)
      PTYProcessShutdown.start(pid)
    }
    setReadActive(true)
    readSource?.cancel()
    if let writeSource {
      // Never release a suspended source.
      if !writeActive { writeSource.resume() }
      writeSource.cancel()
    }
    if master >= 0 { close(master) }
    if slave >= 0 { close(slave) }
    readBuffer.deallocate()
  }

  // MARK: Launch

  /// Spawns the pane's process. Call on `queue`.
  func launch(_ spec: LaunchSpec, launcher: PaneLauncher) throws(MuxError) {
    dispatchPrecondition(condition: .onQueue(queue))
    let p = try launcher.launch(
      spec,
      pane: id,
      workspace: workspace,
      columns: state.columns,
      rows: state.rows,
    )
    master = p.master
    slave = p.slave
    pid = p.pid
    let fd = master
    let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    read.setEventHandler { [weak self] in self?.readAvailable() }
    read.resume()
    readSource = read
    readSourceActive = true
    let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    write.setEventHandler { [weak self] in self?.flush() }
    writeSource = write  // resumed only while output is pending
    let exit = DispatchSource.makeProcessSource(
      identifier: pid,
      eventMask: .exit,
      queue: queue,
    )
    exit.setEventHandler { [weak self] in self?.childExited() }
    exit.resume()
    exitSource = exit
    // The child may have exited before the source was armed. Defer the
    // check until this launch turn has queued service registration; it
    // can synchronously drain output and emit the final lifecycle event.
    queue.async { [weak self] in self?.childExited(pollIfNeeded: false) }
  }

  // MARK: Output

  private func readAvailable() {
    guard master >= 0, !processingRead else { return }
    processingRead = true
    defer { processingRead = false }
    var budget = limits.readTurnBytes
    var parsedAny = false
    var sawEOF = false
    while budget > 0 {
      guard enqueueReplies() else {
        setReadActive(false)
        publish()
        return
      }
      setReadActive(true)
      if bufferedRead.isEmpty {
        let n = Darwin.read(
          master,
          readBuffer.baseAddress,
          min(budget, readBuffer.count),
        )
        if n > 0 {
          observeIO(
            .read,
            bytes: UnsafeRawBufferPointer(rebasing: readBuffer[..<n])
          )
          bufferedRead = 0 ..< n
        } else {
          if n < 0, errno == EINTR { continue }
          if n < 0, errno == EAGAIN { break }
          sawEOF = true
          break
        }
      }
      let chunk = UnsafeBufferPointer(
        start: readBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
          + bufferedRead.lowerBound,
        count: bufferedRead.count,
      )
      let consumed = parser.consumePrefix(chunk, into: &state, replyLimit: 1)
      bufferedRead =
        (bufferedRead.lowerBound + consumed) ..< bufferedRead.upperBound
      budget -= consumed
      parsedAny = true
    }
    if parsedAny { publish() }
    if !state.output.isEmpty { setReadActive(false) }
    if sawEOF {
      setReadActive(true)
      readSource?.cancel()
      readSource = nil
      readSourceActive = false
      if exitStatus != nil { finish() }
    }
  }

  /// One complete command can remain pending beyond the writer reserve.
  /// Its reply is retained separately, without parsing more input into it.
  private func enqueueReplies() -> Bool {
    guard !state.output.isEmpty else { return true }
    state.output.withUnsafeBytes { observeIO(.replyGenerated, bytes: $0) }
    if childIsExiting || exitStatus != nil || finished
      || state.output.count > writer.replyReserve
    {
      // Dead children cannot use replies. A custom reserve smaller than
      // one command retains the existing oversized-reply drop policy.
      state.output.withUnsafeBytes { observeIO(.replyDropped, bytes: $0) }
      state.output.removeAll(keepingCapacity: true)
      return true
    }
    guard writer.appendReply(state.output) else { return false }
    state.output.withUnsafeBytes { observeIO(.replyQueued, bytes: $0) }
    state.output.removeAll(keepingCapacity: true)
    flush()
    return true
  }

  private func setReadActive(_ active: Bool) {
    if active {
      replyExitPoll?.cancel()
      replyExitPoll = nil
    }
    guard let readSource, active != readSourceActive else { return }
    readSourceActive = active
    if active {
      readSource.resume()
    } else {
      readSource.suspend()
      pollPausedExit()
    }
  }

  /// Darwin may delay NOTE_EXIT until the controlling terminal drains.
  /// The short BSD record exposes exit-in-progress without a terminal lock.
  private func pollPausedExit() {
    guard replyExitPoll == nil else { return }
    let poll = DispatchSource.makeTimerSource(queue: queue)
    poll.schedule(
      deadline: .now() + .milliseconds(25),
      repeating: .milliseconds(25),
    )
    poll.setEventHandler { [weak self] in
      guard let self, !self.finished, !self.readSourceActive else { return }
      guard PTYProcessExit.hasStartedExiting(self.pid) else { return }
      self.childIsExiting = true
      self.readAvailable()
    }
    replyExitPoll = poll
    poll.resume()
  }

  /// Flushes replies and events, then notifies the service once.
  private func publish() {
    state.refreshSearchIfNeeded()
    _ = enqueueReplies()
    publishStatus()
    // This service does not expose tmux control-mode streams. Drain their
    // bytes with each batch instead of retaining the entire stream.
    state.controlModeData.removeAll(keepingCapacity: true)
    for event in state.takeEvents() {
      switch event {
      case let .title(t):
        title = t
        onEvent?(.title(t))
      case .bell: onEvent?(.bell)
      case let .workingDirectory(d): onEvent?(.workingDirectory(d))
      default: break  // program clipboard writes are disabled
      }
    }
    _ = state.takeDamage()
    noteChange()
  }

  /// Converts the status journal into owned changes, splitting it at
  /// each reset into a new terminal epoch.
  private func publishStatus() {
    guard let journal = state.takeProgramStatusJournal() else { return }
    var batch: [StatusChange] = []
    var epochChanged = false
    for change in journal.changes {
      switch change {
      case let .report(record): batch.append(.report(Self.status(record)))
      case let .removed(ids): batch.append(.removed(ids))
      case .reset:
        if !batch.isEmpty { onEvent?(.status(terminalEpoch, batch)) }
        batch = []
        terminalEpoch = TerminalEpochID()
        epochChanged = true
      }
    }
    if journal.truncated {
      batch.append(.sync(journal.snapshot.records.map(Self.status)))
    }
    if !batch.isEmpty || epochChanged {
      onEvent?(.status(terminalEpoch, batch))
    }
  }

  static func status(_ r: ProgramStatusRecord) -> StatusRecord {
    let state: AttentionState =
      switch r.state {
      case .idle: .idle
      case .working: .working
      case .done: .done
      case .blocked: .blocked
      case .error: .error
      }
    let kind: AttentionBlockedKind? =
      switch r.kind {
      case .permission?: .permission
      case .question?: .question
      case .auth?: .auth
      case nil: nil
      }
    return StatusRecord(
      path: r.id,
      state: state,
      kind: kind,
      progress: r.progress,
      app: r.app,
      title: r.title,
      message: r.message,
    )
  }

  private func noteChange() {
    revision &+= 1
    if !changePosted.exchange(true, ordering: .acquiringAndReleasing) {
      onChange?()
    }
  }

  // MARK: Input

  /// Admission happened in the service; `estimate` was reserved.
  func write(_ input: MuxInput, estimate: Int) {
    queue.async { [self] in
      guard master >= 0, exitStatus == nil else {
        release(estimate)
        return
      }
      var bytes: [UInt8] = []
      let terminalInput: TerminalInput =
        switch input {
        case let .text(s): .text(s)
        case let .key(key, mods):
          .key(KeyEvent(Self.key(key), modifiers: Self.modifiers(mods)))
        case let .focus(f): .focus(f)
        case let .paste(s): .paste(s)
        }
      // Enhanced keyboard reporting is disabled in this profile.
      InputEncoder.encode(
        terminalInput,
        modes: state.modes,
        keyboardFlags: 0,
        into: &bytes,
      )
      if case .focus = input {
      } else if state.viewportOffset != 0 {
        state.scrollViewportToBottom()
        viewportRevision &+= 1
        noteChange()
      }
      adjust(by: bytes.count - estimate)
      writer.appendInput(bytes)
      flush()
    }
  }

  func pasteBegin(id: UInt64, estimate: Int) {
    queue.async { [self] in
      guard master >= 0, !finished, !writer.hasOpenPaste else {
        release(estimate)
        return
      }
      if state.viewportOffset != 0 {
        state.scrollViewportToBottom()
        viewportRevision &+= 1
        noteChange()
      }
      let before = writer.pendingInputBytes
      writer.beginPaste(
        id: id,
        bracketed: state.modes.contains(.bracketedPaste),
      )
      adjust(by: (writer.pendingInputBytes - before) - estimate)
      flush()
    }
  }

  func pasteChunk(id: UInt64, text: String, estimate: Int) {
    queue.async { [self] in
      guard master >= 0, !finished, writer.paste?.id == id else {
        release(estimate)
        return
      }
      let before = writer.pendingInputBytes
      writer.appendPaste(id: id, text: text)
      adjust(by: (writer.pendingInputBytes - before) - estimate)
      flush()
    }
  }

  func pasteEnd(id: UInt64) {
    queue.async { [self] in
      writer.endPaste(id: id)
      flush()
    }
  }

  /// Disconnect, cancellation or limit failure. `completion` reports the
  /// outcome by what reached the program: `partial` once any payload
  /// byte was written (it cannot be rolled back), `aborted` when none was.
  /// A cancelled paste is never `completed`: its sender gave up on the
  /// rest, as the client reports it.
  func pasteCancel(
    id: UInt64,
    completion: @escaping @Sendable (PasteState) -> Void,
  ) {
    queue.async { [self] in
      let (discarded, wrote) = writer.cancelPaste(id: id)
      release(discarded)
      flush()
      completion(wrote ? .partial : .aborted)
    }
  }

  private func flush() {
    guard master >= 0 else { return }
    let fd = master
    guard
      let released = writer.flush({ buffer in
        var offset = 0
        while offset < buffer.count {
          let n = Darwin.write(
            fd,
            buffer.baseAddress! + offset,
            buffer.count - offset,
          )
          if n > 0 {
            observeIO(
              .written,
              bytes: UnsafeRawBufferPointer(
                rebasing: buffer[offset ..< offset + n]
              )
            )
            offset += n
            continue
          }
          if n < 0, errno == EINTR { continue }
          if n < 0, errno == EAGAIN {
            observeIO(
              .writeBlocked,
              bytes: UnsafeRawBufferPointer(rebasing: buffer[offset...]),
              error: errno
            )
            break
          }
          observeIO(
            .writeFailed,
            bytes: UnsafeRawBufferPointer(rebasing: buffer[offset...]),
            error: n < 0 ? errno : nil
          )
          return offset > 0 ? offset : nil
        }
        return offset
      })
    else {
      release(writer.discardAll())
      setWriteActive(false)
      if !readSourceActive { readAvailable() }
      return
    }
    release(released)
    setWriteActive(!writer.isEmpty)
    if !readSourceActive { readAvailable() }
  }

  private func setWriteActive(_ active: Bool) {
    guard let writeSource, active != writeActive else { return }
    writeActive = active
    if active { writeSource.resume() } else { writeSource.suspend() }
  }

  private func observeIO(
    _ phase: PaneIOObservation.Phase,
    bytes: UnsafeRawBufferPointer,
    error: Int32? = nil
  ) {
    guard let observePaneIO else { return }
    observePaneIO(
      id,
      PaneIOObservation(
        phase: phase,
        byteCount: bytes.count,
        prefix: Array(bytes.prefix(256)),
        error: error
      )
    )
  }

  private func release(_ n: Int) { adjust(by: -n) }

  private func adjust(by delta: Int) {
    guard delta != 0 else { return }
    outstandingInput.withLock { $0 = max(0, $0 + delta) }
  }

  /// Reserves credit for admission; false when over the per-pane budget.
  func reserve(_ bytes: Int) -> Bool {
    outstandingInput.withLock { value in
      guard value + bytes <= limits.inputBytesPerPane else { return false }
      value += bytes
      return true
    }
  }

  // MARK: Geometry, history and search

  /// Engine resize, then `TIOCSWINSZ`, in this pane's order.
  func resize(columns: Int, rows: Int, generation: UInt64) {
    let schedule = resizes.withLock { requests in
      requests.pending = ResizeRequest(
        columns: columns,
        rows: rows,
        generation: generation,
      )
      guard !requests.scheduled else { return false }
      requests.scheduled = true
      return true
    }
    if schedule { scheduleResize() }
  }

  /// One running resize and one replaceable pending request. Queue the next
  /// turn at the tail so sustained geometry traffic cannot starve input.
  private func scheduleResize() {
    queue.async { [self] in
      let request = resizes.withLock { requests in
        let request = requests.pending!
        requests.pending = nil
        return request
      }
      applyResize(request)
      let again = resizes.withLock { requests in
        if requests.pending != nil { return true }
        requests.scheduled = false
        return false
      }
      if again { scheduleResize() }
    }
  }

  private func applyResize(_ request: ResizeRequest) {
    geometryGeneration = request.generation
    guard request.columns != state.columns || request.rows != state.rows else {
      noteChange()
      return
    }
    state.resize(columns: request.columns, rows: request.rows)
    if master >= 0 {
      var size = winsize(
        ws_row: UInt16(clamping: state.rows),
        ws_col: UInt16(clamping: state.columns),
        ws_xpixel: 0,
        ws_ypixel: 0,
      )
      _ = ioctl(master, TIOCSWINSZ, &size)
    }
    publish()
  }

  func scroll(
    _ request: ScrollRequest,
    completion: @escaping @Sendable (MuxError?) -> Void,
  ) {
    queue.async { [self] in
      switch request {
      case let .lines(n): state.scrollViewport(by: n)
      case let .pages(n):
        // The engine clamps to history; only the product can overflow.
        let (lines, overflow) = n.multipliedReportingOverflow(
          by: max(1, state.rows - 1),
        )
        state.scrollViewport(by: overflow ? (n < 0 ? .min : .max) : lines)
      case .bottom: state.scrollViewportToBottom()
      case let .top(address):
        guard address.generation == state.addressingGeneration,
          address.alternateScreen == state.isAlternateScreen,
          state.contains(absoluteRow: address.row)
        else {
          completion(MuxError(.historyUnavailable, "history address is stale"))
          return
        }
        state.scrollViewport(by: -state.viewportRow(absoluteRow: address.row))
      }
      viewportRevision &+= 1
      noteChange()
      completion(nil)
    }
  }

  func search(
    _ query: String?,
    step forward: Bool?,
    completion: @escaping @Sendable (SearchResult) -> Void,
  ) {
    queue.async { [self] in
      if let query {
        state.search(query)
        state.selectSearchMatch(forward: false)
      } else if let forward {
        state.selectSearchMatch(forward: forward)
      } else {
        state.endSearch()
      }
      viewportRevision &+= 1
      noteChange()
      completion(
        SearchResult(
          matchCount: state.searchMatches.count,
          selected: state.searchSelected,
        ),
      )
    }
  }

  /// Frontend theme: default colours and scheme, as a theme change does.
  func setTheme(_ theme: MuxTheme) {
    queue.async { [self] in
      var colors = InlineArray<256, UInt32>(repeating: 0)
      for i in 0 ..< 256 { colors[i] = theme.palette.colors[i] }
      let p = theme.palette
      state.setDefaultPalette(
        Palette(
          colors: colors,
          foreground: p.foreground,
          background: p.background,
          cursor: p.cursor,
          cursorText: p.cursorText,
          selectionForeground: p.selectionForeground,
          selectionBackground: p.selectionBackground,
        ),
      )
      state.setColorScheme(theme.dark ? .dark : .light)
      publish()
    }
  }

  /// Returns the viewport to live output and clears search (detach).
  func resetViewport() {
    queue.async { [self] in
      state.endSearch()
      state.scrollViewportToBottom()
      viewportRevision &+= 1
      noteChange()
    }
  }

  // MARK: Frames

  /// Captures cells and metadata in one operation and encodes the frame
  /// message, off the service queue.
  func captureFrame(
    server: ServerInstanceID,
    attachment: AttachmentID,
    layoutRevision: UInt64,
    completion: @escaping @Sendable (Result<(Data, UInt64), MuxError>) -> Void,
  ) {
    queue.async { [self] in
      state.refreshSearchIfNeeded()
      let screen = state.captureOwnedScreen()
      let identity = FrameIdentity(
        server: server,
        attachment: attachment,
        pane: id,
        revision: revision,
        layoutRevision: layoutRevision,
        geometryGeneration: geometryGeneration,
        viewportRevision: viewportRevision,
      )
      do {
        var frame = try FrameExporter.frame(
          from: screen,
          identity: identity,
          limits: limits,
        )
        frame.search?.selected = state.searchSelected
        let data = try SMXCodec.encode(
          ServerMessage.event(.frame(frame)),
          limit: limits.maxFrameBytes,
        )
        completion(.success((data, revision)))
      } catch let error as MuxError { completion(.failure(error)) } catch {
        completion(.failure(MuxError(.resourceLimit, "\(error)")))
      }
    }
  }

  /// Plain text of the visible screen (tests, diagnostics).
  func screenLines() -> [String] { queue.sync { state.screenLines } }

  /// Captures teardown progress in pane order without signaling or reaping.
  func terminationStateForTesting() -> String {
    queue.sync {
      let now = DispatchTime.now().uptimeNanoseconds
      let remaining = terminationDeadline.map {
        $0.uptimeNanoseconds > now ? $0.uptimeNanoseconds - now : 0
      }
      return
        "pid=\(pid) terminating=\(terminating) exit=\(String(describing: exitStatus)) "
        + "finished=\(finished) forced=\(forcedTermination) groupKill=\(groupKillSent) "
        + "graceRemainingNs=\(String(describing: remaining)) drainPending=\(drainTimer != nil)"
    }
  }

  /// Runs `body` in this pane's order with the authoritative state, for
  /// exports other than `PaneFrame` (the roaming bridge's screens).
  func inspect<T: Sendable>(
    _ body: @escaping @Sendable (borrowing TerminalState) -> T,
    completion: @escaping @Sendable (T) -> Void,
  ) { queue.async { [self] in completion(body(state)) } }

  var size: (columns: Int, rows: Int) {
    queue.sync { (state.columns, state.rows) }
  }

  // MARK: Lifetime

  private func childExited(pollIfNeeded: Bool = true) {
    guard exitStatus == nil, !finished else { return }
    if pollIfNeeded {
      // NOTE_EXIT can precede waitability while the controlling terminal
      // drains. Release reply pressure before checking the exit status.
      childIsExiting = true
      readAvailable()
    }
    var info = siginfo_t()
    var peek: Int32
    repeat {
      peek = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
    } while peek < 0 && errno == EINTR
    guard peek == 0 else {
      recordExit(-1)
      return
    }
    guard info.si_pid == pid else {
      if pollIfNeeded { pollExit() }
      return
    }
    childIsExiting = true
    readAvailable()
    if !groupKillSent, groupHasOtherMembers {
      if !terminating {
        // Preserve the natural final-output drain before hanging up any
        // descendants. Retain the leader until cleanup can safely signal
        // the group; collecting it first would permit ID reuse.
        let deadline = naturalDrainDeadline ?? (.now() + Self.drainBound)
        naturalDrainDeadline = deadline
        if DispatchTime.now() < deadline {
          pollExit()
          return
        }
        beginTermination()
      }
      if let deadline = terminationDeadline, DispatchTime.now() < deadline {
        pollExit()
        return
      }
      killOwnedGroup()
    }
    var status: Int32 = 0
    var result: pid_t
    repeat {
      result = waitpid(pid, &status, WNOHANG)
    } while result < 0 && errno == EINTR
    if result == 0 {
      pollExit()
      return
    }
    recordExit(result == pid ? status : -1)
  }

  /// Only a complete single-member result proves no descendants remain.
  /// A full buffer or a failed query keeps cleanup conservative.
  private var groupHasOtherMembers: Bool {
    var members = [pid_t](repeating: 0, count: 2)
    let count = members.withUnsafeMutableBytes {
      proc_listpgrppids(pid, $0.baseAddress, Int32($0.count))
    }
    return count != 1 || members[0] != pid
  }

  private func pollExit() {
    guard exitPoll == nil else { return }
    let poll = DispatchSource.makeTimerSource(queue: queue)
    poll.schedule(
      deadline: .now() + .milliseconds(25),
      repeating: .milliseconds(25),
    )
    poll.setEventHandler { [weak self] in self?.childExited() }
    exitPoll = poll
    poll.resume()
  }

  /// Called only after waitid confirms exclusive ownership of the leader.
  private func killOwnedGroup() {
    guard !groupKillSent else { return }
    groupKillSent = true
    forcedTermination = true
    kill(-pid, SIGKILL)
    kill(pid, SIGKILL)
  }

  private func recordExit(_ raw: Int32) {
    guard exitStatus == nil else { return }
    exitSource?.cancel()
    exitSource = nil
    exitPoll?.cancel()
    exitPoll = nil
    exitStatus =
      raw == -1
      ? -1 : ((raw & 0x7F) == 0 ? (raw >> 8) & 0xFF : 128 + (raw & 0x7F))
    // Drain what the PTY holds, then release our slave so EOF can arrive
    // once descendants also close it.
    readAvailable()
    if slave >= 0 {
      close(slave)
      slave = -1
    }
    if readSource == nil {
      finish()
      return
    }
    // Descendants may retain the slave; bound the wait.
    let timer = DispatchWorkItem { [weak self] in self?.finish() }
    drainTimer = timer
    queue.asyncAfter(deadline: .now() + Self.drainBound, execute: timer)
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    readAvailable()
    drainTimer?.cancel()
    drainTimer = nil
    setReadActive(true)
    readSource?.cancel()
    readSource = nil
    readSourceActive = false
    bufferedRead = 0 ..< 0
    setWriteActive(true)  // a suspended source must not be released
    writeSource?.cancel()
    writeSource = nil
    writeActive = false
    release(writer.discardAll())
    if master >= 0 {
      // Hang up descendants still holding the slave.
      close(master)
      master = -1
    }
    if slave >= 0 {
      close(slave)
      slave = -1
    }
    parser = Parser()
    state.programExited()
    // The final status reaches the inbox before `finished`.
    publishStatus()
    noteChange()
    onEvent?(.finished(status: exitStatus ?? -1, forced: forcedTermination))
  }

  /// Bounded explicit termination of this pane's processes only.
  func terminate() {
    queue.async { [self] in
      guard !finished else {
        onEvent?(.finished(status: exitStatus ?? -1, forced: forcedTermination))
        return
      }
      guard pid > 0 else {
        finish()
        return
      }
      beginTermination()
    }
  }

  private func beginTermination() {
    guard !terminating else { return }
    terminating = true
    let deadline = DispatchTime.now() + Self.terminateGrace
    terminationDeadline = deadline
    if exitStatus == nil {
      kill(-pid, SIGHUP)
      kill(pid, SIGHUP)
    }
    queue.asyncAfter(deadline: deadline) { [self] in
      guard !finished else { return }
      forcedTermination = true
      if exitStatus == nil {
        var info = siginfo_t()
        var owned: Int32
        repeat {
          owned = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        } while owned < 0 && errno == EINTR
        if owned == 0 { killOwnedGroup() }
        childExited()
      } else {
        finish()
      }
    }
  }

  // MARK: Input mapping

  static func key(_ key: MuxKey) -> Key {
    switch key {
    case let .character(v): .character(Unicode.Scalar(v) ?? " ")
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
    case let .function(n): .function(min(max(n, 1), 12))
    }
  }

  static func modifiers(_ m: MuxKeyModifiers) -> KeyModifiers {
    var out: KeyModifiers = []
    if m.contains(.shift) { out.insert(.shift) }
    if m.contains(.alt) { out.insert(.alt) }
    if m.contains(.control) { out.insert(.control) }
    return out
  }
}
