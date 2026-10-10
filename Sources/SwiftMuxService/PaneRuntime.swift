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

  // Set once before use, read on `queue`.
  var onChange: (@Sendable () -> Void)?
  var onEvent: (@Sendable (PaneEvent) -> Void)?

  // MARK: Queue-owned state

  private var state: TerminalState
  private var parser = Parser()
  private var writer: PaneWriter
  private var master: Int32 = -1
  private var slave: Int32 = -1
  private(set) var pid: pid_t = 0
  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var writeActive = false
  private var exitSource: DispatchSourceProcess?
  private let readBuffer: UnsafeMutableRawBufferPointer
  private var exitStatus: Int32?
  private var finished = false
  private var forcedTermination = false
  private var terminating = false
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
    limits: MuxLimits
  ) {
    self.id = id
    self.workspace = workspace
    self.limits = limits
    queue = DispatchQueue(
      label: "swiftmux.pane.\(id.short)",
      qos: .userInitiated
    )
    self.historyBytes = historyBytes
    state = TerminalState(
      columns: columns,
      rows: rows,
      scrollbackLimitBytes: historyBytes,
      scrollbackLimitRows: limits.historyRowsPerPane
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
    // Only reached when the owning service itself goes away (tests);
    // hang up the pane's processes rather than orphan them.
    if !finished, pid > 0, exitStatus == nil { kill(-pid, SIGHUP) }
    exitSource?.cancel()
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
      rows: state.rows
    )
    master = p.master
    slave = p.slave
    pid = p.pid
    let fd = master
    let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    read.setEventHandler { [weak self] in self?.readAvailable() }
    read.resume()
    readSource = read
    let write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    write.setEventHandler { [weak self] in self?.flush() }
    writeSource = write  // resumed only while output is pending
    let exit = DispatchSource.makeProcessSource(
      identifier: pid,
      eventMask: .exit,
      queue: queue
    )
    exit.setEventHandler { [weak self] in self?.childExited() }
    exit.resume()
    exitSource = exit
    // The child may have exited before the source was armed.
    var status: Int32 = 0
    if waitpid(pid, &status, WNOHANG) == pid { recordExit(status) }
  }

  // MARK: Output

  private func readAvailable() {
    guard master >= 0 else { return }
    var budget = limits.readTurnBytes
    var sawEOF = false
    while budget > 0 {
      let n = Darwin.read(
        master,
        readBuffer.baseAddress,
        min(budget, readBuffer.count)
      )
      if n > 0 {
        let chunk = UnsafeBufferPointer(
          start: readBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
          count: n
        )
        parser.consume(Span(_unsafeElements: chunk), into: &state)
        budget -= n
        continue
      }
      if n < 0, errno == EINTR { continue }
      if n < 0, errno == EAGAIN { break }
      sawEOF = true  // EOF or EIO: every slave descriptor is closed
      break
    }
    if budget < limits.readTurnBytes { publish() }
    if sawEOF {
      readSource?.cancel()
      readSource = nil
      if exitStatus != nil { finish() }
    }
  }

  /// Flushes replies and events, then notifies the service once.
  private func publish() {
    state.refreshSearchIfNeeded()
    if !state.output.isEmpty {
      if !writer.appendReply(state.output) {
        // Reply reserve exhausted (the program is not reading); drop
        // rather than grow without bound.
      }
      state.output.removeAll(keepingCapacity: true)
      flush()
    }
    publishStatus()
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
      message: r.message
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
        into: &bytes
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

  func pasteBegin(id: UInt64) {
    queue.async { [self] in
      guard master >= 0, !finished, !writer.hasOpenPaste else { return }
      if state.viewportOffset != 0 {
        state.scrollViewportToBottom()
        viewportRevision &+= 1
        noteChange()
      }
      writer.beginPaste(
        id: id,
        bracketed: state.modes.contains(.bracketedPaste)
      )
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

  /// Disconnect, cancellation or limit failure. `completion` reports
  /// whether payload was discarded.
  func pasteCancel(id: UInt64, completion: @escaping @Sendable (Bool) -> Void) {
    queue.async { [self] in
      let discarded = writer.cancelPaste(id: id)
      release(discarded)
      flush()
      completion(discarded > 0)
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
            buffer.count - offset
          )
          if n > 0 {
            offset += n
            continue
          }
          if n < 0, errno == EINTR { continue }
          if n < 0, errno == EAGAIN { break }
          return offset > 0 ? offset : nil
        }
        return offset
      })
    else {
      release(writer.discardAll())
      setWriteActive(false)
      return
    }
    release(released)
    setWriteActive(!writer.isEmpty)
  }

  private func setWriteActive(_ active: Bool) {
    guard let writeSource, active != writeActive else { return }
    writeActive = active
    if active { writeSource.resume() } else { writeSource.suspend() }
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
    queue.async { [self] in
      geometryGeneration = generation
      guard columns != state.columns || rows != state.rows else {
        noteChange()
        return
      }
      state.resize(columns: columns, rows: rows)
      if master >= 0 {
        var size = winsize(
          ws_row: UInt16(clamping: state.rows),
          ws_col: UInt16(clamping: state.columns),
          ws_xpixel: 0,
          ws_ypixel: 0
        )
        _ = ioctl(master, TIOCSWINSZ, &size)
      }
      publish()
    }
  }

  func scroll(
    _ request: ScrollRequest,
    completion: @escaping @Sendable (MuxError?) -> Void
  ) {
    queue.async { [self] in
      switch request {
      case let .lines(n): state.scrollViewport(by: n)
      case let .pages(n): state.scrollViewport(by: n * max(1, state.rows - 1))
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
    completion: @escaping @Sendable (SearchResult) -> Void
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
          selected: state.searchSelected
        )
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
          selectionBackground: p.selectionBackground
        )
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
    completion: @escaping @Sendable (Result<(Data, UInt64), MuxError>) -> Void
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
        viewportRevision: viewportRevision
      )
      do {
        var frame = try FrameExporter.frame(
          from: screen,
          identity: identity,
          limits: limits
        )
        frame.search?.selected = state.searchSelected
        let data = try SMXCodec.encode(
          ServerMessage.event(.frame(frame)),
          limit: limits.maxFrameBytes
        )
        completion(.success((data, revision)))
      } catch let error as MuxError { completion(.failure(error)) } catch {
        completion(.failure(MuxError(.resourceLimit, "\(error)")))
      }
    }
  }

  /// Plain text of the visible screen (tests, diagnostics).
  func screenLines() -> [String] { queue.sync { state.screenLines } }

  /// Runs `body` in this pane's order with the authoritative state, for
  /// exports other than `PaneFrame` (the roaming bridge's screens).
  func inspect<T: Sendable>(
    _ body: @escaping @Sendable (borrowing TerminalState) -> T,
    completion: @escaping @Sendable (T) -> Void
  ) {
    queue.async { [self] in completion(body(state)) }
  }

  var size: (columns: Int, rows: Int) {
    queue.sync { (state.columns, state.rows) }
  }

  // MARK: Lifetime

  private func childExited() {
    var status: Int32 = 0
    var result: pid_t
    // Darwin posts NOTE_EXIT before the child becomes waitable.
    repeat {
      result = waitpid(pid, &status, 0)
    } while result < 0 && errno == EINTR
    recordExit(result == pid ? status : -1)
  }

  private func recordExit(_ raw: Int32) {
    guard exitStatus == nil else { return }
    exitSource?.cancel()
    exitSource = nil
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
    readSource?.cancel()
    readSource = nil
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
      guard !terminating else { return }
      terminating = true
      if exitStatus == nil {
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
      }
      queue.asyncAfter(deadline: .now() + Self.terminateGrace) { [self] in
        guard !finished else { return }
        forcedTermination = true
        if exitStatus == nil {
          kill(-pid, SIGKILL)
          kill(pid, SIGKILL)
        } else {
          finish()
        }
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
