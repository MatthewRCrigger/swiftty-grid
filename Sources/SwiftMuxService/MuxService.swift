import Darwin
import Dispatch
import Foundation
import MuxAttention
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
  /// Runs on the pane queue before each launch (tests hold a launch open).
  package var beforeLaunch: (@Sendable () -> Void)?

  public init(launcherPath: String) { self.launcherPath = launcherPath }
}

/// The persistent session service: workspace graph, stable identities,
/// one interactive lease per workspace, layout revisions and frame
/// delivery.
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

  var workspaces: [Workspace] = []
  var panes: [PaneID: PaneRecord] = [:]
  private var clients: [UUID: Client] = [:]
  /// At most one lease per workspace and per client.
  var leases: [WorkspaceID: Lease] = [:]
  private var clientLeases: [UUID: WorkspaceID] = [:]
  /// Last granted lease generation per workspace; `takeover` names it.
  private var leaseGenerations: [WorkspaceID: UInt64] = [:]
  var pendingLaunches = 0
  var pendingHistoryBytes = 0
  /// Latest frontend theme, applied to every pane and to new ones.
  var theme: MuxTheme?
  var quiescing = false
  /// Advances on every `endAllWorkspaces`; a launch begun before one
  /// never joins the graph.
  var endAllEpoch: UInt64 = 0
  /// Frame bytes sent and not yet acknowledged.
  private var inflightFrameBytes = 0
  /// Estimates held by captures in progress, so concurrent captures
  /// cannot overrun `pendingFrameBudget` together.
  private var reservedFrameBytes = 0
  private var pumpScheduled = false
  /// Leases in grant order; `pump` rotates through them.
  private var leaseOrder: [WorkspaceID] = []
  private var workspaceCursor = 0
  private var nextCapture: UInt64 = 0
  private var idleWork: DispatchWorkItem?
  private var listeners: [SMXListener] = []
  /// Called once the empty-state barrier holds for `idleExitDelay`.
  private var onIdle: (@Sendable () -> Void)?
  /// OSC 7501 attention inbox (spec.inbox.md §3).
  private var attention: InboxHub

  var limits: MuxLimits { configuration.limits }

  public init(configuration: MuxServiceConfiguration) {
    self.configuration = configuration
    queue = DispatchSerialQueue(label: "swiftmux.service", qos: .userInitiated)
    attention = InboxHub(serviceEpoch: instance, limits: configuration.limits)
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

  nonisolated func onQueue(
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
    register(client)
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

  func register(_ client: Client) {
    clients[client.id] = client
    idleWork?.cancel()
  }

  func disconnected(_ id: UUID, reason: String) {
    guard clients.removeValue(forKey: id) != nil else { return }
    _ = attention.subscribe(id, false)
    if let ws = clientLeases[id] {
      // Connection loss: cancel remaining input, release the lease.
      releaseLease(ws, notify: false, reason: "connection lost: \(reason)")
    }
    checkIdle()
  }

  private func send(_ message: ServerMessage, to id: UUID) {
    guard let client = clients[id] else { return }
    switch client.transport {
    case let .xpc(channel):
      do {
        channel.send(
          try SMXCodec.encode(
            message,
            limit: SMXCodec.serverRecordLimit(limits)
          )
        )
      } catch { log.error("encode failed: \(error.description)") }
    case let .local(sink): sink.onMessage(message)
    }
  }

  private func receive(_ data: Data, from id: UUID) {
    guard clients[id] != nil else { return }
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
    receive(message, from: id)
  }

  func receive(_ message: ClientMessage, from id: UUID) {
    guard let client = clients[id] else { return }
    guard let hello = client.hello else {
      guard case let .hello(hello) = message else {
        send(.rejected(MuxError(.invalidRequest, "expected hello")), to: id)
        client.cancel()
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
    case .inboxAck: inboxAcknowledged(by: id)
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
      client.cancel()
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
      client.cancel()
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

  typealias Reply = @Sendable (MuxResult) -> Void

  private func handle(
    _ command: MuxCommand,
    from client: Client,
    hello: Hello,
    reply: @escaping Reply
  ) {
    let fail = { (e: MuxError) in reply(.failure(e)) }
    if let refusal = admission(of: command, from: client) {
      return fail(refusal)
    }
    do throws(MuxError) {
      try dispatch(command, from: client, hello: hello, reply: reply)
    } catch { fail(error) }
  }

  /// `handle` after admission; a thrown error is the reply.
  private func dispatch(
    _ command: MuxCommand,
    from client: Client,
    hello: Hello,
    reply: @escaping Reply
  ) throws(MuxError) {
    let ok = { reply(.success(.ok)) }
    let fail = { (e: MuxError) in reply(.failure(e)) }
    switch command {
    case .status: reply(.success(.status(status)))
    case .listWorkspaces: reply(.success(.workspaces(summaries)))
    case let .newWorkspace(request): newWorkspace(request, reply: reply)
    case let .endWorkspace(selector):
      let ws = try workspace(selector)
      endWorkspace(ws.id)
      ok()
    case let .renameWorkspace(selector, name):
      let i = try workspaceIndex(selector)
      guard validName(name) else {
        return fail(MuxError(.invalidRequest, "name"))
      }
      // Names select workspaces, so they stay unique (as on creation).
      guard
        !workspaces.contains(where: {
          $0.id != workspaces[i].id && $0.name == name
        })
      else {
        return fail(MuxError(.invalidRequest, "workspace \"\(name)\" exists"))
      }
      workspaces[i].name = name
      commitLayout(workspaces[i].id)
      ok()
    case .detachActive:
      // Update barrier and `swmux detach`: every holder is told.
      for ws in Array(leases.keys) {
        releaseLease(ws, notify: true, reason: "detached by request")
      }
      ok()
    case .endAllWorkspaces:
      quiescing = true
      endAllEpoch &+= 1
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
      guard clientLeases[client.id] == nil else {
        return fail(MuxError(.alreadyAttached, "this connection is attached"))
      }
      let ws = try workspace(selector)
      guard leases[ws.id] == nil else {
        return fail(
          MuxError(.leaseHeld, "another frontend controls this workspace")
        )
      }
      reply(.success(grantLease(ws, to: client, hello: hello)))
    case let .takeover(selector, expected):
      guard hello.frontend != .control else {
        return fail(
          MuxError(.invalidRequest, "control connections cannot attach")
        )
      }
      guard !quiescing else {
        return fail(MuxError(.quiescing, "service is preparing to update"))
      }
      let ws = try workspace(selector)
      // Names the lease the user agreed to displace; a newer holder
      // (or none) means the prompt is stale.
      guard expected == leaseGenerations[ws.id, default: 0] else {
        return fail(
          MuxError(.staleRevision, "the workspace's controller changed")
        )
      }
      if let held = clientLeases[client.id] {
        releaseLease(held, notify: false, reason: "took over another workspace")
      }
      if leases[ws.id] != nil {
        // Fence the old holder: its pastes close and its attachment ID
        // stops admitting input before the new lease exists.
        releaseLease(
          ws.id,
          notify: true,
          reason: "another frontend took control"
        )
      }
      reply(.success(grantLease(ws, to: client, hello: hello)))
    case .detach:
      if let ws = clientLeases[client.id] {
        releaseLease(ws, notify: false, reason: "detached")
      }
      ok()
    case let .switchWorkspace(selector):
      try switchWorkspace(selector, client: client, reply: reply)
    case let .observeWorkspaces(on):
      client.observesWorkspaces = on
      reply(.success(.workspaces(summaries)))
    case let .quiesce(on):
      quiescing = on
      ok()
    case let .setTheme(theme):
      guard theme.isValid else {
        return fail(MuxError(.invalidRequest, "theme"))
      }
      self.theme = theme
      for record in panes.values { record.runtime.setTheme(theme) }
      ok()
    case .subscribeInbox, .inbox, .locateAttention, .markSeen, .snooze,
      .markReviewed:
      handleAttention(command, client: client, reply: reply)
    default:
      guard let ws = clientLeases[client.id] else {
        return fail(MuxError(.notAttached))
      }
      handleLeased(command, workspace: ws, client: client.id, reply: reply)
    }
  }

  private func switchWorkspace(
    _ selector: WorkspaceSelector,
    client: Client,
    reply: @escaping Reply
  ) throws(MuxError) {
    let fail = { (error: MuxError) in reply(.failure(error)) }
    guard let from = clientLeases[client.id] else {
      return fail(MuxError(.notAttached))
    }
    let ws = try workspace(selector)
    guard ws.id == from || leases[ws.id] == nil else {
      return fail(
        MuxError(.leaseHeld, "another frontend controls this workspace")
      )
    }
    cancelPastes(from)
    _ = setSubscriptions([], client: client.id)
    if ws.id != from, var moved = leases.removeValue(forKey: from) {
      // Leaving returns the old workspace to live output, as a release
      // does: no scrollback position or search outlives the lease.
      resetViewports(from)
      leaseGenerations[ws.id, default: 0] &+= 1
      moved.workspace = ws.id
      moved.generation = leaseGenerations[ws.id, default: 0]
      moved.reportedActivity = []
      leases[ws.id] = moved
      if let i = leaseOrder.firstIndex(of: from) { leaseOrder[i] = ws.id }
      clientLeases[client.id] = ws.id
      publishWorkspaces()
    }
    reply(.success(.layout(snapshot(ws))))
  }

  /// Lease and snapshot at one ordering point; frames follow on
  /// subscription.
  private func grantLease(
    _ ws: Workspace,
    to client: Client,
    hello: Hello
  ) -> MuxReply {
    leaseGenerations[ws.id, default: 0] &+= 1
    let lease = Lease(
      client: client.id,
      workspace: ws.id,
      generation: leaseGenerations[ws.id, default: 0],
      holder: LeaseHolder(
        transport: client.remote ? .remote : .local,
        frontend: hello.frontend,
        since: Date()
      )
    )
    leases[ws.id] = lease
    leaseOrder.append(ws.id)
    clientLeases[client.id] = ws.id
    idleWork?.cancel()
    publishWorkspaces()
    return .attached(attachment: lease.attachment, workspace: snapshot(ws))
  }

  /// OSC 7501 inbox commands: metadata only. They never take a lease,
  /// resize a pane or subscribe frames.
  private func handleAttention(
    _ command: MuxCommand,
    client: Client,
    reply: @escaping Reply
  ) {
    do throws(MuxError) {
      switch command {
      case let .subscribeInbox(on):
        guard attention.subscribe(client.id, on) else {
          throw MuxError(
            .resourceLimit,
            "inbox subscriber limit \(limits.inboxSubscribers) reached"
          )
        }
        client.subscribesInbox = on
        reply(.success(.inbox(try attention.page(InboxQuery()))))
      case let .inbox(query): reply(.success(.inbox(try attention.page(query))))
      case let .locateAttention(ref):
        reply(
          .success(
            .attention(location(attention.inbox.lookup(ref), for: client))
          )
        )
      case let .markSeen(ref):
        let lookup = attention.markSeen(ref)
        reply(.success(.attention(location(lookup, for: client))))
      case let .snooze(ref, until):
        let lookup = attention.snooze(ref, until: until)
        reply(.success(.attention(location(lookup, for: client))))
      case let .markReviewed(ref):
        let lookup = try attention.markReviewed(ref)
        reply(.success(.attention(location(lookup, for: client))))
      default: throw MuxError(.invalidRequest, "not an inbox command")
      }
    } catch { reply(.failure(error)) }
    attentionChanged()
  }

  /// Where an occurrence lives now. The lease is reported, never taken.
  private func location(
    _ lookup: AttentionLookup,
    for client: Client
  ) -> AttentionLocation {
    guard let item = lookup.item else {
      return AttentionLocation(availability: .missing)
    }
    let pane = item.source.pane
    var availability = lookup.availability
    if availability == .available, panes[pane]?.exitStatus != nil {
      availability = .paneExited
    }
    let placed = locate(pane: pane)
    let workspace = placed.map { workspaces[$0.0].id } ?? item.workspace
    let holder = leases[workspace]?.client
    return AttentionLocation(
      availability: availability,
      item: item,
      workspace: workspace,
      tab: placed.map { workspaces[$0.0].tabs[$0.1].id } ?? item.tab,
      pane: pane,
      leaseHeldElsewhere: holder != nil && holder != client.id
    )
  }

  /// After any reduction or acknowledgement: schedule the coalesced
  /// flush and the next snooze expiry.
  private func attentionChanged() {
    if attention.inbox.hasPendingUpdate, !attention.flushScheduled {
      attention.flushScheduled = true
      queue.asyncAfter(deadline: .now() + InboxHub.flushDelay) { [weak self] in
        self?.assumeIsolated { $0.flushInbox() }
      }
    }
    let expiry = attention.inbox.nextSnoozeExpiry
    guard let expiry, expiry != attention.snoozeDeadline else { return }
    attention.snoozeDeadline = expiry
    let delay = max(0, expiry.timeIntervalSinceNow)
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      self?
        .assumeIsolated { service in
          guard service.attention.snoozeDeadline == expiry else { return }
          service.attention.snoozeDeadline = nil
          service.attention.expireSnoozes()
          service.attentionChanged()
        }
    }
  }

  private func flushInbox() {
    for (client, update) in attention.flush() {
      send(.event(.inbox(update)), to: client)
    }
  }

  private func inboxAcknowledged(by client: UUID) {
    if let resync = attention.acknowledge(client) {
      send(.event(.inbox(resync)), to: client)
    }
  }

  /// Sends the workspace list to metadata observers.
  func publishWorkspaces() {
    let observers = clients.values.filter(\.observesWorkspaces)
    guard !observers.isEmpty else { return }
    let list = summaries
    for client in observers { send(.event(.workspaces(list)), to: client.id) }
  }

  /// Commands acting on the attached workspace (lease already checked).
  private func handleLeased(
    _ command: MuxCommand,
    workspace leased: WorkspaceID,
    client: UUID,
    reply: @escaping Reply
  ) {
    let ok = { reply(.success(.ok)) }
    let fail = { (e: MuxError) in reply(.failure(e)) }
    switch command {
    case let .newTab(name, launch):
      newTab(name: name, launch: launch, in: leased, reply: reply)
    case let .selectTab(tab):
      guard let (w, t) = locate(tab: tab, in: leased) else {
        return fail(MuxError(.notFound, "tab"))
      }
      workspaces[w].activeTab = workspaces[w].tabs[t].id
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .renameTab(tab, name):
      guard let (w, t) = locate(tab: tab, in: leased) else {
        return fail(MuxError(.notFound, "tab"))
      }
      guard validName(name) else {
        return fail(MuxError(.invalidRequest, "name"))
      }
      workspaces[w].tabs[t].name = name
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .endTab(tab):
      guard let (w, t) = locate(tab: tab, in: leased) else {
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
      split(pane, axis: axis, launch: launch, in: leased, reply: reply)
    case let .focusPane(pane):
      guard let (w, t) = locate(pane: pane, in: leased) else {
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
      guard let (w, t) = locate(tab: tab, in: leased) else {
        return fail(MuxError(.notFound, "tab"))
      }
      let current = workspaces[w].tabs[t]
      workspaces[w].tabs[t].zoomedPane =
        current.zoomedPane == nil && current.layout.panes.count > 1
        ? current.activePane : nil
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .setSplitRatio(tab, path, ratio):
      guard let (w, t) = locate(tab: tab, in: leased) else {
        return fail(MuxError(.notFound, "tab"))
      }
      guard ratio.isFinite, ratio > 0.02, ratio < 0.98,
        let layout = workspaces[w].tabs[t].layout.settingRatio(ratio, at: path)
      else { return fail(MuxError(.invalidRequest, "split ratio")) }
      workspaces[w].tabs[t].layout = layout
      commitLayout(workspaces[w].id)
      reply(.success(.layout(snapshot(workspaces[w]))))
    case let .endPane(pane):
      guard panes[pane]?.workspace == leased,
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
      if let error = setGeometry(batch, workspace: leased) {
        fail(error)
      } else {
        ok()
      }
    case let .setSubscriptions(list):
      if let error = setSubscriptions(list, client: client) {
        fail(error)
      } else {
        ok()
      }
    case let .scroll(pane, request):
      guard validScroll(request) else {
        return fail(MuxError(.invalidRequest, "scroll distance"))
      }
      guard let runtime = attachedRuntime(pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.scroll(request) { error in
        reply(error.map { .failure($0) } ?? .success(.ok))
      }
    case let .search(pane, query):
      search(query, pane: pane, workspace: leased, reply: reply)
    case let .searchStep(pane, forward):
      guard let runtime = attachedRuntime(pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.search(nil, step: forward) { reply(.success(.search($0))) }
    case let .endSearch(pane):
      guard let runtime = attachedRuntime(pane, in: leased) else {
        return fail(MuxError(.notFound, "pane"))
      }
      runtime.search(nil, step: nil) { reply(.success(.search($0))) }
    case .status, .listWorkspaces, .newWorkspace, .endWorkspace,
      .renameWorkspace, .detachActive, .endAllWorkspaces, .attach, .detach,
      .switchWorkspace, .quiesce, .setTheme, .takeover, .observeWorkspaces,
      .subscribeInbox, .inbox, .locateAttention, .markSeen, .snooze,
      .markReviewed:
      ok()  // handled by `handle`
    }
  }

  private func search(
    _ query: String,
    pane: PaneID,
    workspace leased: WorkspaceID,
    reply: @escaping Reply
  ) {
    let fail = { (error: MuxError) in reply(.failure(error)) }
    guard query.utf8.count <= limits.maxSearchBytes, !query.isEmpty else {
      return fail(MuxError(.invalidRequest, "search query"))
    }
    guard let runtime = attachedRuntime(pane, in: leased) else {
      return fail(MuxError(.notFound, "pane"))
    }
    runtime.search(query, step: nil) { reply(.success(.search($0))) }
  }

  /// Lease and update-barrier admission for a command.
  private func admission(
    of command: MuxCommand,
    from client: Client
  ) -> MuxError? {
    if command.requiresLease, clientLeases[client.id] == nil {
      return MuxError(.notAttached, "this connection holds no attachment")
    }
    // At the update barrier only status, ending sessions and leaving are
    // admitted; the workspace graph is otherwise frozen.
    if quiescing, !command.allowedWhileQuiescing {
      return MuxError(.quiescing, "service is preparing to update")
    }
    return nil
  }

  func notFound(_ selector: WorkspaceSelector) -> MuxError {
    switch selector {
    case let .id(id): MuxError(.notFound, "workspace \(id.short)")
    case let .name(n): MuxError(.notFound, "workspace \"\(n)\"")
    case .latest: MuxError(.notFound, "no workspaces")
    }
  }

  /// Relative scrolls never exceed what a pane could hold: history plus
  /// a screen, in lines or (at least one line each) pages.
  private func validScroll(_ request: ScrollRequest) -> Bool {
    let bound = limits.historyRowsPerPane + limits.maxRows
    switch request {
    case let .lines(n), let .pages(n): return (-bound ... bound).contains(n)
    case .bottom, .top: return true
    }
  }

  func validName(_ name: String) -> Bool {
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
      attached: !leases.isEmpty,
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
        isAttached: leases[ws.id] != nil,
        leaseGeneration: leaseGenerations[ws.id, default: 0],
        leaseHolder: leases[ws.id]?.holder,
        livePaneCount: ws.allPanes.filter { panes[$0]?.exitStatus == nil }.count
      )
    }
  }

  /// Shortest ID prefix a name selector may stand for (`WorkspaceID.short`).
  static let minimumIDPrefix = 8

  /// An exact name first; otherwise an unambiguous ID prefix of at least
  /// `minimumIDPrefix` hex digits. Default names are numbers, which are
  /// also hex, so a short or shared prefix never selects anything.
  private func workspaceIndex(
    _ selector: WorkspaceSelector
  ) throws(MuxError) -> Int {
    let found: Int? =
      switch selector {
      case let .id(id): workspaces.firstIndex { $0.id == id }
      case .latest: workspaces.indices.last
      case let .name(name):
        if name.isEmpty {
          nil
        } else if let i = workspaces.firstIndex(where: { $0.name == name }) {
          i
        } else {
          try idPrefixIndex(name)
        }
      }
    guard let found else { throw notFound(selector) }
    return found
  }

  private func idPrefixIndex(_ text: String) throws(MuxError) -> Int? {
    let prefix = text.uppercased()
    let digits = prefix.unicodeScalars.filter { $0 != "-" }
    guard digits.count >= Self.minimumIDPrefix,
      digits.allSatisfy({ $0.properties.isASCIIHexDigit })
    else { return nil }
    let matches = workspaces.indices.filter {
      workspaces[$0].id.description.uppercased().hasPrefix(prefix)
    }
    guard matches.count <= 1 else {
      throw MuxError(
        .invalidRequest,
        "workspace prefix \"\(text)\" is ambiguous (\(matches.count) matches)"
      )
    }
    return matches.first
  }

  func workspace(
    _ selector: WorkspaceSelector
  ) throws(MuxError) -> Workspace {
    workspaces[try workspaceIndex(selector)]
  }

  func locate(tab: TabID) -> (Int, Int)? {
    for (w, ws) in workspaces.enumerated() {
      if let t = ws.tabs.firstIndex(where: { $0.id == tab }) { return (w, t) }
    }
    return nil
  }

  func locate(pane: PaneID) -> (Int, Int)? {
    for (w, ws) in workspaces.enumerated() {
      if let t = ws.tabIndex(containing: pane) { return (w, t) }
    }
    return nil
  }

  /// Restricted to one workspace: a lease never reaches another's tabs.
  func locate(tab: TabID, in workspace: WorkspaceID) -> (Int, Int)? {
    locate(tab: tab).flatMap { workspaces[$0.0].id == workspace ? $0 : nil }
  }

  func locate(pane: PaneID, in workspace: WorkspaceID) -> (Int, Int)? {
    locate(pane: pane).flatMap { workspaces[$0.0].id == workspace ? $0 : nil }
  }

  /// A pane of the attached workspace.
  private func attachedRuntime(
    _ pane: PaneID,
    in workspace: WorkspaceID
  ) -> PaneRuntime? {
    guard let record = panes[pane], record.workspace == workspace,
      !record.detachedFromLayout
    else { return nil }
    return record.runtime
  }

  func snapshot(_ ws: Workspace) -> WorkspaceSnapshot {
    WorkspaceSnapshot(
      id: ws.id,
      name: ws.name,
      tabs: ws.tabs.map(\.snapshot),
      activeTab: ws.activeTab,
      panes: ws.allPanes.compactMap { id in panes[id]?.summary(id) },
      layoutRevision: ws.layoutRevision
    )
  }

  func snapshot(_ id: WorkspaceID) -> WorkspaceSnapshot? {
    workspaces.first { $0.id == id }.map(snapshot)
  }

  /// Commits a validated mutation: new revision, then notify the lease.
  func commitLayout(_ id: WorkspaceID) {
    guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
    workspaces[i].layoutRevision &+= 1
    if let lease = leases[id] {
      send(.event(.layout(snapshot(workspaces[i]))), to: lease.client)
    }
    publishWorkspaces()
  }

  // MARK: Pane events

  /// `reportActivity` is off for a pane's launch, which is not unseen
  /// output in a hidden tab.
  func paneChanged(_ id: PaneID, reportActivity: Bool = true) {
    guard let record = panes[id] else { return }
    record.runtime.changePosted.store(false, ordering: .releasing)
    let wsID = record.workspace
    if let holder = leases[wsID], let sink = clients[holder.client]?.local {
      // The roaming bridge exports its own screens on demand.
      sink.onPaneChanged(id)
      return
    }
    guard leases[wsID]?.frames[id] != nil else {
      // Only panes in other tabs are hidden; the active tab's panes are
      // shown or about to be subscribed.
      if reportActivity, let current = leases[wsID],
        let ws = workspaces.first(where: { $0.id == wsID }),
        let tab = ws.tabIndex(containing: id),
        ws.tabs[tab].id != ws.activeTab, !current.reportedActivity.contains(id)
      {
        leases[wsID]?.reportedActivity.insert(id)
        send(.event(.activity(id)), to: current.client)
      }
      return
    }
    leases[wsID]?.frames[id]?.dirty = true
    pump()
  }

  func paneEvent(_ id: PaneID, _ event: PaneEvent) {
    guard let wsID = panes[id]?.workspace else { return }
    let client = leases[wsID]?.client
    switch event {
    case let .title(title):
      panes[id]?.title = title
      if let client { send(.event(.title(id, title)), to: client) }
    case .bell: if let client { send(.event(.bell(id)), to: client) }
    case let .workingDirectory(dir): panes[id]?.workingDirectory = dir
    case let .status(epoch, changes):
      let tab = locate(pane: id).map { workspaces[$0.0].tabs[$0.1].id }
      attention.apply(
        changes,
        pane: id,
        epoch: epoch,
        context: AttentionContext(workspace: wsID, tab: tab)
      )
      attentionChanged()
    case let .finished(status, forced):
      // The final status was drained ahead of this event.
      attention.paneExited(id)
      attentionChanged()
      if forced {
        log.notice(
          "pane \(id.short) terminated forcibly; output may be truncated"
        )
      }
      panes[id]?.exitStatus = status
      if let client {
        send(
          .event(.paneExited(id, status: status, truncated: forced)),
          to: client
        )
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

  private func setGeometry(
    _ batch: GeometryBatch,
    workspace wsID: WorkspaceID
  ) -> MuxError? {
    guard var current = leases[wsID],
      let ws = workspaces.first(where: { $0.id == wsID })
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
    leases[wsID] = current
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

  private func setSubscriptions(
    _ list: [PaneID],
    client: UUID
  ) -> MuxError? {
    guard let wsID = clientLeases[client], let current = leases[wsID],
      let ws = workspaces.first(where: { $0.id == wsID })
    else { return MuxError(.notAttached) }
    let members = Set(ws.allPanes)
    guard clients[client]?.local == nil || list.isEmpty else {
      return MuxError(.invalidRequest, "in-process clients export screens")
    }
    guard list.count <= limits.maxPanes, Set(list).count == list.count,
      list.allSatisfy(members.contains)
    else { return MuxError(.invalidRequest, "subscription list") }
    var frames: [PaneID: FrameSlot] = [:]
    for pane in list {
      // Keep in-flight state; a new subscription forces a full frame.
      frames[pane] = current.frames[pane] ?? FrameSlot()
    }
    for (pane, slot) in current.frames where frames[pane] == nil {
      releaseBudget(slot)
    }
    leases[wsID]?.subscriptions = list
    leases[wsID]?.frames = frames
    leases[wsID]?.reportedActivity.subtract(list)
    pump()
    return nil
  }

  // MARK: Frames

  private func pump() {
    let now = DispatchTime.now().uptimeNanoseconds
    var wake: UInt64?
    // Rotate which workspace goes first so one cannot starve the others
    // of the shared frame budget: start after the last lease served.
    let n = leaseOrder.count
    let start = n == 0 ? 0 : workspaceCursor % n
    var served: Int?
    for k in 0 ..< n {
      let i = (start + k) % n
      let (due, started) = pump(leaseOrder[i], now: now)
      if started, served == nil { served = i }
      if let due { wake = min(wake ?? due, due) }
    }
    workspaceCursor = n == 0 ? 0 : ((served ?? start) + 1) % n
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

  /// Starts captures for one lease; returns when a throttled pane is due
  /// and whether any capture started.
  private func pump(
    _ wsID: WorkspaceID,
    now: UInt64
  ) -> (due: UInt64?, started: Bool) {
    guard let current = leases[wsID], !current.subscriptions.isEmpty else {
      return (nil, false)
    }
    let interval = limits.frameIntervalNanoseconds
    var wake: UInt64?
    var started = false
    let order = current.subscriptions
    let n = order.count
    let first = current.paneCursor % n
    leases[wsID]?.paneCursor = (first + 1) % n
    for k in 0 ..< n {
      let pane = order[(first + k) % n]
      guard let slot = current.frames[pane], slot.dirty, slot.capture == nil,
        slot.inflight == nil, let record = panes[pane]
      else { continue }
      if now &- slot.lastSent < interval, slot.lastSent != 0 {
        let due = slot.lastSent + interval
        wake = min(wake ?? due, due)
        continue
      }
      guard inflightFrameBytes + reservedFrameBytes < limits.pendingFrameBudget
      else { break }
      nextCapture &+= 1
      let token = nextCapture
      let estimate = captureEstimate(record)
      reservedFrameBytes += estimate
      leases[wsID]?.frames[pane]?.dirty = false
      leases[wsID]?.frames[pane]?.capture = token
      leases[wsID]?.frames[pane]?.reserved = estimate
      started = true
      let attachment = current.attachment
      let layoutRevision =
        workspaces.first { $0.id == wsID }?.layoutRevision ?? 0
      record.runtime.captureFrame(
        server: instance,
        attachment: attachment,
        layoutRevision: layoutRevision
      ) { [weak self] result in
        self?.onQueue {
          $0.frameCaptured(pane, workspace: wsID, token: token, result)
        }
      }
    }
    return (wake, started)
  }

  private func frameCaptured(
    _ pane: PaneID,
    workspace wsID: WorkspaceID,
    token: UInt64,
    _ result: Result<(Data, UInt64), MuxError>
  ) {
    // The token is unique to this slot's capture: a completion for a
    // pane since unsubscribed (or resubscribed), or for another lease,
    // never reaches the client or the frame budget.
    guard let current = leases[wsID], let slot = current.frames[pane],
      slot.capture == token
    else { return }
    leases[wsID]?.frames[pane]?.capture = nil
    leases[wsID]?.frames[pane]?.reserved = 0
    reservedFrameBytes -= slot.reserved
    switch result {
    case let .success((data, revision)):
      guard let client = clients[current.client],
        case let .xpc(channel) = client.transport
      else { return }
      if let stale = slot.inflight { inflightFrameBytes -= stale.bytes }
      channel.send(data)
      leases[wsID]?.frames[pane]?.inflight = (revision, data.count)
      leases[wsID]?.frames[pane]?.lastSent = DispatchTime.now().uptimeNanoseconds
      inflightFrameBytes += data.count
    case let .failure(error):
      // Preserve the session; report instead of omitting cells.
      send(.event(.frameUnavailable(pane, error)), to: current.client)
    }
    pump()
  }

  /// Frame bytes a capture of `record` may produce, held from its start.
  private func captureEstimate(_ record: PaneRecord) -> Int {
    let cells = max(1, record.columns) * max(1, record.rows)
    let (bytes, overflow) = cells.multipliedReportingOverflow(
      by: Self.frameBytesPerCell
    )
    return overflow ? limits.maxFrameBytes : min(bytes, limits.maxFrameBytes)
  }

  /// Rough encoded size of one cell; frames carry per-cell attributes.
  static let frameBytesPerCell = 32

  /// Returns a dropped slot's budget: its unacknowledged frame and the
  /// estimate held by a capture still in progress (whose completion,
  /// carrying a token no slot holds, is then dropped).
  func releaseBudget(_ slot: FrameSlot) {
    if let inflight = slot.inflight { inflightFrameBytes -= inflight.bytes }
    reservedFrameBytes -= slot.reserved
  }

  private func frameAck(_ pane: PaneID, _ revision: UInt64, from id: UUID) {
    guard let wsID = clientLeases[id], let slot = leases[wsID]?.frames[pane],
      let inflight = slot.inflight, inflight.revision == revision
    else { return }
    leases[wsID]?.frames[pane]?.inflight = nil
    inflightFrameBytes -= inflight.bytes
    pump()
  }

  // MARK: Input

  private func input(_ record: InputRecord, from id: UUID) {
    let ack = { (error: MuxError?) in
      self.send(.inputAck(sequence: record.sequence, error: error), to: id)
    }
    guard let wsID = clientLeases[id], let current = leases[wsID] else {
      return ack(MuxError(.notAttached))
    }
    guard record.attachment == current.attachment else {
      return ack(MuxError(.staleAttachment, "attachment is no longer current"))
    }
    // Ledger (spec.inbox.md §1–2): each sequence is answered once and in
    // order. A duplicate was already answered and is never written
    // again; a gap is refused without consuming anything.
    guard record.sequence >= current.nextInput else { return ack(nil) }
    guard record.sequence == current.nextInput else {
      return ack(
        MuxError(.inputGap, "expected input \(current.nextInput)")
      )
    }
    leases[wsID]?.nextInput += 1
    guard let pane = panes[record.pane], pane.workspace == wsID,
      !pane.detachedFromLayout
    else { return ack(MuxError(.notFound, "pane")) }
    guard pane.exitStatus == nil else { return ack(MuxError(.paneExited)) }
    let runtime = pane.runtime
    switch record.payload {
    case let .input(input):
      if case let .text(s) = input, s.utf8.count > limits.maxPasteChunkBytes {
        return ack(MuxError(.resourceLimit, "text input record too large"))
      }
      if case let .paste(s) = input, s.utf8.count > limits.maxPasteChunkBytes {
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
      leases[wsID]?.pastes[pasteID] = ActivePaste(pane: record.pane)
      runtime.pasteBegin(id: pasteID)
      ack(nil)
    case let .pasteChunk(pasteID, text):
      guard let paste = current.pastes[pasteID], paste.pane == record.pane
      else { return ack(MuxError(.invalidRequest, "unknown paste")) }
      let n = text.utf8.count
      guard n <= limits.maxPasteChunkBytes,
        paste.bytes + n <= limits.maxPasteBytes
      else {
        cancelPaste(pasteID, in: wsID, notify: id)
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
      leases[wsID]?.pastes[pasteID]?.bytes += n
      runtime.pasteChunk(id: pasteID, text: text, estimate: estimate)
      ack(nil)
    case let .pasteEnd(pasteID):
      // The paste stays open on a mismatch, so detach still cancels it.
      guard let paste = current.pastes[pasteID], paste.pane == record.pane
      else { return ack(MuxError(.invalidRequest, "unknown paste")) }
      leases[wsID]?.pastes.removeValue(forKey: pasteID)
      runtime.pasteEnd(id: pasteID)
      ack(nil)
      send(.event(.paste(id: pasteID, state: .completed)), to: id)
    case let .pasteCancel(pasteID):
      guard let paste = current.pastes[pasteID], paste.pane == record.pane
      else { return ack(MuxError(.invalidRequest, "unknown paste")) }
      cancelPaste(pasteID, in: wsID, notify: id)
      ack(nil)
    }
  }

  static func estimate(_ input: MuxInput) -> Int {
    switch input {
    case let .text(s): s.utf8.count
    // Brackets plus a carriage return for every newline.
    case let .paste(s):
      s.utf8.count + 12 + s.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
    case .key: 32
    case .focus: 3
    }
  }

  private func cancelPaste(
    _ pasteID: UInt64,
    in wsID: WorkspaceID,
    notify client: UUID?
  ) {
    guard let paste = leases[wsID]?.pastes.removeValue(forKey: pasteID),
      let runtime = panes[paste.pane]?.runtime
    else { return }
    runtime.pasteCancel(id: pasteID) { [weak self] state in
      guard let client else { return }
      self?.onQueue {
        $0.send(.event(.paste(id: pasteID, state: state)), to: client)
      }
    }
  }

  private func cancelPastes(_ wsID: WorkspaceID) {
    for id in leases[wsID]?.pastes.keys.map({ $0 }) ?? [] {
      cancelPaste(id, in: wsID, notify: nil)
    }
  }

  // MARK: Lease and lifetime

  func releaseLease(
    _ wsID: WorkspaceID,
    notify: Bool,
    reason: String
  ) {
    guard let current = leases[wsID] else { return }
    // Cancellation cleanup is queued on each pane ahead of any later input.
    cancelPastes(wsID)
    resetViewports(wsID)
    for slot in current.frames.values { releaseBudget(slot) }
    leases.removeValue(forKey: wsID)
    leaseOrder.removeAll { $0 == wsID }
    clientLeases.removeValue(forKey: current.client)
    if notify { send(.event(.detached(reason: reason)), to: current.client) }
    publishWorkspaces()
    checkIdle()
  }

  private func resetViewports(_ wsID: WorkspaceID) {
    guard let ws = workspaces.first(where: { $0.id == wsID }) else { return }
    for pane in ws.allPanes { panes[pane]?.runtime.resetViewport() }
  }

  /// The ordered empty-state barrier: no workspaces, retained screens,
  /// attachment, pending launches or teardowns, and no connections.
  public var isEmpty: Bool {
    workspaces.isEmpty && panes.isEmpty && pendingLaunches == 0
      && leases.isEmpty
  }

  func checkIdle() {
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

  func runtime(_ pane: PaneID) -> PaneRuntime? { panes[pane]?.runtime }

  /// Frame bytes sent and not yet acknowledged, plus estimates held by
  /// captures in progress (tests, diagnostics).
  package var pendingFrameBytes: Int { inflightFrameBytes + reservedFrameBytes }

  /// Frames being captured or awaiting acknowledgement (tests).
  package var outstandingFrames: Int {
    leases.values.reduce(0) { n, lease in
      n + lease.frames.values.count { $0.capture != nil || $0.inflight != nil }
    }
  }

  public func panePID(_ pane: PaneID) -> Int32? {
    panes[pane].map { $0.runtime.pid }
  }
}
