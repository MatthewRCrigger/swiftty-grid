import Dispatch
import Foundation
import SwiftMuxProtocol

extension MuxService {
  // MARK: Viewers

  func grantViewer(
    _ ws: Workspace,
    to client: Client,
    hello: Hello,
  ) throws(MuxError) -> MuxReply {
    guard !client.remote else {
      throw MuxError(.unauthorized, "roaming observers are not enabled")
    }
    var list = viewers[ws.id] ?? []
    guard list.count < SMX.maxObservers else {
      throw MuxError(
        .resourceLimit,
        "this workspace already has \(SMX.maxObservers) observers",
      )
    }
    recordLocalUse(ws.id, by: client)
    var viewer = Viewer(client: client.id, workspace: ws.id)
    viewer.readiness.enabled = hello.capabilities.contains(.attachReadiness)
    list.append(viewer)
    viewers[ws.id] = list
    clientViewers[client.id] = ws.id
    idleWork?.cancel()
    var snap = snapshot(ws)
    snap.attachmentRole = .observer
    return .attached(attachment: viewer.attachment, workspace: snap)
  }

  func viewerIndex(_ client: UUID) -> (WorkspaceID, Int)? {
    guard let wsID = clientViewers[client],
      let index = viewers[wsID]?.firstIndex(where: { $0.client == client })
    else { return nil }
    return (wsID, index)
  }

  func releaseViewer(_ client: UUID, reason: String) {
    guard let (wsID, index) = viewerIndex(client) else { return }
    let viewer = viewers[wsID]![index]
    for slot in viewer.frames.values { releaseBudget(slot) }
    viewers[wsID]?.remove(at: index)
    if viewers[wsID]?.isEmpty == true { viewers[wsID] = nil }
    clientViewers.removeValue(forKey: client)
    send(.event(.detached(reason: reason)), to: client)
  }

  func releaseViewers(in wsID: WorkspaceID, reason: String) {
    for viewer in viewers[wsID] ?? [] {
      for slot in viewer.frames.values { releaseBudget(slot) }
      clientViewers.removeValue(forKey: viewer.client)
      send(.event(.detached(reason: reason)), to: viewer.client)
    }
    viewers[wsID] = nil
  }

  func dropPaneFromViewers(_ pane: PaneID, workspace wsID: WorkspaceID) {
    guard var list = viewers[wsID] else { return }
    for index in list.indices {
      list[index].subscriptions.removeAll { $0 == pane }
      list[index].viewports[pane] = nil
      list[index].unavailable.remove(pane)
      list[index].readiness.required.remove(pane)
      list[index].readiness.installed.removeValue(forKey: pane)
      if let slot = list[index].frames.removeValue(forKey: pane) {
        releaseBudget(slot)
      }
    }
    viewers[wsID] = list
  }

  func viewerSubscribed(_ wsID: WorkspaceID, pane: PaneID) -> Bool {
    viewers[wsID]?.contains { $0.frames[pane] != nil } ?? false
  }

  func markViewersDirty(_ wsID: WorkspaceID, pane: PaneID) {
    guard var list = viewers[wsID] else { return }
    for index in list.indices where list[index].frames[pane] != nil {
      list[index].frames[pane]?.dirty = true
    }
    viewers[wsID] = list
  }

  func visiblePaneIDs(_ ws: Workspace) -> Set<PaneID> {
    guard let tab = ws.tabs.first(where: { $0.id == ws.activeTab }) else {
      return []
    }
    if let zoom = tab.zoomedPane { return [zoom] }
    return Set(tab.layout.panes)
  }

  func armReadiness(
    controller wsID: WorkspaceID,
    panes: [PaneID],
    workspace ws: Workspace,
  ) {
    guard var lease = leases[wsID] else { return }
    let publish = arm(&lease.readiness, panes: panes, workspace: ws)
    let readiness = lease.readiness
    let attachment = lease.attachment
    let client = lease.client
    leases[wsID] = lease
    guard publish else { return }
    publishReady(
      readiness,
      attachment: attachment,
      client: client,
      store: { self.leases[wsID]?.readiness.sent = true },
    )
  }

