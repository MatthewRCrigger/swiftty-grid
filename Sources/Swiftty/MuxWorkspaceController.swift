import AppKit
import ServiceManagement
import SwiftMuxClient
import SwiftMuxProtocol
import SwifttyCore

/// The native SwiftMux workspace window. Owns the single connection and
/// the interactive lease; pane views only present and forward input.
/// Closing the window or quitting detaches; panes keep running.
@MainActor
final class MuxWorkspaceController: NSWindowController, NSWindowDelegate {
  private enum InputJob: Sendable {
    case input(MuxInput, PaneID)
    case paste(String, PaneID)
  }

  private let connection: MuxConnection
  private let server: ServerInstanceID
  private let limits: MuxLimits
  private var config: Configuration
  private(set) var workspace: WorkspaceSnapshot?
  private(set) var views: [PaneID: MuxPaneView] = [:]
  private let tabBar = NSSegmentedControl()
  private let layoutView = MuxLayoutView()
  private var inputs: AsyncStream<InputJob>.Continuation?
  private var commands: AsyncStream<@Sendable () async -> Void>.Continuation?
  private var tasks: [Task<Void, Never>] = []
  private var geometryGeneration: UInt64 = 0
  private var sentGeometry: (revision: UInt64, entries: [GeometryBatch.Entry])?
  private var geometryScheduled = false
  private var subscribed: [PaneID] = []
  private var detached = false
  var onClose: (() -> Void)?

