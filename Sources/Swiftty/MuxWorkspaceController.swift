import AppKit
import MuxNavigation
import ServiceManagement
import Synchronization
import SwiftMuxClient
import SwiftMuxProtocol
import SwifttyCore
import SwifttyMac

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
  /// The workspace this connection holds the lease for, from the last
  /// attach, switch or takeover reply. Snapshots of any other workspace
  /// (a late layout event after a switch) are not shown.
  private(set) var attachedWorkspace: WorkspaceID?
  /// Highest layout revision shown per workspace.
  private var layoutRevisions: [WorkspaceID: UInt64] = [:]
  /// The newest snapshot that arrived for a workspace not (yet) attached:
  /// its layout event can overtake the switch reply.
  private var earlySnapshot: WorkspaceSnapshot?
  private(set) var views: [PaneID: MuxPaneView] = [:]
  private(set) var containers: [PaneID: MuxPaneContainer] = [:]
  let tabStrip = MuxTabStrip()
  /// Sanitized program titles, from snapshots and title events.
  private var titles: [PaneID: String] = [:]
  /// Panes with output the user has not seen (hidden tabs, bells).
  private(set) var activity: Set<PaneID> = []
  /// A divider drag shown locally before the service commits it.
  private var ratioProposal: RatioProposal?
  private var ratioSending = false
  /// Test hook: answers destructive confirmations without a sheet.
  var confirmDestructive: ((String) async -> Bool)?
  let layoutView = MuxLayoutView()
  private var inputs: AsyncStream<InputJob>.Continuation?
  private var commands: AsyncStream<@Sendable () async -> Void>.Continuation?
  private var tasks: [Task<Void, Never>] = []
  private var geometryGeneration: UInt64 = 0
  private var sentGeometry: (revision: UInt64, entries: [GeometryBatch.Entry])?
  private var geometryScheduled = false
  private var subscribed: [PaneID] = []
  private var detached = false
  /// Whether this window still holds its workspace's lease: false once
  /// it detached, lost its connection or another frontend took over
  /// (the window then shows "SwiftMux — detached").
  var holdsLease: Bool { !detached && attachedWorkspace != nil }
  var onClose: (() -> Void)?
  private(set) var searchBar: SearchBar?
  private var appearanceObservation: NSKeyValueObservation?
  /// Attention inbox mirror, fed by its own subscription (not frames).
  private(set) var inbox = MuxInboxModel()
  let inboxToolbar = MuxInboxToolbar()
  private var inboxPopover: NSPopover?
  private(set) var inboxView: MuxInboxViewController?

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
    tabStrip.translatesAutoresizingMaskIntoConstraints = false
    tabStrip.onSelect = { [weak self] tab in self?.selectTab(tab) }
    tabStrip.onClose = { [weak self] tab in self?.closeTab(tab) }
    tabStrip.onRename = { [weak self] tab, name in self?.renameTab(tab, name) }
    tabStrip.onNew = { [weak self] in self?.newTab() }
    layoutView.translatesAutoresizingMaskIntoConstraints = false
    layoutView.controller = self
    content.addSubview(tabStrip)
    content.addSubview(layoutView)
    NSLayoutConstraint.activate([
      tabStrip.topAnchor.constraint(equalTo: content.topAnchor),
      tabStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      tabStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      layoutView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
      layoutView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      layoutView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      layoutView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
    window.contentView = content
    inboxToolbar.onClick = { [weak self] in self?.toggleInbox() }
    window.toolbar = inboxToolbar.toolbar
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
        message: "The running SwiftMux service is a different version "
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
  /// in-process service). With `expectedLease`, explicitly takes over the
  /// workspace from whoever holds that lease generation; callers pass it
  /// only after the user confirmed a takeover prompt.
  static func open(
    _ selector: WorkspaceSelector?,
    configuration: Configuration,
    connection: MuxConnection,
    takeover expectedLease: UInt64? = nil
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
    let attach: MuxCommand =
      expectedLease.map { .takeover(target, expectedLease: $0) }
      ?? .attach(target)
    guard
      case let .attached(_, ws) = try await connection.execute(attach)
    else { throw MuxError(.invalidRequest, "unexpected attach reply") }
    let controller = MuxWorkspaceController(
      connection: connection,
      welcome: welcome,
      configuration: configuration
    )
    controller.apply(ws, attached: true)
    controller.startEvents()
    controller.startInbox()
    controller.sendTheme()
    controller.observeAppearance()
    return controller
  }

  /// Opens `selector` on the new `connection` and only then leaves
  /// `current` (one SwiftMux window and lease at a time). A failed attach
  /// (`leaseHeld` before a confirmed takeover, `staleRevision`, …)
  /// closes `connection` and leaves `current` with its window and lease.
  static func replace(
    _ current: MuxWorkspaceController?,
    with selector: WorkspaceSelector,
    configuration: Configuration,
    connection: MuxConnection,
    takeover expectedLease: UInt64? = nil
  ) async throws -> MuxWorkspaceController {
    let controller: MuxWorkspaceController
    do {
      controller = try await open(
        selector,
        configuration: configuration,
        connection: connection,
        takeover: expectedLease
      )
    } catch {
      await connection.close()
      throw error
    }
    if let current {
      await current.detach()
      current.close()
    }
    return controller
  }

  /// Shows `target` for an attention link: in `current` while it holds
  /// that workspace's lease, otherwise attached on a new connection
  /// (`replace`; a takeover only with a confirmed `expectedLease`), so a
  /// detached window reattaches rather than sending commands without a
  /// lease. `attached` receives a new controller as soon as it holds the
  /// lease. Throws when the pane is not shown: `leaseHeld` (keeping
  /// `current`) lets the caller offer a takeover.
  static func reveal(
    _ target: PaneTarget,
    in current: MuxWorkspaceController?,
    configuration: Configuration,
    connect: @MainActor () async throws -> MuxConnection,
    takeover expectedLease: UInt64? = nil,
    attached: (MuxWorkspaceController) -> Void = { _ in }
  ) async throws -> MuxWorkspaceController {
    if let current, current.attachedWorkspace == target.workspace,
      current.holdsLease
    {
      do {
        try await current.revealAttention(pane: target.pane, tab: target.tab)
        return current
      } catch let error as MuxError where error.code == .notAttached {
        // The lease moved before the detach event arrived: attach afresh.
      }
    }
    let controller = try await replace(
      current,
      with: .id(target.workspace),
      configuration: configuration,
      connection: connect(),
      takeover: expectedLease
    )
    attached(controller)
    try await controller.revealAttention(pane: target.pane, tab: target.tab)
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

  /// Applies one non-frame event (internal for tests).
  func handle(_ event: MuxEvent) {
    switch event {
    case let .layout(ws): apply(ws)
    case let .title(pane, title):
      titles[pane] = DisplayText.sanitize(title)
      refreshChrome()
    case let .bell(pane):
      NSSound.beep()
      if pane != activePane { markActivity(pane) }
    case let .activity(pane): markActivity(pane)
    case let .detached(reason): connectionEnded(reason)
    case let .paneExited(pane, status, truncated):
      if truncated {
        window?.subtitle =
          "A pane was force-killed; its final output may be incomplete"
      }
      if let i = workspace?.panes.firstIndex(where: { $0.id == pane }) {
        workspace?.panes[i].exitStatus = status
      }
      refreshChrome()
    case let .inbox(update):
      if inbox.apply(update) {
        Task { await reloadInbox() }
      }
      refreshInbox()
    case .paste, .frameUnavailable, .frame, .workspaces: break
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

  /// Shows `ws`. With `attached`, it is the reply to an attach, switch
  /// or takeover and names the workspace this connection now holds;
  /// otherwise it is shown only for that workspace and when no older
  /// than the layout already shown.
  private func apply(_ ws: WorkspaceSnapshot, attached: Bool = false) {
    if attached, attachedWorkspace != ws.id {
      attachedWorkspace = ws.id
      if let early = earlySnapshot, early.id == ws.id,
        early.layoutRevision > ws.layoutRevision
      {
        earlySnapshot = nil
        apply(early)
        return
      }
      earlySnapshot = nil
    }
    guard ws.id == attachedWorkspace else {
      if ws.layoutRevision >= earlySnapshot?.layoutRevision ?? 0
        || earlySnapshot?.id != ws.id
      {
        earlySnapshot = ws
      }
      return
    }
    guard ws.layoutRevision >= layoutRevisions[ws.id, default: 0] else {
      return
    }
    layoutRevisions[ws.id] = ws.layoutRevision
    if let current = workspace, current.id != ws.id {
      // Switched workspaces (inbox navigation): the service dropped the
      // old subscriptions and geometry.
      subscribed = []
      sentGeometry = nil
      activity = []
    }
    workspace = ws
    for pane in ws.panes where titles[pane.id] == nil || !pane.title.isEmpty {
      titles[pane.id] = DisplayText.sanitize(pane.title)
    }
    let known = Set(ws.panes.map(\.id))
    titles = titles.filter { known.contains($0.key) }
    activity.formIntersection(known)
    guard let tab = ws.activeTabSnapshot else {
      refreshChrome()
      return
    }
    // Rebind: keep views for surviving panes, drop the rest.
    let visible = tab.zoomedPane.map { [$0] } ?? tab.layout.panes
    for (id, view) in views where !visible.contains(id) {
      view.cancelComposition()
      containers[id]?.removeFromSuperview()
      containers.removeValue(forKey: id)
      views.removeValue(forKey: id)
    }
    for id in visible where views[id] == nil {
      guard let view = try? MuxPaneView(pane: id, configuration: config) else {
        continue
      }
      view.controller = self
      let container = MuxPaneContainer(paneView: view)
      container.header.onAction = { [weak self] action in
        self?.headerAction(action, pane: id)
      }
      views[id] = view
      containers[id] = container
      layoutView.addSubview(container)
    }
    for (id, view) in views { view.isActivePane = id == tab.activePane }
    // Shown panes are seen.
    activity.subtract(visible)
    if let proposal = ratioProposal, proposal.tab != tab.id {
      ratioProposal = nil
    }
    refreshChrome()
    layoutView.needsLayout = true
    layoutView.layoutSubtreeIfNeeded()
    if let active = views[tab.activePane], window?.firstResponder !== active,
      !(window?.firstResponder is NSText)
    {
      window?.makeFirstResponder(active)
    }
    if visible != subscribed {
      subscribed = visible
      command(.setSubscriptions(visible))
    }
    geometryChanged()
  }

  // MARK: Chrome

  func title(of pane: PaneID) -> String {
    titles[pane].flatMap(\.nonEmpty) ?? "shell"
  }

  /// Tab strip, pane headers and window title from the current snapshot.
  private func refreshChrome() {
    guard let ws = workspace else { return }
    tabStrip.update(
      ws.tabs.map { tab in
        let name = DisplayText.sanitize(tab.name)
        // Service default names are numbers; show the program instead.
        let automatic = name.isEmpty || name.allSatisfy(\.isNumber)
        let label = automatic ? title(of: tab.activePane) : name
        return MuxTabItem(
          id: tab.id,
          title: label,
          symbol: MuxIcons.symbol(for: title(of: tab.activePane)),
          isActive: tab.id == ws.activeTab,
          hasActivity: tab.id != ws.activeTab
            && tab.layout.panes.contains(where: activity.contains)
        )
      }
    )
    guard let tab = ws.activeTabSnapshot else { return }
    let split = tab.layout.panes.count > 1
    for (id, container) in containers {
      container.showsHeader = split
      container.update(
        MuxPaneHeaderState(
          title: title(of: id),
          isActive: id == tab.activePane,
          hasActivity: activity.contains(id),
          isZoomed: tab.zoomedPane == id,
          hasExited: ws.pane(id)?.exitStatus != nil
        )
      )
    }
    let active = titles[tab.activePane].flatMap(\.nonEmpty)
    window?.title = active ?? workspaceTitle
  }

  private func markActivity(_ pane: PaneID) {
    guard pane != activePane || !subscribed.contains(pane) else { return }
    guard activity.insert(pane).inserted else { return }
    refreshChrome()
  }

  // MARK: Geometry

  /// The active tab's tree with any local divider drag applied.
  private var displayedLayout: LayoutNode? {
    guard let tab = activeTab else { return nil }
    if let p = ratioProposal, p.tab == tab.id,
      let moved = tab.layout.settingRatio(p.ratio, at: p.path)
    {
      return moved
    }
    return tab.layout
  }

  /// Smallest pane in points: 10 columns by 2 rows plus its header.
  var minimumPaneSize: (columns: Int, rows: Int) {
    guard let view = views.values.first else { return (80, 40) }
    let scale = view.window?.backingScaleFactor ?? 2
    let cell = view.renderer.cellSize
    let o = view.renderer.options
    return (
      Int(((cell.width * 10 + o.paddingX * 2) / scale).rounded(.up)),
      Int(((cell.height * 2 + o.paddingY * 2) / scale).rounded(.up))
        + Int(MuxPaneContainer.headerHeight)
    )
  }

  /// Frames for visible panes in points, plus dividers for dragging.
  func layout(
    in bounds: NSRect
  ) -> (panes: [(MuxPaneContainer, NSRect)], dividers: [LayoutDivider]) {
    guard let tab = activeTab, let tree = displayedLayout else {
      return ([], [])
    }
    let area = LayoutRect(
      x: 0,
      y: 0,
      width: Int(bounds.width),
      height: Int(bounds.height)
    )
    if let zoomed = tab.zoomedPane, let view = containers[zoomed] {
      return ([(view, bounds)], [])
    }
    let frames = LayoutGeometry.frames(
      tree,
      in: area,
      divider: MuxLayoutView.divider
    )
    let panes = frames.compactMap { id, r -> (MuxPaneContainer, NSRect)? in
      containers[id]
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
      LayoutGeometry.dividers(tree, in: area, divider: MuxLayoutView.divider)
    )
  }

  /// A divider drag: shown at once, sent coalesced (one request in
  /// flight, newest ratio pending), clamped to the minimum pane size.
  func setRatio(_ ratio: Double, path: [Bool]) {
    guard let tab = activeTab, let tree = displayedLayout else { return }
    let bounds = layoutView.bounds
    let clamped = LayoutGeometry.clampedRatio(
      ratio,
      at: path,
      of: tree,
      in: LayoutRect(
        x: 0,
        y: 0,
        width: Int(bounds.width),
        height: Int(bounds.height)
      ),
      minimum: minimumPaneSize,
      divider: MuxLayoutView.divider
    )
    ratioProposal = RatioProposal(tab: tab.id, path: path, ratio: clamped)
    layoutView.needsLayout = true
    flushRatio()
  }

  /// The current ratio of the split at `path` as displayed.
  func ratio(at path: [Bool]) -> Double? {
    guard case let .split(_, r, _, _)? = displayedLayout?.node(at: path) else {
      return nil
    }
    return r
  }

  private func flushRatio() {
    guard !ratioSending, !detached, let proposal = ratioProposal else { return }
    ratioSending = true
    let connection = connection
    commands?
      .yield {
        let reply = try? await connection.execute(
          .setSplitRatio(
            tab: proposal.tab,
            path: proposal.path,
            ratio: proposal.ratio
          )
        )
        await MainActor.run { [weak self] in
          guard let self else { return }
          ratioSending = false
          if ratioProposal == proposal { ratioProposal = nil }
          if case let .layout(ws)? = reply { apply(ws) }
          flushRatio()
        }
      }
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

  /// Queues `command` in order. Without `failed`, a failure is only
  /// logged; with it, the failure is handed back and `then` is skipped.
  private func command(
    _ command: MuxCommand,
    failed: (@MainActor @Sendable (any Error) -> Void)? = nil,
    then: (@MainActor @Sendable () -> Void)? = nil
  ) {
    let connection = connection
    commands?
      .yield {
        do {
          let reply = try await connection.execute(command)
          switch reply {
          case let .attached(_, ws):
            await MainActor.run { [weak self] in
              self?.apply(ws, attached: true)
            }
          case let .layout(ws):
            // A switch reply names the workspace now held.
            var switched = false
            if case .switchWorkspace = command { switched = true }
            await MainActor.run { [weak self] in
              self?.apply(ws, attached: switched)
            }
          default: break
          }
          if let then { await then() }
        } catch {
          if let failed {
            await failed(error)
            return
          }
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

  /// Moves focus to the visible pane beside the active one.
  func focus(_ direction: Direction) {
    guard let tab = activeTab, tab.zoomedPane == nil, let tree = displayedLayout
    else { return }
    let frames = LayoutGeometry.frames(
      tree,
      in: LayoutRect(x: 0, y: 0, width: 10_000, height: 10_000),
      divider: MuxLayoutView.divider
    )
    if let next = LayoutGeometry.neighbor(
      of: tab.activePane,
      direction: direction,
      frames: frames,
      order: tree.panes
    ) {
      focus(next)
      if let view = views[next] { window?.makeFirstResponder(view) }
    }
  }

  /// Moves the nearest divider beside the active pane (keyboard resize).
  func resizeActivePane(_ direction: Direction, step: Double = 0.05) {
    guard let tab = activeTab, let tree = displayedLayout else { return }
    let axis: SplitAxis =
      direction == .left || direction == .right ? .leftRight : .topBottom
    guard let split = tree.enclosingSplit(of: tab.activePane, axis: axis),
      let current = ratio(at: split.path)
    else { return }
    let grow = direction == .right || direction == .down
    setRatio(current + (grow ? step : -step), path: split.path)
  }

  /// Brings the window forward and activates `pane` (selecting `tab`
  /// first when it is not the active one), for attention links. The
  /// layout reply makes the pane's view first responder.
  func reveal(pane: PaneID, tab: TabID?) {
    if let tab = tab ?? workspace?.tab(containing: pane)?.id { selectTab(tab) }
    if pane != activePane { command(.focusPane(pane)) }
    showWindow(nil)
    window?.makeKeyAndOrderFront(nil)
    if let view = views[pane] { window?.makeFirstResponder(view) }
  }

  /// `reveal(pane:tab:)` that reports failure: `notAttached` once this
  /// window no longer holds the lease, or the service's refusal.
  func revealAttention(pane: PaneID, tab: TabID?) async throws {
    guard holdsLease else { throw MuxError(.notAttached) }
    if let tab = tab ?? workspace?.tab(containing: pane)?.id,
      tab != workspace?.activeTab
    {
      try await execute(.selectTab(tab))
    }
    if pane != activePane { try await execute(.focusPane(pane)) }
    reveal(pane: pane, tab: nil)
  }

  /// Runs `command` in order with the others and waits for its outcome.
  /// A command dropped unrun (the queue ended on detach) fails
  /// `notAttached`.
  private func execute(_ command: MuxCommand) async throws {
    try await withCheckedThrowingContinuation {
      (done: CheckedContinuation<Void, any Error>) in
      let once = Once(done)
      self.command(
        command,
        failed: { error in once.resume(throwing: error) },
        then: { once.resume() }
      )
    }
  }

  /// Resumes a continuation exactly once; released unresumed, it fails.
  private final class Once: Sendable {
    private let done: Mutex<CheckedContinuation<Void, any Error>?>

    init(_ done: CheckedContinuation<Void, any Error>) {
      self.done = Mutex(done)
    }

    func resume(throwing error: (any Error)? = nil) {
      guard let done = self.done.withLock({ $0.take() }) else { return }
      if let error { done.resume(throwing: error) } else { done.resume() }
    }

    deinit { resume(throwing: MuxError(.notAttached)) }
  }

  func selectTab(_ tab: TabID) {
    guard tab != workspace?.activeTab else { return }
    command(.selectTab(tab))
  }

  func renameTab(_ tab: TabID, _ name: String) {
    let clean = DisplayText.sanitize(name)
    guard !clean.isEmpty else { return }
    command(.renameTab(tab, name: clean))
  }

  func beginRenamingActiveTab() {
    tabStrip.buttons.first { $0.item?.isActive == true }?.beginRename()
  }

  func newTab() { command(.newTab(name: nil, launch: nil)) }

  func split(_ axis: SplitAxis, pane: PaneID? = nil) {
    guard let pane = pane ?? activePane else { return }
    command(.split(pane: pane, axis: axis, launch: nil))
  }

  func toggleZoom(pane: PaneID? = nil) {
    guard let tab = activeTab else { return }
    if let pane, pane != tab.activePane { command(.focusPane(pane)) }
    command(.toggleZoom(tab.id))
  }

  private func headerAction(_ action: MuxPaneHeader.Action, pane: PaneID) {
    switch action {
    case .splitRight: split(.leftRight, pane: pane)
    case .splitDown: split(.topBottom, pane: pane)
    case .zoom: toggleZoom(pane: pane)
    case .close: endPane(pane)
    }
  }

  /// Whether ending `panes` would terminate a running process.
  private func running(_ panes: [PaneID]) -> Bool {
    panes.contains { workspace?.pane($0)?.exitStatus == nil }
  }

  /// Destructive actions terminate only their target, and ask first
  /// while a process is still running. Hiding and closing views never
  /// end anything.
  func endPane(_ pane: PaneID? = nil) {
    guard let pane = pane ?? activePane else { return }
    let name = title(of: pane)
    confirmThen(
      running([pane]),
      "End the pane “\(name)”?",
      "Its process is still running and will be terminated."
    ) { [weak self] in self?.command(.endPane(pane)) }
  }

  func closeTab(_ tab: TabID? = nil) {
    guard let ws = workspace,
      let snapshot = ws.tabs.first(where: { $0.id == (tab ?? ws.activeTab) })
    else { return }
    let panes = snapshot.layout.panes
    confirmThen(
      running(panes),
      "End the tab “\(title(of: snapshot.activePane))”?",
      panes.count == 1
        ? "Its process is still running and will be terminated."
        : "Its \(panes.count) panes and their processes will be terminated."
    ) { [weak self] in self?.command(.endTab(snapshot.id)) }
  }

  private func confirmThen(
    _ ask: Bool,
    _ message: String,
    _ detail: String,
    button: String = "End",
    _ action: @escaping @MainActor () -> Void
  ) {
    guard ask else { return action() }
    Task { @MainActor [weak self] in
      guard let self else { return }
      let ok: Bool
      if let hook = confirmDestructive {
        ok = await hook(message)
      } else {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        if let window {
          ok =
            await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        } else {
          ok = alert.runModal() == .alertFirstButtonReturn
        }
      }
      if ok { action() }
    }
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

  // MARK: Theme

  /// Default colours and scheme reported by the service-side engines
  /// follow the app's theme (spec §7.1).
  func sendTheme() {
    let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
    let scheme = TerminalView.scheme(of: appearance)
    let p = config.palette(for: scheme)
    var colors: [UInt32] = []
    colors.reserveCapacity(256)
    for i in 0 ..< 256 { colors.append(p.colors[i]) }
    command(
      .setTheme(
        MuxTheme(
          palette: FramePalette(
            colors: colors,
            foreground: p.foreground,
            background: p.background,
            cursor: p.cursor,
            cursorText: p.cursorText,
            selectionForeground: p.selectionForeground,
            selectionBackground: p.selectionBackground
          ),
          dark: scheme == .dark
        )
      )
    )
  }

  func observeAppearance() {
    appearanceObservation = NSApp.observe(\.effectiveAppearance) {
      [weak self] _, _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.sendTheme() }
      }
    }
  }

  /// A configuration reload: new colours reach the engines.
  func apply(_ configuration: Configuration) {
    config = configuration
    sendTheme()
  }

  // MARK: Search

  /// Literal search over the active pane's service-side history; the
  /// viewport follows the selected match and frames carry highlights.
  func performFind(_ action: NSFindPanelAction?) {
    guard let pane = activePane else { return }
    switch action {
    case .next: command(.searchStep(pane: pane, forward: false))
    case .previous: command(.searchStep(pane: pane, forward: true))
    default: showSearch()
    }
  }

  func showSearch() {
    guard let content = window?.contentView else { return }
    if searchBar == nil {
      let bar = SearchBar()
      bar.onChange = { [weak self] query in self?.search(query) }
      bar.onNavigate = { [weak self] older in
        guard let pane = self?.activePane else { return }
        self?.command(.searchStep(pane: pane, forward: !older))
      }
      bar.onClose = { [weak self] in self?.hideSearch() }
      bar.autoresizingMask = [.minXMargin, .minYMargin]
      content.addSubview(bar)
      searchBar = bar
    }
    searchBar?.position(in: content.bounds)
    searchBar?.isHidden = false
    window?.makeFirstResponder(searchBar?.field)
  }

  private func search(_ query: String) {
    guard let pane = activePane else { return }
    guard !query.isEmpty, query.utf8.count <= limits.maxSearchBytes else {
      command(.endSearch(pane: pane))
      return
    }
    command(.search(pane: pane, query: query))
  }

  func hideSearch() {
    searchBar?.isHidden = true
    searchBar?.text = ""
    if let pane = activePane {
      command(.endSearch(pane: pane))
      command(.scroll(pane: pane, .bottom))
      if let view = views[pane] { window?.makeFirstResponder(view) }
    }
  }

  // MARK: Attention inbox

  /// Rows requested per inbox page (the service caps it at 100).
  var inboxPageLimit = 100
  /// The last failed inbox command: shown inline while the popover is
  /// open, otherwise kept for the next time it opens.
  private(set) var inboxMessage: String?

  /// Subscribes to inbox metadata: no lease, frames or resize involved.
  func startInbox() {
    let connection = connection
    Task { [weak self] in
      do {
        _ = try await connection.execute(.subscribeInbox(true))
        await self?.reloadInbox()
      } catch { self?.inboxFailed(error, alert: false) }
    }
  }

  /// Rereads the first page of each section (after subscribing, a
  /// `resync` or a stale or missing item).
  func reloadInbox() async {
    var pages: [InboxQuery.Section: InboxPage] = [:]
    for section in MuxInboxModel.sections {
      do {
        guard
          case let .inbox(page) = try await connection.execute(
            .inbox(InboxQuery(section: section, limit: inboxPageLimit))
          )
        else { throw MuxError(.invalidRequest, "unexpected inbox reply") }
        pages[section] = page
      } catch {
        inboxFailed(error, alert: false)
        return
      }
    }
    inbox.reset(pages)
    refreshInbox()
  }

  /// Reads the next page of every section that has one ("Load More").
  func loadMoreInbox() async {
    for section in MuxInboxModel.sections {
      guard let cursor = inbox.cursors[section] else { continue }
      do {
        guard
          case let .inbox(page) = try await connection.execute(
            .inbox(
              InboxQuery(
                section: section,
                cursor: cursor,
                limit: inboxPageLimit
              )
            )
          )
        else { throw MuxError(.invalidRequest, "unexpected inbox reply") }
        inbox.append(page, section: section)
      } catch {
        // A cursor the service no longer accepts: start over.
        inboxFailed(error, alert: true)
        await reloadInbox()
        return
      }
    }
    refreshInbox()
  }

  private func refreshInbox() {
    inboxToolbar.update(inbox.counts)
    if inboxPopover?.isShown == true {
      inboxView?.update(inbox)
    }
  }

  /// Reports a failed inbox command: inline while the popover is open,
  /// otherwise as an alert when `alert` (user-initiated commands).
  private func inboxFailed(_ error: any Error, alert: Bool) {
    inboxProblem(MuxInboxModel.describe(error), alert: alert)
  }

  private func inboxProblem(_ message: String, alert: Bool) {
    inboxMessage = message
    if inboxPopover?.isShown == true {
      inboxView?.show(message: message)
    } else if alert {
      notice(message)
    }
  }

  /// Checks a lookup reply: a stale or missing item is reported, dropped
  /// and the list reread. Returns the location while the item is there.
  private func checked(
    _ reply: MuxReply,
    _ item: AttentionItem,
    alert: Bool
  ) -> AttentionLocation? {
    guard case let .attention(location) = reply else {
      inboxFailed(MuxError(.invalidRequest, "unexpected reply"), alert: alert)
      return nil
    }
    if let problem = MuxInboxModel.describe(location.availability) {
      inbox.forget(item.occurrence)
      inboxProblem(problem, alert: alert)
      Task { [weak self] in await self?.reloadInbox() }
      return nil
    }
    return location
  }

  func toggleInbox() {
    if let popover = inboxPopover, popover.isShown {
      popover.performClose(nil)
      return
    }
    let view = inboxView ?? MuxInboxViewController()
    // A failure from while the popover was closed is shown once.
    view.show(message: inboxMessage)
    inboxMessage = nil
    view.onOpen = { [weak self] item in self?.openAttention(item) }
    view.onReview = { [weak self] item in self?.markReviewed(item) }
    view.onSnooze = { [weak self] item, until in
      self?.snooze(item, until: until)
    }
    view.onLoadMore = { [weak self] in Task { await self?.loadMoreInbox() } }
    // Showing an item marks it seen; it never resolves it.
    view.onShown = { [weak self] items in
      for item in items where !item.seen { self?.markSeen(item) }
    }
    inboxView = view
    let popover = inboxPopover ?? NSPopover()
    popover.behavior = .transient
    popover.contentViewController = view
    inboxPopover = popover
    view.update(inbox)
    guard let content = window?.contentView else { return }
    popover.show(
      relativeTo: NSRect(
        x: content.bounds.maxX - 40,
        y: content.bounds.maxY - 2,
        width: 1,
        height: 1
      ),
      of: content,
      preferredEdge: .minY
    )
  }

  private func reference(_ item: AttentionItem) -> AttentionReference {
    AttentionReference(source: item.source, occurrence: item.occurrence)
  }

  /// Runs one inbox command against `item`, reporting failures and
  /// stale or missing items.
  private func attention(
    _ command: MuxCommand,
    _ item: AttentionItem,
    alert: Bool,
    then: (@MainActor (AttentionLocation) -> Void)? = nil
  ) {
    let connection = connection
    Task { [weak self] in
      do {
        let reply = try await connection.execute(command)
        guard let self, let location = checked(reply, item, alert: alert) else {
          return
        }
        then?(location)
      } catch { self?.inboxFailed(error, alert: alert) }
    }
  }

  private func markSeen(_ item: AttentionItem) {
    attention(.markSeen(reference(item)), item, alert: false)
  }

  func markReviewed(_ item: AttentionItem) {
    guard item.category != .needsYou else { return }
    attention(.markReviewed(reference(item)), item, alert: true)
  }

  /// Snoozes a waiting request until `until`, or clears its snooze.
  func snooze(_ item: AttentionItem, until: Date?) {
    guard MuxInboxModel.canSnooze(item) else { return }
    attention(.snooze(reference(item), until: until), item, alert: true)
  }

  /// Opens the item's pane: marks it seen, then reveals the pane in this
  /// workspace. Another workspace is switched to, and one controlled
  /// elsewhere is taken over only after explicit confirmation.
  func openAttention(_ item: AttentionItem) {
    attention(.markSeen(reference(item)), item, alert: true) {
      [weak self] location in self?.reveal(location)
    }
  }

  private func reveal(_ location: AttentionLocation) {
    guard let wsID = location.workspace, let pane = location.pane else {
      inboxProblem("This item is no longer available.", alert: true)
      return
    }
    inboxPopover?.performClose(nil)
    if wsID == workspace?.id {
      guard workspace?.pane(pane) != nil else {
        notice("That pane is no longer open.")
        return
      }
      if pane != activePane { command(.focusPane(pane)) }
      return
    }
    guard location.leaseHeldElsewhere else {
      command(
        .switchWorkspace(.id(wsID)),
        failed: { [weak self] error in
          // Another frontend attached in between: ask before taking over.
          if (error as? MuxError)?.code == .leaseHeld {
            self?.confirmTakeover(wsID, pane: pane, moved: false)
          } else {
            self?.inboxFailed(error, alert: true)
          }
        },
        then: { [weak self] in self?.focusRevealed(pane) }
      )
      return
    }
    confirmTakeover(wsID, pane: pane, moved: false)
  }

  /// Focuses `pane` after a switch or takeover, reporting a pane that
  /// ended in the meantime.
  private func focusRevealed(_ pane: PaneID) {
    command(
      .focusPane(pane),
      failed: { [weak self] error in self?.inboxFailed(error, alert: true) }
    )
  }

  /// Asks before taking over `wsID` at the lease generation listed now.
  /// If the lease moves while asking, the takeover fails `staleRevision`
  /// and the user is asked again about the new holder.
  private func confirmTakeover(_ wsID: WorkspaceID, pane: PaneID, moved: Bool) {
    let connection = connection
    Task { [weak self] in
      let summary: WorkspaceSummary
      do {
        guard
          case let .workspaces(list) = try await connection.execute(
            .listWorkspaces
          ), let found = list.first(where: { $0.id == wsID })
        else { throw MuxError(.notFound) }
        summary = found
      } catch {
        self?.inboxFailed(error, alert: true)
        return
      }
      let name = DisplayText.sanitize(summary.name)
      self?
        .confirmThen(
          true,
          moved
            ? "Control of workspace “\(name)” changed while you were deciding. Take control now?"
            : "Take control of workspace “\(name)”?",
          "Another window or device controls it. Taking over disconnects it there; its programs keep running.",
          button: "Take Over"
        ) { [weak self] in
          self?
            .command(
              .takeover(.id(wsID), expectedLease: summary.leaseGeneration),
              failed: { [weak self] error in
                if (error as? MuxError)?.code == .staleRevision {
                  self?.confirmTakeover(wsID, pane: pane, moved: true)
                } else {
                  self?.inboxFailed(error, alert: true)
                }
              },
              then: { [weak self] in self?.focusRevealed(pane) }
            )
        }
    }
  }

  private func notice(_ message: String) {
    if let hook = confirmDestructive {
      Task { _ = await hook(message) }
      return
    }
    let alert = NSAlert()
    alert.messageText = message
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
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
  private(set) var dividers: [LayoutDivider] = []
  private var dragging: LayoutDivider?
  private var dividerElements: [MuxDividerElement] = []

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
    dividerElements = dividers.map { d in
      let element = MuxDividerElement(divider: d, in: self)
      element.setAccessibilityFrameInParentSpace(appKitRect(d.rect))
      return element
    }
  }

  func appKitRect(_ r: LayoutRect) -> NSRect {
    NSRect(
      x: r.x,
      y: Int(bounds.height) - r.maxY,
      width: r.width,
      height: r.height
    )
  }

  override func accessibilityChildren() -> [Any]? {
    (super.accessibilityChildren() ?? []) + dividerElements
  }

  private func flippedY(_ p: NSPoint) -> Int { Int(bounds.height - p.y) }

  override func resetCursorRects() {
    for d in dividers {
      addCursorRect(
        appKitRect(d.rect),
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

/// A split handle for assistive technologies: its value is the first
/// child's share; increment and decrement move it in 5% steps.
/// AppKit calls accessibility on the main thread.
final class MuxDividerElement: NSAccessibilityElement {
  let divider: LayoutDivider
  private weak var layoutView: MuxLayoutView?

  @MainActor
  init(divider: LayoutDivider, in view: MuxLayoutView) {
    self.divider = divider
    layoutView = view
    super.init()
    setAccessibilityParent(view)
    setAccessibilityRole(.splitter)
    setAccessibilityOrientation(
      divider.axis == .leftRight ? .vertical : .horizontal
    )
    setAccessibilityLabel(
      divider.axis == .leftRight ? "Left/right divider" : "Top/bottom divider"
    )
  }

  override func accessibilityValue() -> Any? {
    let (view, path) = (layoutView, divider.path)
    return MainActor.assumeIsolated { view?.controller?.ratio(at: path) }
      .map { $0 as NSNumber }
  }

  override func accessibilityPerformIncrement() -> Bool { move(0.05) }
  override func accessibilityPerformDecrement() -> Bool { move(-0.05) }

  private func move(_ delta: Double) -> Bool {
    let (view, path) = (layoutView, divider.path)
    return MainActor.assumeIsolated {
      guard let controller = view?.controller,
        let ratio = controller.ratio(at: path)
      else { return false }
      controller.setRatio(ratio + delta, path: path)
      return true
    }
  }
}

struct RatioProposal: Equatable {
  var tab: TabID
  var path: [Bool]
  var ratio: Double
}

struct MuxUnavailable: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}

extension String { fileprivate var nonEmpty: String? { isEmpty ? nil : self } }