  /// False when this subscription must not publish Ready: the client has
  /// not named the visible panes yet, or Ready was already sent.
  func arm(
    _ readiness: inout Readiness,
    panes: [PaneID],
    workspace ws: Workspace,
  ) -> Bool {
    guard readiness.enabled, !readiness.sent else { return false }
    let visible = visiblePaneIDs(ws)
    if panes.isEmpty, !visible.isEmpty { return false }
    readiness.required = Set(panes).intersection(visible)
    readiness.installed = readiness.installed.filter {
      readiness.required.contains($0.key)
    }
    return true
  }

  func publishReady(
    _ readiness: Readiness,
    attachment: AttachmentID,
    client: UUID,
    store: () -> Void,
  ) {
    guard readiness.enabled, !readiness.sent,
      readiness.required.isSubset(of: Set(readiness.installed.keys))
    else { return }
    let frames = readiness.required.sorted {
      $0.rawValue.uuidString < $1.rawValue.uuidString
    }
    .map { pane in
      let installed = readiness.installed[pane]!
      return ReadyNotice.PaneRevision(
        pane: pane,
        frameRevision: installed.frame,
        geometryRevision: installed.geometry,
      )
    }
    store()
    send(
      .event(
        .ready(
          ReadyNotice(
            attachment: attachment,
            server: instance,
            initialFrames: frames,
          )
        )
      ),
      to: client,
    )
  }

  func noteReady(
    _ wsID: WorkspaceID,
    controller: Bool,
    viewer client: UUID? = nil,
    pane: PaneID,
    revision: UInt64,
    geometry: UInt64,
    acked: Bool,
  ) {
    guard acked else { return }
    if controller {
      guard var lease = leases[wsID], lease.readiness.required.contains(pane)
      else { return }
      lease.readiness.installed[pane] = (revision, geometry)
      let readiness = lease.readiness
      leases[wsID] = lease
      publishReady(
        readiness,
        attachment: lease.attachment,
        client: lease.client,
        store: { self.leases[wsID]?.readiness.sent = true },
      )
      return
    }
    guard let client, var list = viewers[wsID],
      let index = list.firstIndex(where: { $0.client == client }),
      list[index].readiness.required.contains(pane)
    else { return }
    list[index].readiness.installed[pane] = (revision, geometry)
    let viewer = list[index]
    viewers[wsID] = list
    publishReady(
      viewer.readiness,
      attachment: viewer.attachment,
      client: viewer.client,
      store: {
        self.viewers[wsID]?[index].readiness.sent = true
      },
    )
  }

  func setControllerViewport(
    _ request: ViewportRequest,
    workspace leased: WorkspaceID,
    reply: @escaping Reply,
  ) {
    guard displaySize(request) == nil else {
      reply(.failure(MuxError(.invalidRequest, "viewport size")))
      return
    }
    guard let runtime = attachedRuntime(request.pane, in: leased) else {
      reply(.failure(MuxError(.notFound, "pane")))
      return
    }
    let scroll: ScrollRequest
    if request.followTail {
      scroll = .bottom
    } else if let row = request.anchorRow {
      scroll = .top(
        HistoryAddress(
          generation: request.historyGeneration,
          alternateScreen: false,
          row: row,
        )
      )
    } else {
      reply(.failure(MuxError(.invalidRequest, "viewport anchor")))
      return
    }
    guard validScroll(scroll) else {
      reply(.failure(MuxError(.invalidRequest, "scroll distance")))
      return
    }
    runtime.scroll(scroll) { error in
      reply(error.map { .failure($0) } ?? .success(.ok))
    }
  }

  /// Nil when the display size is absent or within the frame limits.
  /// A size is display-only: it never resizes the PTY.
  func displaySize(_ request: ViewportRequest) -> MuxError? {
    guard request.rows != nil || request.columns != nil else { return nil }
    guard let rows = request.rows, let columns = request.columns,
      limits.cellCount(columns: columns, rows: rows) != nil
    else { return MuxError(.invalidRequest, "viewport size") }
    return nil
  }

