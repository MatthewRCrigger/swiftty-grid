import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol

/// The `swmux` interactive attachment inside Swiftty: raw outer tty,
/// prefix commands, a composed workspace display and copy mode.
@MainActor
public final class TerminalClient {
  public enum Outcome: Equatable, Sendable {
    case detached(String)
    case lost(String)
    case failed(String)
  }

  struct CopyState {
    var pane: PaneID
    var frame: PaneFrame
    var row: Int
    var column: Int
    var anchor: (row: Int, column: Int)?
    var lines = false
  }

  struct Prompt {
    var label: String
    var text = ""
    var commit: @MainActor (String) -> Void
  }

  enum Mode {
    case normal
    case prefix
    case copy(CopyState)
    case prompt(Prompt)
    case help
    case confirm(String, @MainActor () -> Void)
  }

  let connection: MuxConnection
  let attachment: AttachmentID
  let tty: RawTTY
  let settings: Settings
  private var decoder: InputDecoder
  private(set) var workspace: WorkspaceSnapshot
  private var frames: [PaneID: PaneFrame] = [:]
  private var size: (columns: Int, rows: Int)
  private var renderer = DiffRenderer()
  private var geometryGeneration: UInt64 = 0
  private var lastGeometry: (revision: UInt64, entries: [GeometryBatch.Entry])?
  private var subscriptions: [PaneID] = []
  private var mode: Mode = .normal
  private var message: String?
  private var messageTimer: DispatchWorkItem?
  private var pasteBuffer: String?
  private var escapeTimer: DispatchWorkItem?
  private var redrawScheduled = false
  private var continuation: CheckedContinuation<Outcome, Never>?
  private var outcome: Outcome?
  private var sources: [any DispatchSourceProtocol] = []
  private var eventTask: Task<Void, Never>?
  private let limits: MuxLimits

  public init(
    connection: MuxConnection,
    attachment: AttachmentID,
    workspace: WorkspaceSnapshot,
    limits: MuxLimits,
    tty: RawTTY = RawTTY(),
    settings: Settings = Settings()
  ) {
    self.connection = connection
    self.attachment = attachment
    self.workspace = workspace
    self.tty = tty
    self.settings = settings
    self.limits = limits
    decoder = InputDecoder(maxPasteBytes: limits.maxPasteBytes)
    size = tty.size
  }

  /// Runs until detach or connection loss. The outer tty is restored
  /// before returning, and before waiting on any service cleanup.
  public func run() async -> Outcome {
    do { try tty.enter() } catch { return .failed("\(error)") }
    installSources()
    startEvents()
    syncLayout()
    return await withCheckedContinuation { continuation = $0 }
  }

  private func finish(_ result: Outcome, detach: Bool) {
    guard outcome == nil else { return }
    outcome = result
    for source in sources { source.cancel() }
    sources = []
    escapeTimer?.cancel()
    messageTimer?.cancel()
    tty.restore()
    let connection = self.connection
    Task {
      if detach { await connection.detach() }
      await connection.close()
      self.eventTask?.cancel()
      self.continuation?.resume(returning: result)
      self.continuation = nil
    }
  }

  // MARK: Sources