  private init(
    connection: MuxConnection,
    welcome: Welcome,
    configuration: Configuration
  ) {
    self.connection = connection
    server = welcome.server
    limits = welcome.limits
    config = configuration
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "SwiftMux"
    window.tabbingMode = .disallowed
    window.center()
    super.init(window: window)
    window.delegate = self
    let content = NSView()
    tabBar.segmentStyle = .automatic
    tabBar.trackingMode = .selectOne
    tabBar.target = self
    tabBar.action = #selector(tabClicked(_:))
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    layoutView.translatesAutoresizingMaskIntoConstraints = false
    layoutView.controller = self
    content.addSubview(tabBar)
    content.addSubview(layoutView)
    NSLayoutConstraint.activate([
      tabBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
      tabBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      layoutView.topAnchor.constraint(
        equalTo: tabBar.bottomAnchor,
        constant: 4
      ), layoutView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      layoutView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      layoutView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    window.contentView = content
    startPipelines()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  // MARK: Service connection

  enum ServiceState: Equatable {
    case available
    case requiresApproval
    case unavailable(String)
  }

  /// Registers the bundled agent when running from an app bundle and
  /// reports its state; never starts a second service on its own.
  static func ensureAgent() -> ServiceState {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      return .available
    }
    let service = SMAppService.agent(plistName: SMX.agentPlistName)
    switch service.status {
    case .enabled: return .available
    case .requiresApproval: return .requiresApproval
    case .notFound:
      return .unavailable(
        "The SwiftMux helper is missing from this app bundle."
      )
    case .notRegistered:
      do {
        try service.register()
        return service.status == .requiresApproval
          ? .requiresApproval : .available
      } catch {
        return .unavailable(
          "Registering the SwiftMux helper failed: \(error.localizedDescription)"
        )
      }
    @unknown default: return .unavailable("Unknown SwiftMux helper state.")
    }
  }

  static func connect() async throws -> MuxConnection {
    switch ensureAgent() {
    case .available: break
    case .requiresApproval:
      SMAppService.openSystemSettingsLoginItems()
      throw MuxUnavailable(
        message:
          "Allow the SwiftMux helper in System Settings › Login Items. It keeps terminals running after Swiftty closes."
      )
    case let .unavailable(reason): throw MuxUnavailable(message: reason)
    }
    do { return try await MuxConnection.connect(frontend: .native) } catch let
      error as MuxError where error.code == .incompatibleVersion
    {
      // Preserve the running service and its sessions.
      throw MuxUnavailable(
        message:
          "The running SwiftMux service is a different version "
          + "(\(error.message)). Reopen the Swiftty version that started "
          + "it, or end its sessions with `swmux end-all` before updating."
      )
    } catch {
      throw MuxUnavailable(
        message:
          "SwiftMux service unavailable (\(error)). Install it with `swmux agent install`."
      )
    }
  }

  /// Attaches to `selector` (creating a workspace when nil) in a new window.
  static func open(
    _ selector: WorkspaceSelector?,
    configuration: Configuration
  ) async throws -> MuxWorkspaceController {
    try await open(
      selector,
      configuration: configuration,
      connection: connect()
    )
  }

  /// Attaches over an existing connection (also used by tests with an
  /// in-process service).
  static func open(
    _ selector: WorkspaceSelector?,
    configuration: Configuration,
    connection: MuxConnection
  ) async throws -> MuxWorkspaceController {
    guard let welcome = await connection.welcome else {
      throw MuxError(.connectionLost)
    }
    let target: WorkspaceSelector
    if let selector {
      target = selector
    } else {
      let env = ProcessInfo.processInfo.environment
      guard
        case let .created(ws) = try await connection.execute(
          .newWorkspace(
            NewWorkspaceRequest(
              columns: 100,
              rows: 30,
              launch: LaunchSpec(
                workingDirectory: FileManager.default
                  .homeDirectoryForCurrentUser.path,
                environment: env
              )
            )
          )
        )
      else { throw MuxError(.invalidRequest, "unexpected reply") }
      target = .id(ws.id)
    }
    guard
      case let .attached(_, ws) = try await connection.execute(.attach(target))
    else { throw MuxError(.invalidRequest, "unexpected attach reply") }
    let controller = MuxWorkspaceController(
      connection: connection,
      welcome: welcome,
      configuration: configuration
    )
    controller.apply(ws)
    controller.startEvents()
    return controller
  }

  /// Workspaces known to the service (no lease needed).
  static func listWorkspaces() async throws -> [WorkspaceSummary] {
    let connection = try await connect()
    defer { Task { await connection.close() } }
    guard
      case let .workspaces(list) = try await connection.execute(.listWorkspaces)
    else { return [] }
    return list
  }

  // MARK: Pipelines

  /// One ordered input writer and one ordered command executor.
  private func startPipelines() {
    let (inputStream, inputContinuation) = AsyncStream<InputJob>.makeStream()
    inputs = inputContinuation
    let connection = connection
    tasks.append(
      Task.detached {
        for await job in inputStream {
          switch job {
          case let .input(input, pane): await connection.post(input, to: pane)
          case let .paste(text, pane):
            _ = try? await connection.paste(text, to: pane)
          }
        }
      }
    )
    let (commandStream, commandContinuation) = AsyncStream<
      @Sendable () async -> Void
    >
    .makeStream()
    commands = commandContinuation
    tasks.append(
      Task.detached { for await command in commandStream { await command() } }
    )
  }

  /// Consumes events off the main actor; imports frames there and hops
  /// to the main actor only to publish finished presentations.
  private func startEvents() {
    let connection = connection
    let limits = limits
    tasks.append(
      Task.detached { [weak self] in
        do {
          while let event = try await connection.nextEvent() {
            switch event {
            case let .frame(frame):
              guard
                let presentation = MuxPaneView.importFrame(
                  frame,
                  limits: limits
                )
              else { continue }
              await self?.present(presentation)
            default: await self?.handle(event)
            }
          }
        } catch { await self?.connectionEnded(String(describing: error)) }
      }
    )
  }

  private func present(_ presentation: MuxPresentation) {
    views[presentation.frame.identity.pane]?
      .receive(presentation, server: server)
  }

  private func handle(_ event: MuxEvent) {
    switch event {
    case let .layout(ws): apply(ws)
    case let .title(pane, title):
      if pane == activePane {
        window?.title = title.isEmpty ? workspaceTitle : title
      }
    case .bell: NSSound.beep()
    case let .detached(reason): connectionEnded(reason)
    case .paneExited, .paste, .frameUnavailable, .frame: break
    }
  }

  private func connectionEnded(_ reason: String) {
    guard !detached else { return }
    detached = true
    for view in views.values { view.reset() }
    window?.title = "SwiftMux — detached (\(reason))"
  }

  // MARK: Layout

  private var workspaceTitle: String { "SwiftMux — \(workspace?.name ?? "")" }

  var activeTab: TabSnapshot? { workspace?.activeTabSnapshot }
  var activePane: PaneID? { activeTab?.activePane }

  private func apply(_ ws: WorkspaceSnapshot) {
    guard workspace == nil || ws.layoutRevision >= workspace!.layoutRevision
    else { return }
    workspace = ws
    tabBar.segmentCount = ws.tabs.count
    for (i, tab) in ws.tabs.enumerated() {
      tabBar.setLabel(tab.name, forSegment: i)
      tabBar.setWidth(0, forSegment: i)
    }
    if let i = ws.tabs.firstIndex(where: { $0.id == ws.activeTab }) {
      tabBar.selectedSegment = i
    }
    guard let tab = ws.activeTabSnapshot else { return }
    // Rebind: keep views for surviving panes, drop the rest.
    let visible = tab.zoomedPane.map { [$0] } ?? tab.layout.panes
    for (id, view) in views where !visible.contains(id) {
      view.cancelComposition()
      view.removeFromSuperview()
      views.removeValue(forKey: id)
    }
    for id in visible where views[id] == nil {
      guard let view = try? MuxPaneView(pane: id, configuration: config) else {
        continue
      }
      view.controller = self
      views[id] = view
      layoutView.addSubview(view)
    }
    for (id, view) in views { view.isActivePane = id == tab.activePane }
    window?.title = ws.pane(tab.activePane)?.title.nonEmpty ?? workspaceTitle
    layoutView.needsLayout = true
    layoutView.layoutSubtreeIfNeeded()
    if let active = views[tab.activePane], window?.firstResponder !== active {
      window?.makeFirstResponder(active)
    }
    if visible != subscribed {
      subscribed = visible
      command(.setSubscriptions(visible))
    }
    geometryChanged()
  }

  /// Frames for visible panes in points, plus dividers for dragging.
  func layout(
    in bounds: NSRect
  ) -> (panes: [(MuxPaneView, NSRect)], dividers: [LayoutDivider]) {
    guard let tab = activeTab else { return ([], []) }
    let area = LayoutRect(
      x: 0,
      y: 0,
      width: Int(bounds.width),
      height: Int(bounds.height)
    )
    if let zoomed = tab.zoomedPane, let view = views[zoomed] {
      return ([(view, bounds)], [])
    }
    let frames = LayoutGeometry.frames(
      tab.layout,
      in: area,
      divider: MuxLayoutView.divider
    )
    let panes = frames.compactMap { id, r -> (MuxPaneView, NSRect)? in
      views[id]
        .map {
          // LayoutRect y grows downward; AppKit's grows upward.
          (
            $0,
            NSRect(
              x: r.x,
              y: Int(bounds.height) - r.maxY,
              width: r.width,
              height: r.height
            )
          )
        }
    }
    return (
      panes,
      LayoutGeometry.dividers(
        tab.layout,
        in: area,
        divider: MuxLayoutView.divider
      )
    )
  }

  func setRatio(_ ratio: Double, path: [Bool]) {
    guard let tab = activeTab else { return }
    command(
      .setSplitRatio(
        tab: tab.id,
        path: path,
        ratio: min(0.95, max(0.05, ratio))
      )
    )
  }

  /// Coalesces superseded geometry into one batch per run loop turn.
  func geometryChanged() {
    guard !geometryScheduled else { return }
    geometryScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.geometryScheduled = false
        self?.sendGeometry()
      }
    }
  }