  func handleViewer(
    _ command: MuxCommand,
    workspace wsID: WorkspaceID,
    client: UUID,
    reply: @escaping Reply,
  ) {
    let fail = { (error: MuxError) in reply(.failure(error)) }
    switch command {
    case let .setSubscriptions(list):
      if let error = setViewerSubscriptions(list, client: client, workspace: wsID)
      {
        fail(error)
      } else {
        reply(.success(.ok))
      }
    case let .setViewport(request):
      moveViewer(request, client: client, workspace: wsID, reply: reply)
    case let .scroll(pane, request):
      guard validScroll(request) else {
        return fail(MuxError(.invalidRequest, "scroll distance"))
      }
      scrollViewer(pane, request, client: client, workspace: wsID, reply: reply)
    case let .search(pane, query):
      guard query.utf8.count <= limits.maxSearchBytes, !query.isEmpty else {
        return fail(MuxError(.invalidRequest, "search query"))
      }
      searchViewer(
        pane,
        query: query,
        step: nil,
        client: client,
        workspace: wsID,
        reply: reply,
      )
    case let .searchStep(pane, forward):
      searchViewer(
        pane,
        query: nil,
        step: forward,
        client: client,
        workspace: wsID,
        reply: reply,
      )
    case let .endSearch(pane):
      guard var viewer = viewer(client, in: wsID) else {
        return fail(MuxError(.notAttached))
      }
      viewer.viewports[pane]?.searchQuery = nil
      viewer.viewports[pane]?.searchSelected = nil
      viewer.frames[pane]?.dirty = true
      store(viewer, client: client, workspace: wsID)
      reply(.success(.search(SearchResult(matchCount: 0, selected: nil))))
      pump()
    default:
      reply(.success(.ok))
    }
  }

  func viewer(_ client: UUID, in wsID: WorkspaceID) -> Viewer? {
    viewers[wsID]?.first { $0.client == client }
  }

  func store(_ viewer: Viewer, client: UUID, workspace wsID: WorkspaceID) {
    guard let index = viewers[wsID]?.firstIndex(where: { $0.client == client })
    else { return }
    viewers[wsID]?[index] = viewer
  }

  func setViewerSubscriptions(
    _ list: [PaneID],
    client: UUID,
    workspace wsID: WorkspaceID,
  ) -> MuxError? {
    guard var viewer = viewer(client, in: wsID),
      let ws = workspaces.first(where: { $0.id == wsID })
    else { return MuxError(.notAttached) }
    let members = Set(ws.allPanes)
    guard list.count <= limits.maxPanes, Set(list).count == list.count,
      list.allSatisfy(members.contains)
    else { return MuxError(.invalidRequest, "subscription list") }
    var frames: [PaneID: FrameSlot] = [:]
    for pane in list {
      frames[pane] = viewer.frames[pane] ?? FrameSlot()
      frames[pane]?.hiddenActivity = false
      if viewer.viewports[pane] == nil {
        viewer.viewports[pane] = ViewerViewport(
          followTail: true,
          historyGeneration: 0,
          anchorRow: nil,
        )
      }
    }
    for (pane, slot) in viewer.frames where frames[pane] == nil {
      releaseBudget(slot)
      viewer.viewports[pane] = nil
    }
    viewer.subscriptions = list
    viewer.frames = frames
    let publish = arm(&viewer.readiness, panes: list, workspace: ws)
    let readiness = viewer.readiness
    let attachment = viewer.attachment
    store(viewer, client: client, workspace: wsID)
    guard publish else {
      pump()
      return nil
    }
    publishReady(
      readiness,
      attachment: attachment,
      client: client,
      store: {
        if let index = self.viewers[wsID]?.firstIndex(where: {
          $0.client == client
        }) {
          self.viewers[wsID]?[index].readiness.sent = true
        }
      },
    )
    pump()
    return nil
  }

