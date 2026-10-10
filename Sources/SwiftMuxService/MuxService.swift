import Darwin
import Dispatch
import Foundation
import SwiftMuxProtocol
import os

public struct MuxServiceConfiguration: Sendable {
  public var launcherPath: String
  public var limits = MuxLimits.standard
  public var innerTerm = SMX.fallbackInnerTerm
  public var terminfoDirectory: String?
  /// Code-signing requirement every peer must satisfy (shipping builds).
  public var peerRequirement: String?
  /// Exit delay once the service reaches its empty-state barrier; nil
  /// keeps the service running (tests, foreground use).
  public var idleExitDelay: TimeInterval?

  public init(launcherPath: String) { self.launcherPath = launcherPath }
}

/// The persistent session service: workspace graph, stable identities,
/// the single interactive lease, layout revisions and frame delivery.
///
/// Isolated to one serial queue, which is also every XPC connection's
/// queue, so messages from a client are handled in arrival order.
public actor MuxService {
  public nonisolated let queue: DispatchSerialQueue
  public nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  public nonisolated let instance = ServerInstanceID()
  nonisolated let configuration: MuxServiceConfiguration
  nonisolated let launcher: PaneLauncher
  private let log = Logger(
    subsystem: "com.chr33s.swiftty.swiftmux",
    category: "service"
  )
  private let startedAt = Date()

  private var workspaces: [Workspace] = []
  private var panes: [PaneID: PaneRecord] = [:]
  private var clients: [UUID: Client] = [:]
  private var lease: Lease?
  private var pendingLaunches = 0
  private var pendingHistoryBytes = 0
  private var quiescing = false
  private var inflightFrameBytes = 0
  private var pumpScheduled = false
  private var pumpCursor = 0
  private var idleWork: DispatchWorkItem?
  private var listeners: [SMXListener] = []
  /// Called once the empty-state barrier holds for `idleExitDelay`.
  private var onIdle: (@Sendable () -> Void)?

  var limits: MuxLimits { configuration.limits }

  public init(configuration: MuxServiceConfiguration) {
    self.configuration = configuration
    queue = DispatchSerialQueue(label: "swiftmux.service", qos: .userInitiated)
    launcher = PaneLauncher(
      launcherPath: configuration.launcherPath,
      innerTerm: configuration.innerTerm,
      terminfoDirectory: configuration.terminfoDirectory
    )
  }

  // MARK: Listening

  /// Accepts connections on a launchd Mach service.
  public nonisolated func listen(machService name: String) {
    let listener = SMXListener(machService: name, queue: queue)
    start(listener)
  }

  /// Accepts connections on an anonymous endpoint (tests, in-process).
  public nonisolated func listenAnonymously() -> SMXEndpoint {
    let listener = SMXListener(anonymousOn: queue)
    start(listener)
    return listener.endpoint
  }

  private nonisolated func start(_ listener: SMXListener) {
    listener.activate(connectionQueue: queue) { [weak self] channel in
      guard let self else { return }
      self.queue.async { self.assumeIsolated { $0.accept(channel) } }
    }
    queue.async { self.assumeIsolated { $0.listeners.append(listener) } }
  }

  public nonisolated func setIdleHandler(
    _ handler: @escaping @Sendable () -> Void
  ) {
    queue.async {
      self.assumeIsolated {
        $0.onIdle = handler
        $0.checkIdle()
      }
    }
  }

  private nonisolated func onQueue(
    _ body: @escaping @Sendable (isolated MuxService) -> Void
  ) { queue.async { self.assumeIsolated(body) } }

  // MARK: Connections

  private func accept(_ channel: SMXChannel) {
    // OS-provided peer identity, never a claimed pid or bundle id.
    guard channel.peerEUID == geteuid() else {
      log.error("rejecting peer with euid \(channel.peerEUID)")
      channel.cancel()
      return
    }
    if let requirement = configuration.peerRequirement,
      !channel.requirePeer(codeSigning: requirement)
    {
      channel.cancel()
      return
    }
    let client = Client(channel: channel)
    clients[client.id] = client
    idleWork?.cancel()
    let id = client.id
    channel.activate { [weak self] event in
      guard let self else { return }
      self.assumeIsolated { service in
        switch event {
        case let .message(data): service.receive(data, from: id)
        case let .closed(reason): service.disconnected(id, reason: reason)
        }
      }
    }
  }

  private func disconnected(_ id: UUID, reason: String) {
    guard clients.removeValue(forKey: id) != nil else { return }
    if lease?.client == id {
      // Connection loss: cancel remaining input, release the lease.
      releaseLease(notify: false, reason: "connection lost: \(reason)")
    }
    checkIdle()
  }

  private func send(_ message: ServerMessage, to id: UUID) {
    guard let client = clients[id] else { return }
    do {
      client.channel.send(
        try SMXCodec.encode(message, limit: SMXCodec.serverRecordLimit(limits))
      )
    } catch { log.error("encode failed: \(error.description)") }
  }

  private func receive(_ data: Data, from id: UUID) {
    guard let client = clients[id] else { return }
    let message: ClientMessage
    do {
      message = try SMXCodec.decode(
        ClientMessage.self,
        from: data,
        limit: SMXCodec.clientRecordLimit(limits)
      )
    } catch {
      send(.rejected(error), to: id)
      return
    }
    guard let hello = client.hello else {
      guard case let .hello(hello) = message else {
        send(.rejected(MuxError(.invalidRequest, "expected hello")), to: id)
        client.channel.cancel()
        return
      }
      handshake(hello, client: client)
      return
    }
    switch message {
    case .hello:
      send(.rejected(MuxError(.invalidRequest, "duplicate hello")), to: id)
    case let .request(requestID, command):
      handle(command, from: client, hello: hello) { [weak self] result in
        self?.onQueue { $0.send(.reply(id: requestID, result: result), to: id) }
      }
    case let .input(record): input(record, from: id)
    case let .frameAck(pane, revision): frameAck(pane, revision, from: id)
    }
  }

  private func handshake(_ hello: Hello, client: Client) {
    guard SMX.compatibleVersions.contains(hello.protocolVersion) else {
      send(
        .rejected(
          MuxError(
            .incompatibleVersion,
            "service speaks SMX/\(SMX.protocolVersion) (\(SMX.build)); client \(hello.build) speaks SMX/\(hello.protocolVersion)"
          )
        ),
        to: client.id
      )
      client.channel.cancel()
      return
    }
    if hello.frontend == .terminal, hello.terminalProfile != SMX.terminalProfile
    {
      send(
        .rejected(
          MuxError(
            .invalidRequest,
            "unsupported terminal profile \(hello.terminalProfile ?? "none")"
          )
        ),
        to: client.id
      )
      client.channel.cancel()
      return
    }
    client.hello = hello
    send(
      .welcome(
        Welcome(
          protocolVersion: SMX.protocolVersion,
          build: SMX.build,
          server: instance,
          acceptedProfile: hello.frontend == .terminal
            ? SMX.terminalProfile : nil,
          limits: limits,
          innerTerm: configuration.innerTerm
        )
      ),
      to: client.id
    )
  }

  // MARK: Commands

  private typealias Reply = @Sendable (MuxResult) -> Void

  private func handle(
    _ command: MuxCommand,
    from client: Client,
    hello: Hello,
    reply: @escaping Reply
  ) {
    let ok = { reply(.success(.ok)) }
    let fail = { (e: MuxError) in reply(.failure(e)) }
    if command.requiresLease, lease?.client != client.id {
      fail(MuxError(.notAttached, "this connection holds no attachment"))
      return
    }
    switch command {
    case .status: reply(.success(.status(status)))
    case .listWorkspaces: reply(.success(.workspaces(summaries)))
    case let .newWorkspace(request): newWorkspace(request, reply: reply)
    case let .endWorkspace(selector):
      guard let ws = workspace(selector) else {
        return fail(notFound(selector))
      }
      endWorkspace(ws.id)
      ok()
    case let .renameWorkspace(selector, name):
      guard let i = workspaceIndex(selector) else {
        return fail(notFound(selector))
      }
      guard validName(name) else {
        return fail(MuxError(.invalidRequest, "name"))
      }
      workspaces[i].name = name
      commitLayout(workspaces[i].id)
      ok()
    case .detachActive:
      if lease != nil {
        releaseLease(notify: true, reason: "detached by request")
      }
      ok()
    case .endAllWorkspaces:
      quiescing = true
      for ws in workspaces { endWorkspace(ws.id) }
      ok()
    case let .attach(selector):
      guard hello.frontend != .control else {
        return fail(
          MuxError(.invalidRequest, "control connections cannot attach")
        )
      }
      guard !quiescing else {
        return fail(MuxError(.quiescing, "service is preparing to update"))
      }
      guard lease == nil else {
        return fail(MuxError(.alreadyAttached, "another frontend is attached"))
      }
      guard let ws = workspace(selector) else {
        return fail(notFound(selector))
      }
      // Lease and snapshot at one ordering point; frames follow on
      // subscription.
      let newLease = Lease(client: client.id, workspace: ws.id)
      lease = newLease
      idleWork?.cancel()
      reply(
        .success(
          .attached(attachment: newLease.attachment, workspace: snapshot(ws))
        )
      )
    case .detach:
      releaseLease(notify: false, reason: "detached")
      ok()
    case let .switchWorkspace(selector):
      guard let ws = workspace(selector) else {
        return fail(notFound(selector))
      }
      cancelPastes()
      _ = setSubscriptions([])
      lease?.workspace = ws.id
      reply(.success(.layout(snapshot(ws))))
    default: handleLeased(command, reply: reply)
    }
  }

  /// Commands acting on the attached workspace (lease already checked).
  private func handleLeased(_ command: MuxCommand, reply: @escaping Reply) {
    let ok = { reply(.success(.ok)) }
    let fail = { (e: MuxError) in reply(.failure(e)) }
    switch command {
    case let .newTab(name, launch):
      newTab(name: name, launch: launch, reply: reply)
    case let .selectTab(tab):
      guard let (w, t) = locate(tab: tab) else {
        return fail(MuxError(.notFound, "tab"))
      }
      workspaces[w].activeTab = workspaces[w].tabs[t].id
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .renameTab(tab, name):
      guard let (w, t) = locate(tab: tab) else {
        return fail(MuxError(.notFound, "tab"))
      }
      guard validName(name) else {
        return fail(MuxError(.invalidRequest, "name"))
      }
      workspaces[w].tabs[t].name = name
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .endTab(tab):
      guard let (w, t) = locate(tab: tab) else {
        return fail(MuxError(.notFound, "tab"))
      }
      let wsID = workspaces[w].id
      for pane in workspaces[w].tabs[t].layout.panes { endPane(pane) }
      reply(
        .success(
          workspaces.contains { $0.id == wsID } ? .layout(snapshot(wsID)!) : .ok
        )
      )
    case let .split(pane, axis, launch):
      split(pane, axis: axis, launch: launch, reply: reply)
    case let .focusPane(pane):
      guard let (w, t) = locate(pane: pane) else {
        return fail(MuxError(.notFound, "pane"))
      }
      workspaces[w].tabs[t].activePane = pane
      workspaces[w].activeTab = workspaces[w].tabs[t].id
      if let z = workspaces[w].tabs[t].zoomedPane, z != pane {
        workspaces[w].tabs[t].zoomedPane = nil
      }
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .toggleZoom(tab):
      guard let (w, t) = locate(tab: tab) else {
        return fail(MuxError(.notFound, "tab"))
      }
      let current = workspaces[w].tabs[t]
      workspaces[w].tabs[t].zoomedPane =
        current.zoomedPane == nil && current.layout.panes.count > 1
        ? current.activePane : nil
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .setSplitRatio(tab, path, ratio):
      guard let (w, t) = locate(tab: tab) else {
        return fail(MuxError(.notFound, "tab"))
      }
      guard ratio.isFinite, ratio > 0.02, ratio < 0.98,
        let layout = workspaces[w].tabs[t].layout.settingRatio(ratio, at: path)
      else { return fail(MuxError(.invalidRequest, "split ratio")) }
      workspaces[w].tabs[t].layout = layout
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .endPane(pane):
      guard
        locate(pane: pane) != nil || panes[pane]?.detachedFromLayout == false
      else { return fail(MuxError(.notFound, "pane")) }
      let ws = panes[pane]?.workspace
      endPane(pane)
      if let ws, let snap = snapshot(ws) {
        reply(.success(.layout(snap)))
      } else {
        ok()
      }
    case let .setGeometry(batch):
      if let error = setGeometry(batch) { fail(error) } else { ok() }
    case let .setSubscriptions(list):
      if let error = setSubscriptions(list) { fail(error) } else { ok() }
    case let .scroll(pane, request):
      guard let runtime = attachedRuntime(pane) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.scroll(request) { error in
        reply(error.map { .failure($0) } ?? .success(.ok))
      }
    case let .search(pane, query):
      guard query.utf8.count <= limits.maxSearchBytes, !query.isEmpty else {
        return fail(MuxError(.invalidRequest, "search query"))
      }
      guard let runtime = attachedRuntime(pane) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.search(query, step: nil) { reply(.success(.search($0))) }
    case let .searchStep(pane, forward):
      guard let runtime = attachedRuntime(pane) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.search(nil, step: forward) { reply(.success(.search($0))) }
    case let .endSearch(pane):
      guard let runtime = attachedRuntime(pane) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.search(nil, step: nil) { reply(.success(.search($0))) }
    case let .quiesce(on):
      quiescing = on
      ok()
    case .status, .listWorkspaces, .newWorkspace, .endWorkspace,
      .renameWorkspace, .detachActive, .endAllWorkspaces, .attach, .detach,
      .switchWorkspace:
      ok()  // handled by `handle`
    }
  }

  private func notFound(_ selector: WorkspaceSelector) -> MuxError {
    switch selector {
    case let .id(id): MuxError(.notFound, "workspace \(id.short)")
    case let .name(n): MuxError(.notFound, "workspace \"\(n)\"")
    case .latest: MuxError(.notFound, "no workspaces")
    }
  }

  private func validName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.count <= limits.maxNameBytes
      && !name.unicodeScalars.contains {
        $0.properties.generalCategory == .control
      }
  }

  // MARK: Model queries

  private var status: ServiceStatus {
    ServiceStatus(
      server: instance,
      build: SMX.build,
      pid: getpid(),
      startedAt: startedAt,
      workspaces: workspaces.count,
      panes: panes.count,
      attached: lease != nil,
      quiescing: quiescing,
      innerTerm: configuration.innerTerm
    )
  }

  private var summaries: [WorkspaceSummary] {
    workspaces.map { ws in
      WorkspaceSummary(
        id: ws.id,
        name: ws.name,
        tabCount: ws.tabs.count,
        paneCount: ws.allPanes.count,
        createdAt: ws.createdAt,
        isAttached: lease?.workspace == ws.id
      )
    }
  }

  private func workspaceIndex(_ selector: WorkspaceSelector) -> Int? {
    switch selector {
    case let .id(id): workspaces.firstIndex { $0.id == id }
    case let .name(name):
      workspaces.firstIndex { $0.name == name }
        ?? workspaces.firstIndex {
          $0.id.description.lowercased().hasPrefix(name.lowercased())
        }
    case .latest: workspaces.indices.last
    }
  }

  private func workspace(_ selector: WorkspaceSelector) -> Workspace? {
    workspaceIndex(selector).map { workspaces[$0] }
  }

  private func locate(tab: TabID) -> (Int, Int)? {
    for (w, ws) in workspaces.enumerated() {
      if let t = ws.tabs.firstIndex(where: { $0.id == tab }) { return (w, t) }
    }
    return nil
  }

  private func locate(pane: PaneID) -> (Int, Int)? {
    for (w, ws) in workspaces.enumerated() {
      if let t = ws.tabIndex(containing: pane) { return (w, t) }
    }
    return nil
  }

  /// A pane of the attached workspace.
  private func attachedRuntime(_ pane: PaneID) -> PaneRuntime? {
    guard let lease, let record = panes[pane],
      record.workspace == lease.workspace, !record.detachedFromLayout
    else { return nil }
    return record.runtime
  }

  private func snapshot(_ ws: Workspace) -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      id: ws.id,
      name: ws.name,
      tabs: ws.tabs.map(\.snapshot),
      activeTab: ws.activeTab,
      panes: ws.allPanes.compactMap { id in panes[id]?.summary(id) },
      layoutRevision: ws.layoutRevision
    )
  }

  private func snapshot(_ id: WorkspaceID) -> WorkspaceSnapshot? {
    workspaces.first { $0.id == id }.map(snapshot)
  }

  /// Commits a validated mutation: new revision, then notify the lease.
  private func commitLayout(_ id: WorkspaceID) {
    guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
    workspaces[i].layoutRevision &+= 1
    if let lease, lease.workspace == id {
      send(.event(.layout(snapshot(workspaces[i]))), to: lease.client)
    }
  }

  // MARK: Pane creation

  private var paneCount: Int { panes.count + pendingLaunches }

  /// Logical history committed to live and starting panes.
  private var allocatedHistoryBytes: Int {
    panes.values.reduce(pendingHistoryBytes) { $0 + $1.runtime.historyBytes }
  }

  /// Up to the per-pane cap from the shared budget, keeping the minimum
  /// back for every pane that may still be created. The sum of shares
  /// never exceeds `totalHistoryBytes`; ended panes return theirs.
  private func nextHistoryShare() -> Int {
    let reserve =
      max(0, limits.maxPanes - paneCount - 1) * limits.minHistoryBytesPerPane
    let available = limits.totalHistoryBytes - allocatedHistoryBytes - reserve
    return min(
      limits.historyBytesPerPane,
      max(limits.minHistoryBytesPerPane, available)
    )
  }

  private func spawnPane(
    workspace: WorkspaceID,
    columns: Int,
    rows: Int,
    launch: LaunchSpec,
    completion:
      @escaping @Sendable (isolated MuxService, Result<PaneID, MuxError>) ->
      Void
  ) {
    guard !quiescing else {
      return completion(
        self,
        .failure(MuxError(.quiescing, "service is preparing to update"))
      )
    }
    guard paneCount < limits.maxPanes else {
      return completion(
        self,
        .failure(
          MuxError(.resourceLimit, "pane limit \(limits.maxPanes) reached")
        )
      )
    }
    let id = PaneID()
    let columns = min(max(columns, 1), limits.maxColumns)
    let rows = min(max(rows, 1), limits.maxRows)
    let historyBytes = nextHistoryShare()
    let runtime = PaneRuntime(
      id: id,
      workspace: workspace,
      columns: columns,
      rows: rows,
      historyBytes: historyBytes,
      limits: limits
    )
    runtime.onChange = { [weak self] in self?.onQueue { $0.paneChanged(id) } }
    runtime.onEvent = { [weak self] event in
      self?.onQueue { $0.paneEvent(id, event) }
    }
    pendingLaunches += 1
    pendingHistoryBytes += historyBytes
    let launcher = self.launcher
    runtime.queue.async { [weak self] in
      let result: Result<Void, MuxError>
      do throws(MuxError) {
        try runtime.launch(launch, launcher: launcher)
        result = .success(())
      } catch { result = .failure(error) }
      self?
        .onQueue { service in
          service.pendingLaunches -= 1
          service.pendingHistoryBytes -= historyBytes
          switch result {
          case .success:
            service.panes[id] = PaneRecord(
              runtime: runtime,
              workspace: workspace,
              columns: columns,
              rows: rows,
              workingDirectory: launch.workingDirectory
            )
            completion(service, .success(id))
            // Creation generation: the target may have ended meanwhile.
            if service.locate(pane: id) == nil {
              service.panes[id]?.detachedFromLayout = true
              runtime.terminate()
            }
          case let .failure(error):
            completion(service, .failure(error))
            service.checkIdle()
          }
        }
    }
  }

  private func newWorkspace(
    _ request: NewWorkspaceRequest,
    reply: @escaping Reply
  ) {
    if let name = request.name, !validName(name) {
      return reply(.failure(MuxError(.invalidRequest, "workspace name")))
    }
    if let name = request.name, workspaces.contains(where: { $0.name == name })
    {
      return reply(
        .failure(MuxError(.invalidRequest, "workspace \"\(name)\" exists"))
      )
    }
    let wsID = WorkspaceID()
    spawnPane(
      workspace: wsID,
      columns: request.columns,
      rows: request.rows,
      launch: request.launch
    ) { service, result in
      switch result {
      case let .failure(error): reply(.failure(error))
      case let .success(pane):
        let tab = Tab(name: "1", layout: .pane(pane), activePane: pane)
        var name = request.name ?? "\(service.workspaces.count)"
        var n = service.workspaces.count
        while service.workspaces.contains(where: { $0.name == name }) {
          n += 1
          name = "\(n)"
        }
        let ws = Workspace(
          id: wsID,
          name: name,
          tabs: [tab],
          activeTab: tab.id,
          remainOnExit: request.remainOnExit,
          launch: request.launch
        )
        service.workspaces.append(ws)
        reply(.success(.created(service.snapshot(ws))))
      }
    }
  }

  private func newTab(
    name: String?,
    launch: LaunchSpec?,
    reply: @escaping Reply
  ) {
    guard let lease,
      let w = workspaces.firstIndex(where: { $0.id == lease.workspace })
    else { return reply(.failure(MuxError(.notAttached))) }
    let ws = workspaces[w]
    let reference = ws.tabs.first { $0.id == ws.activeTab }
      .flatMap { panes[$0.activePane] }
    spawnPane(
      workspace: ws.id,
      columns: reference?.columns ?? 80,
      rows: reference?.rows ?? 24,
      launch: launch ?? ws.launch
    ) { service, result in
      switch result {
      case let .failure(error): reply(.failure(error))
      case let .success(pane):
        guard let w = service.workspaces.firstIndex(where: { $0.id == ws.id })
        else { return reply(.failure(MuxError(.notFound, "workspace ended"))) }
        let tab = Tab(
          name: name ?? "\(service.workspaces[w].tabs.count + 1)",
          layout: .pane(pane),
          activePane: pane
        )
        service.workspaces[w].tabs.append(tab)
        service.workspaces[w].activeTab = tab.id
        service.commitLayout(ws.id)
        reply(.success(.layout(service.snapshot(service.workspaces[w]))))
      }
    }
  }

  private func split(
    _ pane: PaneID,
    axis: SplitAxis,
    launch: LaunchSpec?,
    reply: @escaping Reply
  ) {
    guard let (w, _) = locate(pane: pane), let record = panes[pane],
      workspaces[w].id == lease?.workspace
    else { return reply(.failure(MuxError(.notFound, "pane"))) }
    let ws = workspaces[w]
    let columns =
      axis == .leftRight ? max(1, (record.columns - 1) / 2) : record.columns
    let rows = axis == .topBottom ? max(1, (record.rows - 1) / 2) : record.rows
    guard columns >= limits.minPaneColumns || axis == .topBottom,
      rows >= limits.minPaneRows || axis == .leftRight
    else {
      return reply(
        .failure(MuxError(.resourceLimit, "pane too small to split"))
      )
    }
    spawnPane(
      workspace: ws.id,
      columns: columns,
      rows: rows,
      launch: launch
        ?? LaunchSpec(
          command: ws.launch.command == nil ? nil : nil,
          workingDirectory: record.workingDirectory
            ?? ws.launch.workingDirectory,
          environment: ws.launch.environment
        )
    ) { service, result in
      switch result {
      case let .failure(error): reply(.failure(error))
      case let .success(newPane):
        guard let (w, t) = service.locate(pane: pane) else {
          return reply(.failure(MuxError(.notFound, "pane ended")))
        }
        service.workspaces[w].tabs[t].layout = service.workspaces[w].tabs[t]
          .layout.splitting(pane, axis: axis, newPane: newPane)
        service.workspaces[w].tabs[t].activePane = newPane
        service.workspaces[w].tabs[t].zoomedPane = nil
        service.commitLayout(ws.id)
        reply(.success(.layout(service.snapshot(service.workspaces[w]))))
      }
    }
  }

  // MARK: Pane removal

  /// Removes `pane` from its layout and terminates only its processes.
  private func endPane(_ pane: PaneID) {
    removeFromLayout(pane)
    panes[pane]?.detachedFromLayout = true
    if let record = panes[pane] {
      if record.exitStatus != nil {
        panes.removeValue(forKey: pane)
      } else {
        record.runtime.terminate()
      }
    }
    checkIdle()
  }

  private func endWorkspace(_ id: WorkspaceID) {
    guard let ws = workspaces.first(where: { $0.id == id }) else { return }
    for pane in ws.allPanes { endPane(pane) }
    // endPane removes the workspace with its last pane.
    workspaces.removeAll { $0.id == id }
    if lease?.workspace == id {
      releaseLease(notify: true, reason: "workspace ended")
    }
  }

  private func removeFromLayout(_ pane: PaneID) {
    guard let (w, t) = locate(pane: pane) else { return }
    let wsID = workspaces[w].id
    lease?.subscriptions.removeAll { $0 == pane }
    if let slot = lease?.frames.removeValue(forKey: pane),
      let inflight = slot.inflight
    {
      inflightFrameBytes -= inflight.bytes
    }
    if let pasteIDs = lease?.pastes.filter({ $0.value.pane == pane }).map(\.key)
    {
      for id in pasteIDs { lease?.pastes.removeValue(forKey: id) }
    }
    guard let layout = workspaces[w].tabs[t].layout.removing(pane) else {
      // Last pane of the tab.
      let tabID = workspaces[w].tabs[t].id
      workspaces[w].tabs.remove(at: t)
      if workspaces[w].tabs.isEmpty {
        workspaces.remove(at: w)
        if lease?.workspace == wsID {
          releaseLease(notify: true, reason: "workspace ended")
        }
        return
      }
      if workspaces[w].activeTab == tabID {
        workspaces[w].activeTab =
          workspaces[w].tabs[min(t, workspaces[w].tabs.count - 1)].id
      }
      commitLayout(wsID)
      return
    }
    workspaces[w].tabs[t].layout = layout
    if workspaces[w].tabs[t].activePane == pane {
      workspaces[w].tabs[t].activePane = layout.panes.first!
    }
    if workspaces[w].tabs[t].zoomedPane == pane {
      workspaces[w].tabs[t].zoomedPane = nil
    }
    commitLayout(wsID)
  }

  // MARK: Pane events

  private func paneChanged(_ id: PaneID) {
    guard let record = panes[id] else { return }
    record.runtime.changePosted.store(false, ordering: .releasing)
    guard lease?.frames[id] != nil else { return }
    lease?.frames[id]?.dirty = true
    pump()
  }

  private func paneEvent(_ id: PaneID, _ event: PaneEvent) {
    guard panes[id] != nil else { return }
    let client = lease.flatMap { l in
      panes[id]?.workspace == l.workspace ? l.client : nil
    }
    switch event {
    case let .title(title):
      panes[id]?.title = title
      if let client { send(.event(.title(id, title)), to: client) }
    case .bell: if let client { send(.event(.bell(id)), to: client) }
    case let .workingDirectory(dir): panes[id]?.workingDirectory = dir
    case let .finished(status, forced):
      if forced {
        log.notice(
          "pane \(id.short) terminated forcibly; output may be truncated"
        )
      }
      panes[id]?.exitStatus = status
      if let client {
        send(.event(.paneExited(id, status: status)), to: client)
      }
      let record = panes[id]!
      if record.detachedFromLayout {
        panes.removeValue(forKey: id)
      } else if let ws = workspaces.first(where: { $0.id == record.workspace }),
        ws.remainOnExit
      {
        commitLayout(ws.id)
      } else {
        removeFromLayout(id)
        panes.removeValue(forKey: id)
      }
      checkIdle()
    }
  }

  // MARK: Geometry and subscriptions

  private func setGeometry(_ batch: GeometryBatch) -> MuxError? {
    guard var current = lease,
      let ws = workspaces.first(where: { $0.id == current.workspace })
    else { return MuxError(.notAttached) }
    guard batch.layoutRevision == ws.layoutRevision else {
      return MuxError(
        .staleGeometry,
        "layout revision \(batch.layoutRevision) is not current (\(ws.layoutRevision))"
      )
    }
    guard batch.generation > current.geometryGeneration else {
      return MuxError(.staleGeometry, "geometry generation did not advance")
    }
    guard batch.entries.count <= limits.maxGeometryBatch else {
      return MuxError(.resourceLimit, "geometry batch size")
    }
    let members = Set(ws.allPanes)
    for e in batch.entries {
      guard members.contains(e.pane) else {
        return MuxError(
          .staleGeometry,
          "pane \(e.pane.short) is not in this workspace"
        )
      }
      guard limits.cellCount(columns: e.columns, rows: e.rows) != nil else {
        return MuxError(.invalidRequest, "pane size \(e.columns)x\(e.rows)")
      }
    }
    current.geometryGeneration = batch.generation
    lease = current
    for e in batch.entries {
      guard let record = panes[e.pane] else { continue }
      panes[e.pane]?.columns = e.columns
      panes[e.pane]?.rows = e.rows
      record.runtime.resize(
        columns: e.columns,
        rows: e.rows,
        generation: batch.generation
      )
    }
    return nil
  }

  private func setSubscriptions(_ list: [PaneID]) -> MuxError? {
    guard let current = lease,
      let ws = workspaces.first(where: { $0.id == current.workspace })
    else { return MuxError(.notAttached) }
    let members = Set(ws.allPanes)
    guard list.count <= limits.maxPanes, Set(list).count == list.count,
      list.allSatisfy(members.contains)
    else { return MuxError(.invalidRequest, "subscription list") }
    var frames: [PaneID: FrameSlot] = [:]
    for pane in list {
      // Keep in-flight state; a new subscription forces a full frame.
      frames[pane] = current.frames[pane] ?? FrameSlot()
    }
    for (pane, slot) in current.frames where frames[pane] == nil {
      if let inflight = slot.inflight { inflightFrameBytes -= inflight.bytes }
    }
    lease?.subscriptions = list
    lease?.frames = frames
    pump()
    return nil
  }

  // MARK: Frames

  private func pump() {
    guard let current = lease, !current.subscriptions.isEmpty else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    let interval = limits.frameIntervalNanoseconds
    var wake: UInt64?
    let order = current.subscriptions
    let n = order.count
    pumpCursor = (pumpCursor + 1) % max(1, n)
    for k in 0 ..< n {
      let pane = order[(pumpCursor + k) % n]
      guard let slot = current.frames[pane], slot.dirty, !slot.capturing,
        slot.inflight == nil, let record = panes[pane]
      else { continue }
      if now &- slot.lastSent < interval, slot.lastSent != 0 {
        let due = slot.lastSent + interval
        wake = min(wake ?? due, due)
        continue
      }
      guard inflightFrameBytes < limits.pendingFrameBudget else { break }
      lease?.frames[pane]?.dirty = false
      lease?.frames[pane]?.capturing = true
      let attachment = current.attachment
      let layoutRevision =
        workspaces.first { $0.id == current.workspace }?.layoutRevision ?? 0
      record.runtime.captureFrame(
        server: instance,
        attachment: attachment,
        layoutRevision: layoutRevision
      ) { [weak self] result in
        self?.onQueue { $0.frameCaptured(pane, attachment: attachment, result) }
      }
    }
    if let wake, !pumpScheduled {
      pumpScheduled = true
      queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: wake)) {
        [weak self] in
        self?
          .assumeIsolated {
            $0.pumpScheduled = false
            $0.pump()
          }
      }
    }
  }

  private func frameCaptured(
    _ pane: PaneID,
    attachment: AttachmentID,
    _ result: Result<(Data, UInt64), MuxError>
  ) {
    guard let current = lease, current.attachment == attachment,
      current.frames[pane] != nil
    else { return }
    lease?.frames[pane]?.capturing = false
    switch result {
    case let .success((data, revision)):
      guard let client = clients[current.client] else { return }
      client.channel.send(data)
      lease?.frames[pane]?.inflight = (revision, data.count)
      lease?.frames[pane]?.lastSent = DispatchTime.now().uptimeNanoseconds
      inflightFrameBytes += data.count
    case let .failure(error):
      // Preserve the session; report instead of omitting cells.
      send(.event(.frameUnavailable(pane, error)), to: current.client)
    }
    pump()
  }

  private func frameAck(_ pane: PaneID, _ revision: UInt64, from id: UUID) {
    guard lease?.client == id, let slot = lease?.frames[pane],
      let inflight = slot.inflight, inflight.revision == revision
    else { return }
    lease?.frames[pane]?.inflight = nil
    inflightFrameBytes -= inflight.bytes
    pump()
  }

  // MARK: Input

  private func input(_ record: InputRecord, from id: UUID) {
    let ack = { (error: MuxError?) in
      self.send(.inputAck(sequence: record.sequence, error: error), to: id)
    }
    guard let current = lease, current.client == id else {
      return ack(MuxError(.notAttached))
    }
    guard record.attachment == current.attachment else {
      return ack(MuxError(.staleAttachment, "attachment is no longer current"))
    }
    guard let pane = panes[record.pane], pane.workspace == current.workspace,
      !pane.detachedFromLayout
    else { return ack(MuxError(.notFound, "pane")) }
    guard pane.exitStatus == nil else { return ack(MuxError(.paneExited)) }
    let runtime = pane.runtime
    switch record.payload {
    case let .input(input):
      if case let .text(s) = input, s.utf8.count > limits.maxPasteChunkBytes {
        return ack(MuxError(.resourceLimit, "text input record too large"))
      }
      let estimate = Self.estimate(input)
      guard runtime.reserve(estimate) else {
        return ack(MuxError(.resourceLimit, "pane input buffer is full"))
      }
      runtime.write(input, estimate: estimate)
      ack(nil)
    case let .pasteBegin(pasteID):
      guard current.pastes[pasteID] == nil,
        !current.pastes.values.contains(where: { $0.pane == record.pane })
      else { return ack(MuxError(.invalidRequest, "paste already active")) }
      lease?.pastes[pasteID] = ActivePaste(pane: record.pane)
      runtime.pasteBegin(id: pasteID)
      ack(nil)
    case let .pasteChunk(pasteID, text):
      guard let paste = current.pastes[pasteID], paste.pane == record.pane
      else { return ack(MuxError(.invalidRequest, "unknown paste")) }
      let n = text.utf8.count
      guard n <= limits.maxPasteChunkBytes,
        paste.bytes + n <= limits.maxPasteBytes
      else {
        cancelPaste(pasteID, notify: id)
        return ack(
          MuxError(
            .resourceLimit,
            "paste exceeds \(limits.maxPasteBytes) bytes"
          )
        )
      }
      let estimate = n + text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
      guard runtime.reserve(estimate) else {
        return ack(MuxError(.resourceLimit, "pane input buffer is full"))
      }
      lease?.pastes[pasteID]?.bytes += n
      runtime.pasteChunk(id: pasteID, text: text, estimate: estimate)
      ack(nil)
    case let .pasteEnd(pasteID):
      guard current.pastes[pasteID] != nil else {
        return ack(MuxError(.invalidRequest, "unknown paste"))
      }
      lease?.pastes.removeValue(forKey: pasteID)
      runtime.pasteEnd(id: pasteID)
      ack(nil)
      send(.event(.paste(id: pasteID, state: .completed)), to: id)
    }
  }

  static func estimate(_ input: MuxInput) -> Int {
    switch input {
    case let .text(s): s.utf8.count
    case .key: 32
    case .focus: 3
    }
  }

  private func cancelPaste(_ pasteID: UInt64, notify client: UUID?) {
    guard let paste = lease?.pastes.removeValue(forKey: pasteID),
      let runtime = panes[paste.pane]?.runtime
    else { return }
    runtime.pasteCancel(id: pasteID) { [weak self] discarded in
      guard let client else { return }
      self?
        .onQueue {
          $0.send(
            .event(.paste(id: pasteID, state: discarded ? .partial : .aborted)),
            to: client
          )
        }
    }
  }

  private func cancelPastes() {
    for id in lease?.pastes.keys.map({ $0 }) ?? [] {
      cancelPaste(id, notify: nil)
    }
  }

  // MARK: Lease and lifetime

  private func releaseLease(notify: Bool, reason: String) {
    guard let current = lease else { return }
    // Cancellation cleanup is queued on each pane ahead of any later input.
    cancelPastes()
    if let ws = workspaces.first(where: { $0.id == current.workspace }) {
      for pane in ws.allPanes { panes[pane]?.runtime.resetViewport() }
    }
    for slot in current.frames.values {
      if let inflight = slot.inflight { inflightFrameBytes -= inflight.bytes }
    }
    lease = nil
    if notify { send(.event(.detached(reason: reason)), to: current.client) }
    checkIdle()
  }

  /// The ordered empty-state barrier: no workspaces, retained screens,
  /// attachment, pending launches or teardowns, and no connections.
  public var isEmpty: Bool {
    workspaces.isEmpty && panes.isEmpty && pendingLaunches == 0 && lease == nil
  }

  private func checkIdle() {
    idleWork?.cancel()
    idleWork = nil
    guard let delay = configuration.idleExitDelay, let onIdle, isEmpty,
      clients.isEmpty
    else { return }
    let work = DispatchWorkItem { [weak self] in
      self?
        .assumeIsolated { service in
          guard service.isEmpty, service.clients.isEmpty else { return }
          onIdle()
        }
    }
    idleWork = work
    queue.asyncAfter(deadline: .now() + delay, execute: work)
  }

  // MARK: Diagnostics

  /// Visible text of a pane (tests).
  public func screenLines(_ pane: PaneID) -> [String]? {
    panes[pane]?.runtime.screenLines()
  }

  /// A pane's history share and the service total (tests, diagnostics).
  public func historyBudget(_ pane: PaneID) -> (pane: Int, total: Int)? {
    panes[pane].map { ($0.runtime.historyBytes, allocatedHistoryBytes) }
  }

  public func panePID(_ pane: PaneID) -> Int32? {
    panes[pane].map { $0.runtime.pid }
  }
}