  private func sendGeometry() {
    guard !detached, let ws = workspace else { return }
    let entries =
      views.compactMap { id, view -> GeometryBatch.Entry? in
        guard view.superview != nil, view.bounds.width > 0,
          view.bounds.height > 0
        else {
          return nil  // retain the last valid size; never resize to zero
        }
        let size = view.gridSize
        return .init(
          pane: id,
          columns: min(size.columns, limits.maxColumns),
          rows: min(size.rows, limits.maxRows)
        )
      }
      .sorted { $0.pane.description < $1.pane.description }
    guard !entries.isEmpty else { return }
    if let sent = sentGeometry, sent.revision == ws.layoutRevision,
      sent.entries == entries
    {
      return
    }
    geometryGeneration += 1
    sentGeometry = (ws.layoutRevision, entries)
    let batch = GeometryBatch(
      layoutRevision: ws.layoutRevision,
      generation: geometryGeneration,
      entries: entries
    )
    let connection = connection
    commands?
      .yield {
        do { try await connection.execute(.setGeometry(batch)) } catch let error
          as MuxError where error.code == .staleGeometry
        {
          // A newer layout is on its way; resend once it arrives.
          await MainActor.run { [weak self] in self?.sentGeometry = nil }
        } catch {}
      }
  }

  // MARK: Actions