  func moveViewer(
    _ request: ViewportRequest,
    client: UUID,
    workspace wsID: WorkspaceID,
    reply: @escaping Reply,
  ) {
    guard displaySize(request) == nil else {
      reply(.failure(MuxError(.invalidRequest, "viewport size")))
      return
    }
    guard var viewer = viewer(client, in: wsID),
      viewer.subscriptions.contains(request.pane),
      let runtime = panes[request.pane]?.runtime
    else {
      reply(.failure(MuxError(.notFound, "pane")))
      return
    }
    guard request.followTail || request.anchorRow != nil else {
      reply(.failure(MuxError(.invalidRequest, "viewport anchor")))
      return
    }
    let rows = request.rows
    let columns = request.columns
    runtime.resolveViewer(request, searchQuery: nil, searchStep: nil) {
      [weak self] result in
      self?
        .onQueue { service in
          switch result {
          case let .failure(error):
            reply(.failure(error))
          case let .success(resolved):
            guard var viewer = service.viewer(client, in: wsID) else {
              reply(.failure(MuxError(.notAttached)))
              return
            }
            var viewport =
              viewer.viewports[request.pane]
              ?? ViewerViewport(
                followTail: true,
                historyGeneration: resolved.historyGeneration,
                anchorRow: nil,
              )
            viewport.followTail = resolved.followTail
            viewport.historyGeneration = resolved.historyGeneration
            viewport.anchorRow = resolved.anchorRow
            viewport.rows = rows
            viewport.columns = columns
            viewport.revision &+= 1
            viewer.viewports[request.pane] = viewport
            viewer.unavailable.remove(request.pane)
            viewer.frames[request.pane]?.dirty = true
            service.store(viewer, client: client, workspace: wsID)
            reply(.success(.ok))
            service.pump()
          }
        }
    }
  }

  func scrollViewer(
    _ pane: PaneID,
    _ request: ScrollRequest,
    client: UUID,
    workspace wsID: WorkspaceID,
    reply: @escaping Reply,
  ) {
    guard let viewer = viewer(client, in: wsID),
      viewer.subscriptions.contains(pane),
      let runtime = panes[pane]?.runtime
    else {
      reply(.failure(MuxError(.notFound, "pane")))
      return
    }
    let current = viewer.viewports[pane]
    runtime.resolveViewer(
      ViewportRequest(
        pane: pane,
        anchorRow: current?.anchorRow,
        followTail: current?.followTail ?? true,
        historyGeneration: current?.historyGeneration ?? 0,
        rows: current?.rows,
        columns: current?.columns,
      ),
      searchQuery: nil,
      searchStep: nil,
    ) { [weak self] result in
      self?
        .onQueue { service in
          guard case let .success(resolved) = result else {
            reply(.failure(MuxError(.historyUnavailable, "history anchor is stale")))
            return
          }
          let viewport = ViewportRequest(
            pane: pane,
            anchorRow: {
              switch request {
              case .bottom: return nil
              case let .top(address): return address.row
              case let .lines(n):
                return (resolved.anchorRow ?? 0) - n
              case let .pages(n):
                let page = max(1, (service.panes[pane]?.rows ?? 1) - 1)
                return (resolved.anchorRow ?? 0) - n * page
              }
            }(),
            followTail: {
              if case .bottom = request { return true }
              return false
            }(),
            historyGeneration: {
              if case let .top(address) = request { return address.generation }
              return resolved.historyGeneration
            }(),
            rows: current?.rows,
            columns: current?.columns,
          )
          service.moveViewer(
            viewport,
            client: client,
            workspace: wsID,
            reply: reply,
          )
        }
    }
  }