  private func installSources() {
    let read = DispatchSource.makeReadSource(
      fileDescriptor: tty.input,
      queue: .main
    )
    read.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.readInput() }
    }
    read.resume()
    sources.append(read)
    // Signal handlers only notify normal execution code.
    for sig in [SIGWINCH, SIGTERM, SIGHUP, SIGCONT, SIGINT, SIGQUIT] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.handleSignal(sig) }
      }
      source.resume()
      sources.append(source)
    }
  }

  private func handleSignal(_ sig: Int32) {
    switch sig {
    case SIGWINCH:
      size = tty.size
      renderer.invalidate()
      syncLayout()
    case SIGCONT:
      try? tty.enter()
      renderer.invalidate()
      redraw()
    default: finish(.detached("terminated by signal \(sig)"), detach: true)
    }
  }

  private func startEvents() {
    let connection = self.connection
    eventTask = Task.detached { [weak self] in
      do {
        while let event = try await connection.nextEvent() {
          await self?.handle(event)
        }
      } catch { await self?.finish(.lost("\(error)"), detach: false) }
    }
  }

  // MARK: Service events

  func handle(_ event: MuxEvent) {
    switch event {
    case let .frame(frame):
      guard frame.identity.attachment == attachment else { return }
      frames[frame.identity.pane] = frame
      if case var .copy(state) = mode, state.pane == frame.identity.pane,
        frame.identity.viewportRevision != state.frame.identity.viewportRevision
      {
        // A viewport reached by scrolling or search replaces the frozen
        // frame; selection across fetched pages is not supported.
        state.frame = frame
        state.anchor = nil
        state.row = min(state.row, frame.grid.rows - 1)
        state.column = min(state.column, frame.grid.columns - 1)
        mode = .copy(state)
      }
      redraw()
    case let .layout(snapshot):
      guard snapshot.id == workspace.id else { return }
      workspace = snapshot
      let live = Set(snapshot.panes.map(\.id))
      frames = frames.filter { live.contains($0.key) }
      if case let .copy(state) = mode, !live.contains(state.pane) {
        mode = .normal
      }
      syncLayout()
    case let .paneExited(pane, status, truncated):
      if truncated {
        show("pane was force-killed; its final output may be incomplete")
      }
      if let i = workspace.panes.firstIndex(where: { $0.id == pane }) {
        workspace.panes[i].exitStatus = status
      }
      redraw()
    case let .title(pane, title):
      if let i = workspace.panes.firstIndex(where: { $0.id == pane }) {
        workspace.panes[i].title = title
      }
      redraw()
    case .bell: tty.write("\u{07}")
    case .activity: break
    case let .detached(reason): finish(.detached(reason), detach: false)
    case let .paste(_, state):
      if state != .completed { show("paste \(state.rawValue)") }
    case let .frameUnavailable(_, error): show("frame unavailable: \(error)")
    case .workspaces, .inbox: break
    }
  }

  // MARK: Layout and geometry

  private var compositor: Compositor {
    Compositor(columns: size.columns, rows: size.rows)
  }

  private var activeTab: TabSnapshot? { workspace.activeTabSnapshot }

  /// Sends a geometry batch for visible panes and subscribes to them.
  /// Panes whose area is empty keep their last valid size.
  func syncLayout() {
    guard let tab = activeTab else { return }
    let rects = compositor.frames(for: tab)
    let order = tab.layout.panes.filter { rects[$0] != nil }
    var entries: [GeometryBatch.Entry] = []
    for pane in order {
      guard let r = rects[pane], r.width >= 1, r.height >= 1 else { continue }
      entries.append(
        .init(
          pane: pane,
          columns: min(r.width, limits.maxColumns),
          rows: min(r.height, limits.maxRows)
        )
      )
    }
    if lastGeometry?.revision != workspace.layoutRevision
      || lastGeometry?.entries != entries
    {
      lastGeometry = (workspace.layoutRevision, entries)
      geometryGeneration += 1
      let batch = GeometryBatch(
        layoutRevision: workspace.layoutRevision,
        generation: geometryGeneration,
        entries: entries
      )
      command(.setGeometry(batch), quietOn: [.staleGeometry])
    }
    if order != subscriptions {
      subscriptions = order
      command(.setSubscriptions(order))
    }
    redraw()
  }

  private func command(
    _ command: MuxCommand,
    quietOn quiet: Set<MuxError.Code> = [],
    then: (@MainActor (MuxReply) -> Void)? = nil
  ) {
    connection.enqueue(command) { [weak self] result in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          guard let self else { return }
          switch result {
          case let .success(reply):
            if case let .layout(snapshot) = reply,
              snapshot.id == self.workspace.id,
              snapshot.layoutRevision >= self.workspace.layoutRevision
            {
              self.handle(.layout(snapshot))
            }
            then?(reply)
          case let .failure(error):
            if !quiet.contains(error.code) { self.show(error.description) }
          }
        }
      }
    }
  }

  // MARK: Drawing

  private func redraw() {
    guard !redrawScheduled, outcome == nil else { return }
    redrawScheduled = true
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.redrawScheduled = false
        self.draw()
      }
    }
  }

  func compose() -> ScreenBuffer {
    var shown = frames
    var overlays: [PaneID: PaneOverlay] = [:]
    if case let .copy(state) = mode {
      shown[state.pane] = state.frame
      overlays[state.pane] = PaneOverlay(
        selection: state.anchor.map {
          ($0, (state.row, state.column), state.lines)
        },
        cursor: (state.row, state.column)
      )
    }
    let showCursor: Bool =
      switch mode {
      case .normal, .prefix: true
      default: false
      }
    var screen = compositor.compose(
      workspace: workspace,
      frames: shown,
      overlays: overlays,
      status: status,
      showCursor: showCursor
    )
    if case .help = mode { drawHelp(into: &screen) }
    return screen
  }

  private func draw() {
    guard outcome == nil else { return }
    let screen = compose()
    let bytes = renderer.update(to: screen)
    if tty.write(bytes) {
      renderer.commit(screen)
    } else {
      renderer.invalidate()
    }
  }

  private var status: StatusLine {
    var line = StatusLine()
    line.left = "[\(workspace.name)] "
    for (i, tab) in workspace.tabs.enumerated() {
      let active = tab.id == workspace.activeTab
      let flags = (active ? "*" : "") + (tab.zoomedPane != nil ? "Z" : "")
      line.items.append(
        .init(text: "\(i):\(tab.name)\(flags) ", active: active)
      )
    }
    switch mode {
    case let .copy(state):
      line.right =
        "[copy \(state.frame.history.viewportOffset)/\(state.frame.history.scrollbackRows)] "
    case .prefix:
      line.right =
        "^\(settings.prefix.last.map { String($0).uppercased() } ?? "B") "
    case let .prompt(p):
      line.prompt = p.label + p.text
      line.promptCursor = true
    case let .confirm(question, _): line.prompt = question + " (y/n)"
    default:
      if let pane = activeTab?.activePane,
        let title = workspace.pane(pane)?.title, !title.isEmpty
      {
        line.right = "\"\(title.prefix(max(0, size.columns / 3)))\" "
      }
    }
    if let message, line.prompt == nil { line.prompt = message }
    return line
  }

  private static let help = [
    "swmux — prefix then:",
    "c new tab        n/p next/prev tab   0-9 select tab",
    "% split ←→       \" split ↑↓         o next pane",
    "arrows focus     M-arrows resize     z zoom pane",
    "x end pane       & end tab           d detach",
    "[ copy mode      ] paste buffer      / search",
    ", rename tab     $ rename workspace  w switch workspace",
    "? help           prefix twice sends the prefix",
    "copy mode: hjkl/arrows move, v/V select, y copy,",
    "  PgUp/PgDn scroll, g/G top/bottom, n/N search, q quit",
  ]

  private func drawHelp(into screen: inout ScreenBuffer) {
    let width = min(size.columns - 2, (Self.help.map(\.count).max() ?? 0) + 4)
    let height = min(size.rows - 2, Self.help.count + 2)
    guard width > 4, height > 2 else { return }
    let x0 = (size.columns - width) / 2
    let y0 = max(0, (size.rows - 1 - height) / 2)
    let style = OuterStyle(foreground: .palette(15), background: .palette(4))
    screen.fill(
      LayoutRect(x: x0, y: y0, width: width, height: height),
      style: style
    )
    for (i, line) in Self.help.prefix(height - 2).enumerated() {
      screen.write(
        line,
        x: x0 + 2,
        y: y0 + 1 + i,
        style: style,
        limit: width - 4
      )
    }
  }

  private func show(_ text: String) {
    message = text
    messageTimer?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.message = nil
        self?.redraw()
      }
    }
    messageTimer = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    redraw()
  }

  // MARK: Input

  private func readInput() {
    guard let bytes = tty.read() else {
      finish(.detached("terminal closed"), detach: true)
      return
    }
    guard !bytes.isEmpty else { return }
    feed(bytes)
  }

  func feed(_ bytes: [UInt8]) {
    for event in decoder.feed(bytes) { handle(event) }
    escapeTimer?.cancel()
    if decoder.hasPending {
      let work = DispatchWorkItem { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          for event in self.decoder.flushPending() { self.handle(event) }
        }
      }
      escapeTimer = work
      DispatchQueue.main.asyncAfter(
        deadline: .now() + .milliseconds(settings.escapeDelayMilliseconds),
        execute: work
      )
    }
  }

  private var activePane: PaneID? { activeTab?.activePane }

  func handle(_ input: DecodedInput) {
    if message != nil {
      message = nil
      messageTimer?.cancel()
    }
    switch mode {
    case .normal:
      if case let .key(k, m) = input, k == settings.prefixKey.0,
        m == settings.prefixKey.1
      {
        mode = .prefix
        redraw()
        return
      }
      sendToPane(input)
    case .prefix:
      mode = .normal
      prefixCommand(input)
      redraw()
    case let .copy(state): copyMode(input, state)
    case var .prompt(prompt):
      switch input {
      case let .text(s):
        prompt.text += s
        mode = .prompt(prompt)
      case let .paste(s, _):
        prompt.text += s.filter { !$0.isNewline }
        mode = .prompt(prompt)
      case .key(.backspace, _):
        if !prompt.text.isEmpty { prompt.text.removeLast() }
        mode = .prompt(prompt)
      case .key(.enter, _):
        mode = .normal
        prompt.commit(prompt.text)
      case .key(.escape, _), .key(.character(0x63), .control),
        .key(.character(0x67), .control):
        mode = .normal
      default: break
      }
      redraw()
    case .help:
      mode = .normal
      redraw()
    case let .confirm(_, action):
      mode = .normal
      if case let .text(s) = input, s.lowercased() == "y" { action() }
      redraw()
    }
  }

  private func sendToPane(_ input: DecodedInput) {
    guard let pane = activePane else { return }
    if workspace.pane(pane)?.exitStatus != nil { return }
    switch input {
    case let .text(s):
      connection.enqueue(.text(s), to: pane, rejected: rejectedInput)
    case let .key(k, m):
      connection.enqueue(.key(k, m), to: pane, rejected: rejectedInput)
    case let .paste(s, truncated):
      if truncated { show("paste truncated to \(limits.maxPasteBytes) bytes") }
      paste(s, to: pane)
    }
  }

  private nonisolated var rejectedInput: @Sendable (MuxError) -> Void {
    { [weak self] error in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.show("input rejected: \(error)") }
      }
    }
  }

  private func paste(_ text: String, to pane: PaneID) {
    connection.enqueuePaste(text, to: pane) { [weak self] result in
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          switch result {
          case let .success(state) where state != .completed:
            self?.show("paste \(state.rawValue)")
          case let .failure(error): self?.show("paste failed: \(error)")
          default: break
          }
        }
      }
    }
  }

  // MARK: Prefix commands

  private func prefixCommand(_ input: DecodedInput) {
    guard let tab = activeTab, let pane = activePane else { return }
    switch input {
    case let .key(k, m)
    where k == settings.prefixKey.0 && m == settings.prefixKey.1:
      connection.enqueue(.key(k, m), to: pane, rejected: rejectedInput)
    case let .key(dir, mods) where [.up, .down, .left, .right].contains(dir):
      let direction: Direction =
        switch dir {
        case .up: .up
        case .down: .down
        case .left: .left
        default: .right
        }
      if mods.contains(.alt) || mods.contains(.control) {
        resize(pane: pane, tab: tab, direction: direction)
      } else if let target = LayoutGeometry.neighbor(
        of: pane,
        direction: direction,
        frames: compositor.frames(
          for: TabSnapshot(
            id: tab.id,
            name: tab.name,
            layout: tab.layout,
            activePane: pane
          )
        ),
        order: tab.layout.panes
      ) {
        command(.focusPane(target))
      }
    case let .text(s):
      switch s {
      case "c": command(.newTab(name: nil, launch: nil))
      case "n", "p":
        guard let i = workspace.tabs.firstIndex(where: { $0.id == tab.id })
        else { return }
        let n = workspace.tabs.count
        command(.selectTab(workspace.tabs[(i + (s == "n" ? 1 : n - 1)) % n].id))
      case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
        let i = Int(s)!
        if i < workspace.tabs.count {
          command(.selectTab(workspace.tabs[i].id))
        }
      case "%": command(.split(pane: pane, axis: .leftRight, launch: nil))
      case "\"": command(.split(pane: pane, axis: .topBottom, launch: nil))
      case "o":
        let order = tab.layout.panes
        if let i = order.firstIndex(of: pane), order.count > 1 {
          command(.focusPane(order[(i + 1) % order.count]))
        }
      case "z": command(.toggleZoom(tab.id))
      case "x":
        mode = .confirm("end pane?") { [weak self] in
          self?.command(.endPane(pane))
        }
      case "&":
        mode = .confirm("end tab \(tab.name)?") { [weak self] in
          self?.command(.endTab(tab.id))
        }
      case "d":
        finish(.detached("detached from \(workspace.name)"), detach: true)
      case "[": enterCopyMode(pane)
      case "]": if let buffer = pasteBuffer { paste(buffer, to: pane) }
      case "/":
        enterCopyMode(pane)
        promptSearch(pane)
      case ",":
        mode = .prompt(
          Prompt(label: "rename tab: ", text: tab.name) { [weak self] name in
            if !name.isEmpty { self?.command(.renameTab(tab.id, name: name)) }
          }
        )
      case "$":
        let id = workspace.id
        mode = .prompt(
          Prompt(label: "rename workspace: ", text: workspace.name) {
            [weak self] name in
            guard let self, !name.isEmpty else { return }
            self.command(.renameWorkspace(.id(id), name: name)) { _ in
              self.workspace.name = name
              self.redraw()
            }
          }
        )
      case "w": chooseWorkspace()
      case "?": mode = .help
      default: break
      }
    default: break
    }
  }

  private func resize(pane: PaneID, tab: TabSnapshot, direction: Direction) {
    let axis: SplitAxis =
      direction == .left || direction == .right ? .leftRight : .topBottom
    guard let split = tab.layout.enclosingSplit(of: pane, axis: axis) else {
      return
    }
    let delta = direction == .right || direction == .down ? 0.05 : -0.05
    let ratio = min(0.95, max(0.05, split.ratio + delta))
    command(.setSplitRatio(tab: tab.id, path: split.path, ratio: ratio))
  }

  private func chooseWorkspace() {
    command(.listWorkspaces) { [weak self] reply in
      guard let self, case let .workspaces(list) = reply else { return }
      let names = list.map(\.name).joined(separator: ", ")
      self.mode = .prompt(
        Prompt(label: "workspace (\(names)): ") { [weak self] name in
          guard let self, !name.isEmpty else { return }
          self.command(.switchWorkspace(.name(name))) { reply in
            guard case let .layout(snapshot) = reply else { return }
            self.workspace = snapshot
            self.frames = [:]
            self.subscriptions = []
            self.lastGeometry = nil
            self.syncLayout()
          }
        }
      )
      self.redraw()
    }
  }

  // MARK: Copy mode

  private func enterCopyMode(_ pane: PaneID) {
    guard let frame = frames[pane] else { return }
    mode = .copy(
      CopyState(
        pane: pane,
        frame: frame,
        row: frame.cursor.y,
        column: frame.cursor.x
      )
    )
    redraw()
  }

  private func exitCopyMode(_ pane: PaneID) {
    mode = .normal
    command(.endSearch(pane: pane), quietOn: [.notFound])
    command(.scroll(pane: pane, .bottom), quietOn: [.notFound])
    redraw()
  }

  private func promptSearch(_ pane: PaneID) {
    let previous = mode
    mode = .prompt(
      Prompt(label: "search: ") { [weak self] query in
        guard let self else { return }
        self.mode = previous
        guard !query.isEmpty else { return }
        self.command(.search(pane: pane, query: query)) { reply in
          if case let .search(result) = reply, result.matchCount == 0 {
            self.show("no matches")
          }
        }
      }
    )
  }

  private func copyMode(_ input: DecodedInput, _ initial: CopyState) {
    var state = initial
    let rows = state.frame.grid.rows
    let columns = state.frame.grid.columns
    let pane = state.pane
    func scroll(_ request: ScrollRequest) {
      command(.scroll(pane: pane, request), quietOn: [.historyUnavailable])
    }
    var key: (MuxKey, MuxKeyModifiers)?
    var text: String?
    switch input {
    case let .key(k, m): key = (k, m)
    case let .text(s): text = s
    case .paste: return
    }
    switch (key?.0, key?.1, text) {
    case (.escape, _, _), (_, _, "q"):
      exitCopyMode(pane)
      return
    case (.up, _, _), (_, _, "k"):
      if state.row > 0 { state.row -= 1 } else { scroll(.lines(1)) }
    case (.down, _, _), (_, _, "j"):
      if state.row < rows - 1 { state.row += 1 } else { scroll(.lines(-1)) }
    case (.left, _, _), (_, _, "h"): state.column = max(0, state.column - 1)
    case (.right, _, _), (_, _, "l"):
      state.column = min(columns - 1, state.column + 1)
    case (.pageUp, _, _), (.character(0x62), MuxKeyModifiers.control, _):
      scroll(.pages(1))
    case (.pageDown, _, _), (.character(0x66), MuxKeyModifiers.control, _):
      scroll(.pages(-1))
    case (.character(0x75), MuxKeyModifiers.control, _):
      scroll(.lines(max(1, rows / 2)))
    case (.character(0x64), MuxKeyModifiers.control, _):
      scroll(.lines(-max(1, rows / 2)))
    case (_, _, "g"):
      scroll(.lines(state.frame.history.scrollbackRows))
      state.row = 0
    case (_, _, "G"):
      scroll(.bottom)
      state.row = rows - 1
    case (.home, _, _), (_, _, "0"): state.column = 0
    case (.end, _, _), (_, _, "$"):
      state.column = max(
        0,
        state.frame.text(row: state.row).unicodeScalars.count - 1
      )
    case (_, _, "w"):
      let (_, hi) = FrameText.word(
        state.frame,
        row: state.row,
        column: state.column
      )
      state.column = min(columns - 1, hi + 1)
      while state.column < columns - 1,
        state.frame.scalars(row: state.row, column: state.column) == [" "]
      { state.column += 1 }
    case (_, _, "b"):
      var c = max(0, state.column - 1)
      while c > 0, state.frame.scalars(row: state.row, column: c) == [" "] {
        c -= 1
      }
      state.column = FrameText.word(state.frame, row: state.row, column: c).0
    case (_, _, "v"), (_, _, " "):
      state.anchor = state.anchor == nil ? (state.row, state.column) : nil
      state.lines = false
    case (_, _, "V"):
      state.anchor =
        state.anchor == nil || !state.lines ? (state.row, state.column) : nil
      state.lines = state.anchor != nil
    case (.enter, _, _), (_, _, "y"):
      if let anchor = state.anchor {
        let text = FrameText.text(
          state.frame,
          from: anchor,
          to: (state.row, state.column),
          lines: state.lines
        )
        copy(text)
      }
      exitCopyMode(pane)
      return
    case (_, _, "/"):
      mode = .copy(state)
      promptSearch(pane)
      redraw()
      return
    case (_, _, "n"): command(.searchStep(pane: pane, forward: false))
    case (_, _, "N"): command(.searchStep(pane: pane, forward: true))
    default: break
    }
    mode = .copy(state)
    redraw()
  }

  /// Local copy: the paste buffer plus the system pasteboard.
  private func copy(_ text: String) {
    pasteBuffer = text
    let pbcopy = Process()
    pbcopy.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
    let pipe = Pipe()
    pbcopy.standardInput = pipe
    do {
      try pbcopy.run()
      pipe.fileHandleForWriting.write(Data(text.utf8))
      try? pipe.fileHandleForWriting.close()
      show("copied \(text.count) characters")
    } catch { show("copied to swmux buffer") }
  }
}