  private func command(_ command: MuxCommand) {
    let connection = connection
    commands?
      .yield {
        do {
          let reply = try await connection.execute(command)
          if case let .layout(ws) = reply {
            await MainActor.run { [weak self] in self?.apply(ws) }
          }
        } catch {
          await MainActor.run {
            FileHandle.standardError.write(
              Data("swiftty: swiftmux: \(error)\n".utf8)
            )
          }
        }
      }
  }

  func send(_ input: MuxInput, to pane: PaneID) {
    guard !detached else { return }
    inputs?.yield(.input(input, pane))
  }

  func paste(_ text: String, to pane: PaneID) {
    guard !detached else { return }
    inputs?.yield(.paste(text, pane))
  }

  func scroll(_ pane: PaneID, lines: Int) {
    command(.scroll(pane: pane, .lines(lines)))
  }

  func focus(_ pane: PaneID) {
    guard pane != activePane else { return }
    command(.focusPane(pane))
  }

  func paneBecameFirstResponder(_ view: MuxPaneView) {
    if view.pane != activePane { focus(view.pane) }
  }

  @objc
  private func tabClicked(_ sender: NSSegmentedControl) {
    guard let ws = workspace, ws.tabs.indices.contains(sender.selectedSegment)
    else { return }
    command(.selectTab(ws.tabs[sender.selectedSegment].id))
  }

  func newTab() { command(.newTab(name: nil, launch: nil)) }

  func split(_ axis: SplitAxis) {
    guard let pane = activePane else { return }
    command(.split(pane: pane, axis: axis, launch: nil))
  }

  func toggleZoom() {
    guard let tab = activeTab else { return }
    command(.toggleZoom(tab.id))
  }

  func endPane() {
    guard let pane = activePane else { return }
    command(.endPane(pane))
  }

  func cycleTab(_ delta: Int) {
    guard let ws = workspace,
      let i = ws.tabs.firstIndex(where: { $0.id == ws.activeTab })
    else { return }
    command(.selectTab(ws.tabs[(i + delta + ws.tabs.count) % ws.tabs.count].id))
  }

  /// Releases the lease; panes, layout and history stay with the service.
  func detach() async {
    guard !detached else { return }
    detached = true
    for view in views.values { view.cancelComposition() }
    inputs?.finish()
    commands?.finish()
    await connection.detach()
    await connection.close()
    for task in tasks { task.cancel() }
  }

  func windowWillClose(_ notification: Notification) {
    Task { await detach() }
    onClose?()
  }
}

/// Lays out pane views from the logical split tree; dividers drag.
@MainActor
final class MuxLayoutView: NSView {
  static let divider = 4
  weak var controller: MuxWorkspaceController?
  private var dividers: [LayoutDivider] = []
  private var dragging: LayoutDivider?

  override var isFlipped: Bool { false }

  override func layout() {
    super.layout()
    guard let controller else { return }
    let (panes, dividers) = controller.layout(in: bounds)
    self.dividers = dividers
    let shown = Set(panes.map { ObjectIdentifier($0.0) })
    for view in subviews where !shown.contains(ObjectIdentifier(view)) {
      view.isHidden = true
    }
    for (view, frame) in panes {
      view.isHidden = false
      view.frame = frame
    }
    window?.invalidateCursorRects(for: self)
  }

  private func flippedY(_ p: NSPoint) -> Int { Int(bounds.height - p.y) }

  override func resetCursorRects() {
    for d in dividers {
      let r = NSRect(
        x: d.rect.x,
        y: Int(bounds.height) - d.rect.maxY,
        width: d.rect.width,
        height: d.rect.height
      )
      addCursorRect(
        r,
        cursor: d.axis == .leftRight ? .resizeLeftRight : .resizeUpDown
      )
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if dividers.contains(where: {
      $0.rect.contains(x: Int(local.x), y: flippedY(local))
    }) {
      return self
    }
    return super.hitTest(point)
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    dragging = dividers.first { $0.rect.contains(x: Int(p.x), y: flippedY(p)) }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let d = dragging else { return }
    let p = convert(event.locationInWindow, from: nil)
    let ratio =
      d.axis == .leftRight
      ? (Double(p.x) - Double(d.parent.x)) / Double(max(1, d.parent.width))
      : (Double(flippedY(p)) - Double(d.parent.y))
        / Double(max(1, d.parent.height))
    controller?.setRatio(ratio, path: d.path)
  }

  override func mouseUp(with event: NSEvent) { dragging = nil }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    bounds.fill()
  }
}

struct MuxUnavailable: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}

extension String { fileprivate var nonEmpty: String? { isEmpty ? nil : self } }