  func searchViewer(
    _ pane: PaneID,
    query: String?,
    step: Bool?,
    client: UUID,
    workspace wsID: WorkspaceID,
    reply: @escaping Reply,
  ) {
    guard var viewer = viewer(client, in: wsID),
      viewer.subscriptions.contains(pane),
      let runtime = panes[pane]?.runtime
    else {
      reply(.failure(MuxError(.notFound, "pane")))
      return
    }
    let existing = query ?? viewer.viewports[pane]?.searchQuery
    guard let existing, !existing.isEmpty || query == nil else {
      reply(.failure(MuxError(.invalidRequest, "search query")))
      return
    }
    let rows = viewer.viewports[pane]?.rows
    let columns = viewer.viewports[pane]?.columns
    let selected = viewer.viewports[pane]?.searchSelected
    runtime.resolveViewer(
      ViewportRequest(
        pane: pane,
        followTail: false,
        historyGeneration: viewer.viewports[pane]?.historyGeneration ?? 0,
      ),
      searchQuery: existing,
      searchStep: step,
      searchSelected: selected,
    ) { [weak self] result in
      self?
        .onQueue { service in
          switch result {
          case let .failure(error): reply(.failure(error))
          case let .success(resolved):
            guard var viewer = service.viewer(client, in: wsID) else {
              reply(.failure(MuxError(.notAttached)))
              return
            }
            var viewport =
              viewer.viewports[pane]
              ?? ViewerViewport(
                followTail: false,
                historyGeneration: resolved.historyGeneration,
                anchorRow: resolved.anchorRow,
              )
            viewport.followTail = resolved.followTail
            viewport.historyGeneration = resolved.historyGeneration
            viewport.anchorRow = resolved.anchorRow
            viewport.searchQuery = existing
            viewport.searchSelected = resolved.search?.selected
            viewport.rows = rows
            viewport.columns = columns
            viewport.revision &+= 1
            viewer.viewports[pane] = viewport
            viewer.frames[pane]?.dirty = true
            service.store(viewer, client: client, workspace: wsID)
            reply(.success(.search(resolved.search ?? SearchResult(matchCount: 0, selected: nil))))
            service.pump()
          }
        }
    }
  }

  /// Observers are served after controllers, and only while a controller
  /// is not waiting on the shared frame budget.
  func pumpViewers(now: UInt64) -> UInt64? {
    guard !controllerWaitingForBudget(now: now) else { return nil }
    var wake: UInt64?
    for wsID in Array(viewers.keys) {
      let count = viewers[wsID]?.count ?? 0
      for index in 0 ..< count {
        if let due = pumpViewer(wsID, index: index, now: now) {
          wake = min(wake ?? due, due)
        }
      }
    }
    return wake
  }

  func controllerWaitingForBudget(now: UInt64) -> Bool {
    let interval = limits.frameIntervalNanoseconds
    for lease in leases.values {
      for slot in lease.frames.values {
        guard slot.dirty, slot.capture == nil, slot.inflight == nil else {
          continue
        }
        if slot.lastSent != 0, now &- slot.lastSent < interval { continue }
        return inflightFrameBytes + reservedFrameBytes >= limits.pendingFrameBudget
      }
    }
    return false
  }

  func pumpViewer(
    _ wsID: WorkspaceID,
    index: Int,
    now: UInt64,
  ) -> UInt64? {
    guard let viewer = viewers[wsID]?[safe: index], !viewer.subscriptions.isEmpty
    else { return nil }
    let interval = limits.frameIntervalNanoseconds
    var wake: UInt64?
    let order = viewer.subscriptions
    let count = order.count
    let first = viewer.paneCursor % count
    viewers[wsID]?[index].paneCursor = (first + 1) % count
    for step in 0 ..< count {
      let pane = order[(first + step) % count]
      guard let slot = viewers[wsID]?[index].frames[pane], slot.dirty,
        slot.capture == nil, let record = panes[pane]
      else { continue }
      let stamp = max(slot.lastSent, slot.lastCapture)
      if stamp != 0, now &- stamp < interval {
        let due = stamp + interval
        wake = min(wake ?? due, due)
        continue
      }
      // One in flight plus one replaceable newest frame.
      if slot.inflight != nil, slot.queued != nil { continue }
      guard inflightFrameBytes + reservedFrameBytes < limits.pendingFrameBudget
      else { return wake }
      nextCapture &+= 1
      let token = nextCapture
      let estimate = captureEstimate(record)
      reservedFrameBytes += estimate
      viewers[wsID]?[index].frames[pane]?.dirty = false
      viewers[wsID]?[index].frames[pane]?.capture = token
      viewers[wsID]?[index].frames[pane]?.reserved = estimate
      viewers[wsID]?[index].frames[pane]?.lastCapture = now
      let attachment = viewer.attachment
      let layoutRevision =
        workspaces.first { $0.id == wsID }?.layoutRevision ?? 0
      let window = viewers[wsID]?[index].viewports[pane]
      let capture = ViewerCapture(
        followTail: window?.followTail ?? true,
        historyGeneration: window?.historyGeneration ?? 0,
        anchorRow: window?.anchorRow,
        rows: window?.rows,
        columns: window?.columns,
        searchQuery: window?.searchQuery,
        searchSelected: window?.searchSelected,
        viewportRevision: window?.revision ?? 0,
      )
      record.runtime.captureFrame(
        server: instance,
        attachment: attachment,
        layoutRevision: layoutRevision,
        viewport: capture,
      ) { [weak self] result in
        self?
          .onQueue {
            $0.viewerFrameCaptured(
              pane,
              workspace: wsID,
              client: viewer.client,
              token: token,
              result,
            )
          }
      }
    }
    return wake
  }

  func viewerFrameCaptured(
    _ pane: PaneID,
    workspace wsID: WorkspaceID,
    client: UUID,
    token: UInt64,
    _ result: Result<PaneRuntime.CapturedFrame, MuxError>,
  ) {
    guard let index = viewers[wsID]?.firstIndex(where: { $0.client == client }),
      let slot = viewers[wsID]?[index].frames[pane], slot.capture == token
    else { return }
    viewers[wsID]?[index].frames[pane]?.capture = nil
    viewers[wsID]?[index].frames[pane]?.reserved = 0
    reservedFrameBytes -= slot.reserved
    switch result {
    case let .success(captured):
      deliverViewerFrame(
        captured,
        pane: pane,
        workspace: wsID,
        index: index,
        slot: slot,
      )
    case let .failure(error):
      if error.code == .historyUnavailable {
        if viewers[wsID]?[index].unavailable.contains(pane) == false {
          viewers[wsID]?[index].unavailable.insert(pane)
          send(.event(.frameUnavailable(pane, error)), to: client)
        }
      } else {
        send(.event(.frameUnavailable(pane, error)), to: client)
      }
    }
    pump()
  }

  func deliverViewerFrame(
    _ captured: PaneRuntime.CapturedFrame,
    pane: PaneID,
    workspace wsID: WorkspaceID,
    index: Int,
    slot: FrameSlot,
  ) {
    guard let viewer = viewers[wsID]?[index],
      let client = clients[viewer.client], case let .xpc(channel) = client.transport
    else { return }
    let queued = QueuedFrame(
      revision: captured.revision,
      bytes: captured.data.count,
      geometry: captured.geometry,
      data: captured.data,
    )
    if slot.inflight == nil {
      channel.send(captured.data)
      viewers[wsID]?[index].frames[pane]?.inflight = (queued.revision, queued.bytes)
      viewers[wsID]?[index].frames[pane]?.inflightGeometry = queued.geometry
      viewers[wsID]?[index].frames[pane]?.lastSent =
        DispatchTime.now().uptimeNanoseconds
      inflightFrameBytes += queued.bytes
    } else {
      if let previous = slot.queued { inflightFrameBytes -= previous.bytes }
      viewers[wsID]?[index].frames[pane]?.queued = queued
      inflightFrameBytes += queued.bytes
    }
  }

  func acknowledgeViewer(
    _ pane: PaneID,
    _ revision: UInt64,
    from id: UUID,
  ) {
    guard let wsID = clientViewers[id],
      let index = viewers[wsID]?.firstIndex(where: { $0.client == id }),
      let slot = viewers[wsID]?[index].frames[pane],
      let inflight = slot.inflight, inflight.revision == revision
    else { return }
    viewers[wsID]?[index].frames[pane]?.inflight = nil
    inflightFrameBytes -= inflight.bytes
    noteReady(
      wsID,
      controller: false,
      viewer: id,
      pane: pane,
      revision: revision,
      geometry: slot.inflightGeometry,
      acked: true,
    )
    if let queued = viewers[wsID]?[index].frames[pane]?.queued,
      let client = clients[id], case let .xpc(channel) = client.transport
    {
      channel.send(queued.data)
      viewers[wsID]?[index].frames[pane]?.queued = nil
      viewers[wsID]?[index].frames[pane]?.inflight = (queued.revision, queued.bytes)
      viewers[wsID]?[index].frames[pane]?.inflightGeometry = queued.geometry
      viewers[wsID]?[index].frames[pane]?.lastSent =
        DispatchTime.now().uptimeNanoseconds
    }
    pump()
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
