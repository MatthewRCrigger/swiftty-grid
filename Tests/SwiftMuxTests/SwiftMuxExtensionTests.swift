import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

/// Attach readiness, per-viewer viewports, and bounded read-only observers.
/// Drives `MuxService` through `MuxConnection`.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct SwiftMuxExtensionTests {
  @Test
  func readyWaitsForVisibleFramesOnly() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, hidden) = try await create(c)
    guard
      case let .attached(_, attached) = try await c.execute(
        .attach(AttachRequest(.id(ws)))
      )
    else { throw MuxError(.invalidRequest, "attach") }
    #expect(attached.attachmentRole == .controller)
    #expect(await c.readiness == nil)
    // Naming no panes while a pane is visible must not report Ready.
    try await c.execute(.setSubscriptions([]))
    try await Task.sleep(for: .milliseconds(200))
    #expect(await c.readiness == nil)

    guard
      case let .layout(split) = try await c.execute(
        .newTab(name: "other", launch: shellLaunch())
      ), let shown = split.activeTabSnapshot?.activePane
    else { throw MuxError(.invalidRequest, "tab") }
    #expect(shown != hidden)
    await c.setSuppressesFrameAcknowledgement(true)
    try await c.execute(.setSubscriptions([shown, hidden]))
    let installed = try await waitInstall(c, pane: shown)
    try await Task.sleep(for: .milliseconds(250))
    #expect(await c.readiness == nil)
    await c.acknowledgeFrame(
      pane: shown,
      revision: installed.identity.revision
    )
    let ready = try await waitReady(c)
    let attachment = await c.attachment
    let server = await c.welcome?.server
    #expect(ready.attachment == attachment)
    #expect(ready.server == server)
    #expect(ready.initialFrames.map(\.pane) == [shown])
    #expect(
      ready.initialFrames.first?.frameRevision == installed.identity.revision
    )
    #expect(
      ready.initialFrames.first?.geometryRevision
        == installed.identity.geometryGeneration
    )
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func legacyAttachIsTheSoleController() async throws {
    let h = try Harness()
    let legacy = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: []
    )
    let (ws, pane) = try await create(legacy)
    let shown = try await legacy.attachAndShow(.id(ws))
    #expect(shown.attachmentRole == .controller)
    _ = try await legacy.frame(of: pane) { _ in true }
    let deadline = ContinuousClock.now + .milliseconds(400)
    while ContinuousClock.now < deadline {
      if await legacy.readiness != nil { break }
      do {
        let event = try await legacy.nextEvent(timeout: .milliseconds(50))
        if case .ready = event { break }
      } catch is MuxConnection.EventWaitError {
        continue
      }
    }
    #expect(await legacy.readiness == nil)
    let second = try await h.connect()
    #expect(
      await rejection {
        _ = try await second.execute(.attach(AttachRequest(.id(ws))))
      } == .leaseHeld
    )
    try await legacy.execute(.endWorkspace(.id(ws)))
    await legacy.close()
    await second.close()
  }

  @Test
  func reattachShowsOwnedCellsAndRejectsStaleFrames() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8, generation: 5)
    let pid = try #require(await h.service.panePID(pane))
    let wide = String(repeating: "W", count: 90)
    try await c.send(.text("echo owned-screen-42 \(wide)\r"), to: pane)
    let first = try await c.frame(of: pane) {
      $0.lines.contains { $0.contains("owned-screen-42") }
    }
    try FrameValidator.validate(first)
    let owned = try #require(await h.service.screenLines(pane))
    #expect(first.lines == owned)
    #expect(first.lines.contains { $0.count == 40 && $0.allSatisfy { $0 == "W" } })
    await c.close()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await h.service.panePID(pane) == pid)
    let again = try await h.connect()
    try await again.attachAndShow(.id(ws), columns: 40, rows: 8, generation: 6)
    let second = try await again.frame(of: pane) {
      $0.lines.contains { $0.contains("owned-screen-42") }
    }
    try FrameValidator.validate(second)
    let ownedAgain = try #require(await h.service.screenLines(pane))
    #expect(second.lines == ownedAgain)
    #expect(await h.service.panePID(pane) == pid)
    #expect(await again.readiness != nil)

    let shown = second
    var older = shown
    older.identity.revision = shown.identity.revision &- 1
    var foreignServer = shown
    foreignServer.identity.server = ServerInstanceID()
    foreignServer.identity.revision = shown.identity.revision &+ 3
    var foreignAttachment = shown
    foreignAttachment.identity.attachment = AttachmentID()
    foreignAttachment.identity.revision = shown.identity.revision &+ 3
    var staleGeometry = shown
    staleGeometry.identity.geometryGeneration = shown.identity.geometryGeneration &- 1
    staleGeometry.identity.revision = shown.identity.revision &+ 3
    var staleLayout = shown
    staleLayout.identity.layoutRevision = shown.identity.layoutRevision &- 1
    staleLayout.identity.revision = shown.identity.revision &+ 3
    for rejected in [older, foreignServer, foreignAttachment, staleGeometry, staleLayout] {
      #expect(await again.install(rejected) == false)
    }
    #expect(
      await again.installation.visible[pane]?.identity.revision
        == shown.identity.revision
    )
    var newer = shown
    newer.identity.revision = shown.identity.revision &+ 1
    #expect(await again.install(newer))
    #expect(await again.installation.visible[pane]?.lines == shown.lines)
    try await again.execute(.endWorkspace(.id(ws)))
    await again.close()
  }

  @Test
  func inputBeforeTheLeaseIsNotWritten() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    #expect(
      await rejection {
        try await c.send(.text("echo leaked-before-lease\r"), to: pane)
      } == .notAttached
    )
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(.text("echo after-lease-ok\r"), to: pane)
    let frame = try await c.frame(of: pane) {
      $0.lines.contains("after-lease-ok")
    }
    #expect(!frame.lines.contains { $0.contains("leaked-before-lease") })
    let owned = try #require(await h.service.screenLines(pane))
    #expect(frame.lines == owned)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
  }

  @Test
  func viewersHaveIndependentViewports() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let shown = try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    try await c.send(
      .text(
        "i=0; while [ $i -lt 40 ]; do echo row-$i; i=$((i+1)); done\r"
      ),
      to: pane
    )
    let tail = try await c.frame(of: pane, label: "tail") {
      $0.lines.contains("row-39") && $0.history.scrollbackRows > 12
    }
    let generation = tail.history.generation
    let older = tail.history.firstRow
    let middle = tail.history.viewportTop - 8
    #expect(older != middle)

    let a = try await observe(h, ws, panes: [pane])
    let b = try await observe(h, ws, panes: [pane])
    try await pin(a, pane: pane, anchor: older, generation: generation)
    let frameA = try await a.frame(of: pane, label: "anchor-a") {
      $0.history.viewportTop == older && $0.history.viewportOffset > 0
    }
    try await pin(
      b,
      pane: pane,
      anchor: middle,
      generation: generation,
      rows: 4,
      columns: 12
    )
    let frameB = try await b.frame(of: pane, label: "anchor-b") {
      $0.history.viewportTop == middle && $0.grid.rows == 4
        && $0.grid.columns == 12
    }
    #expect(frameA.history.viewportTop != frameB.history.viewportTop)
    #expect(frameA.copiedText() != frameB.copiedText())
    #expect(frameA.copiedText() == frameA.lines.joined(separator: "\n"))
    let frozen = frameA.copiedText()

    let runtime = try #require(await h.service.runtime(pane))
    let offset = await withCheckedContinuation { done in
      runtime.inspect { $0.viewportOffset } completion: { done.resume(returning: $0) }
    }
    #expect(offset == 0)
    #expect(runtime.size.columns == 40)
    #expect(runtime.size.rows == 8)
    // The tail frame was already consumed. A zero scroll republishes the
    // controller viewport without moving it or resizing the PTY.
    try await c.execute(.scroll(pane: pane, .lines(0)))
    let live = try await c.frame(of: pane, label: "controller-tail") {
      $0.history.viewportOffset == 0 && $0.grid.columns == 40
        && $0.grid.rows == 8 && $0.lines.contains("row-39")
    }
    #expect(live.lines.contains("row-39"))
    try await c.send(.text("stty size\r"), to: pane)
    _ = try await c.frame(of: pane, label: "stty-40") { $0.lines.contains("8 40") }

    try await c.send(.text("echo tail-marker-99\r"), to: pane)
    _ = try await c.frame(of: pane, label: "marker") {
      $0.lines.contains("tail-marker-99")
    }
    let pinned = try await a.frame(of: pane, label: "pinned") {
      $0.identity.revision > frameA.identity.revision
    }
    #expect(pinned.history.viewportTop == older)
    #expect(!pinned.lines.contains { $0.contains("tail-marker-99") })
    #expect(frozen == frameA.lines.joined(separator: "\n"))
    #expect(!frozen.contains("tail-marker-99"))
    let latestOwned = try #require(await h.service.screenLines(pane))
    #expect(latestOwned.contains { $0.contains("tail-marker-99") })
    #expect(frozen != latestOwned.joined(separator: "\n"))

    try await pin(b, pane: pane, followTail: true, generation: generation)
    let followed = try await b.frame(of: pane, label: "follow") {
      $0.lines.contains { $0.contains("tail-marker-99") } && $0.grid.columns == 40
    }
    #expect(followed.history.viewportOffset == 0)
    #expect(
      await rejection {
        try await pin(a, pane: pane, anchor: older, generation: generation &+ 9)
      } == .historyUnavailable
    )
    #expect(
      await rejection {
        try await pin(
          a,
          pane: pane,
          followTail: true,
          generation: generation,
          rows: 3
        )
      } == .invalidRequest
    )

    try await expectReflowDropsAnchor(
      controller: c,
      viewer: a,
      pane: pane,
      layoutRevision: shown.layoutRevision,
      generation: generation,
      anchor: older
    )
    try await pin(a, pane: pane, followTail: true, generation: 0)
    try await c.send(.text("stty size\r"), to: pane)
    _ = try await a.frame(of: pane, label: "stty-50") { $0.lines.contains("8 50") }
    #expect(runtime.size.columns == 50)
    #expect(runtime.size.rows == 8)

    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await a.close()
    await b.close()
  }

  @Test
  func observersAreBoundedAndCannotMutate() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    let shown = try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    let tab = try #require(shown.activeTabSnapshot?.id)
    #expect(
      await rejection {
        _ = try await c.execute(
          .attach(AttachRequest(.id(ws), role: .observer))
        )
      } == .alreadyAttached
    )
    var observers: [MuxConnection] = []
    for _ in 0 ..< SMX.maxObservers {
      observers.append(try await observe(h, ws, panes: [pane]))
    }
    let extra = try await h.connect()
    #expect(
      await rejection {
        _ = try await extra.execute(
          .attach(AttachRequest(.id(ws), role: .observer))
        )
      } == .resourceLimit
    )
    let other = try await h.connect()
    #expect(
      await rejection {
        _ = try await other.execute(.attach(AttachRequest(.id(ws))))
      } == .leaseHeld
    )
    let observer = observers[0]
    let generation = try await leaseGeneration(observer, ws)
    await expectObserverCannotMutate(
      observer,
      pane: pane,
      tab: tab,
      workspace: ws,
      generation: generation
    )
    guard case .status = try await observer.execute(.status) else {
      throw MuxError(.invalidRequest, "status")
    }
    guard case .workspaces = try await observer.execute(.listWorkspaces) else {
      throw MuxError(.invalidRequest, "list")
    }
    try await c.send(.text("echo controller-still-writes\r"), to: pane)
    let frame = try await c.frame(of: pane) {
      $0.lines.contains("controller-still-writes")
    }
    #expect(!frame.lines.contains { $0.contains("observer-write") })
    #expect(!frame.lines.contains { $0.contains("observer-paste") })
    let watched = try await observer.frame(of: pane) {
      $0.lines.contains("controller-still-writes")
    }
    #expect(watched.lines == frame.lines)

    let pid = try #require(await h.service.panePID(pane))
    try await c.send(.text("sleep 1; echo observer-still-sees\r"), to: pane)
    await c.close()
    try await Task.sleep(for: .milliseconds(150))
    #expect(await h.service.panePID(pane) == pid)
    let later = try await observer.frame(of: pane, timeout: .seconds(8)) {
      $0.lines.contains("observer-still-sees")
    }
    #expect(await observer.attachment != nil)
    #expect(
      await rejection {
        try await observer.send(.text("echo promoted\r"), to: pane)
      } == .unauthorized
    )
    #expect(!later.lines.contains { $0.contains("promoted") })
    #expect(await h.service.panePID(pane) == pid)

    try await other.execute(.endWorkspace(.id(ws)))
    await other.close()
    await extra.close()
    for observer in observers { await observer.close() }
  }

  @Test
  func takeoverCancelsPendingInputWithoutPromotingAnObserver() async throws {
    let h = try Harness()
    let controller = try await h.connect()
    let (ws, pane) = try await create(controller)
    try await controller.attachAndShow(.id(ws), columns: 40, rows: 8)
    let observer = try await observe(h, ws, panes: [pane])
    let observerAttachment = await observer.attachment
    await controller.setPasteRetry(attempts: 40, delay: .milliseconds(25))
    // Echo off so the queued paste does not flood the screen. Sleep keeps
    // the shell from reading while the writer still holds the tail.
    try await controller.send(
      .text("stty -echo; echo ECHO-OFF; sleep 3\r"),
      to: pane
    )
    _ = try await controller.frame(of: pane, label: "echo-off") {
      $0.lines.contains("ECHO-OFF")
    }
    // Short lines fill the canonical input buffer. A single oversize line
    // is discarded by the tty without ever blocking the writer, so the
    // tail would already be gone before takeover. The token sits past
    // the first chunk and must still be queued when the lease ends.
    let line = String(repeating: "q", count: 40) + "\n"
    let paste = Task {
      try await controller.paste(
        String(repeating: line, count: 2500) + "GHOST-TAIL-TOKEN\n",
        to: pane
      )
    }
    let runtime = try #require(await h.service.runtime(pane))
    let backlogDeadline = ContinuousClock.now + .seconds(2)
    var pending = 0
    while ContinuousClock.now < backlogDeadline {
      pending = runtime.outstandingInput.withLock { $0 }
      if pending > 20_000 { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    if pending <= 20_000 {
      throw MuxError(
        .notFound,
        "writer never backed up, outstanding=\(pending)"
      )
    }
    // Admitted only after the paste has filled the tty buffer, so this
    // command is pending behind that paste and still unwritten.
    try await controller.send(.text("echo ghost-cmd-token\r"), to: pane)
    pending = runtime.outstandingInput.withLock { $0 }
    if pending <= 20_000 {
      throw MuxError(
        .notFound,
        "writer drained before takeover, outstanding=\(pending)"
      )
    }
    #expect(
      await rejection {
        _ = try await observer.execute(
          .takeover(
            .id(ws),
            expectedLease: try await leaseGeneration(observer, ws)
          )
        )
      } == .unauthorized
    )
    let taker = try await h.connect()
    let generation = try await leaseGeneration(taker, ws)
    guard
      case let .attached(_, snap) = try await taker.execute(
        .takeover(.id(ws), expectedLease: generation)
      )
    else { throw MuxError(.invalidRequest, "takeover") }
    #expect(snap.attachmentRole == .controller)
    #expect(await observer.attachment == observerAttachment)
    #expect(await taker.attachment != observerAttachment)
    _ = try? await paste.value
    try await taker.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: snap.layoutRevision,
          generation: 2,
          entries: [.init(pane: pane, columns: 40, rows: 8)]
        )
      )
    )
    try await taker.execute(.setSubscriptions([pane]))
    // The discarded paste can leave a partial canonical line in the
    // kernel. Kill that editing line (not the shell) and then prove the
    // new writer. Completed lines already in the kernel still run; a
    // cancelled tail must not.
    try await taker.send(
      .text("\u{15}printf 'KEPT-LINE-OK\\n'\r"),
      to: pane
    )
    let leaked = LeakFlag()
    let frame = try await taker.frame(
      of: pane,
      timeout: .seconds(15),
      label: "kept"
    ) { frame in
      if frame.lines.contains(where: {
        $0.contains("GHOST-TAIL-TOKEN") || $0.contains("ghost-cmd-token")
      }) {
        leaked.value = true
      }
      return frame.lines.contains { $0.contains("KEPT-LINE-OK") }
    }
    #expect(!leaked.value)
    #expect(frame.lines.filter { $0.contains("KEPT-LINE-OK") }.count == 1)
    #expect(!frame.lines.contains { $0.contains("GHOST-TAIL-TOKEN") })
    #expect(!frame.lines.contains { $0.contains("ghost-cmd-token") })
    let seen = try await observer.frame(of: pane, label: "observer-kept") {
      $0.lines.contains { $0.contains("KEPT-LINE-OK") }
    }
    #expect(await rejection {
      try await observer.send(.text("echo still-observer\r"), to: pane)
    } == .unauthorized)
    #expect(!seen.lines.contains { $0.contains("still-observer") })
    try await taker.execute(.endWorkspace(.id(ws)))
    await taker.close()
    await observer.close()
    await controller.close()
  }

  @Test
  func aSlowObserverDoesNotStallTheController() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 40, rows: 8)
    let observer = try await h.connect()
    guard
      case .attached = try await observer.execute(
        .attach(AttachRequest(.id(ws), role: .observer))
      )
    else { throw MuxError(.invalidRequest, "observe") }
    await observer.setSuppressesFrameAcknowledgement(true)
    try await observer.execute(.setSubscriptions([pane]))
    let status = Task { try await observer.execute(.status) }
    try await c.send(
      .text(
        "i=0; while [ $i -lt 30 ]; do echo burst-$i; i=$((i+1)); done\r"
      ),
      to: pane
    )
    let deadline = ContinuousClock.now + .seconds(5)
    while await h.service.observerQueuedFrames(pane) < 1,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
    }
    let frame = try await c.frame(of: pane) { $0.lines.contains("burst-29") }
    guard case .status = try await status.value else {
      throw MuxError(.invalidRequest, "status")
    }
    guard case .status = try await c.execute(.status) else {
      throw MuxError(.invalidRequest, "controller status")
    }
    try await Task.sleep(for: .milliseconds(100))
    let budget = await c.welcome?.limits.pendingFrameBudget ?? 0
    #expect(await h.service.observerQueuedFrames(pane) >= 1)
    #expect(await h.service.observerQueuedFrames(pane) <= 2)
    #expect(await h.service.pendingFrameBytes <= budget)
    #expect(frame.lines.contains("burst-29"))
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }

  @Test
  func localControllerOutputReachesAnAckingObserver() async throws {
    let h = try Harness()
    let local = LocalController()
    _ = try await local.connect(h.service)
    guard
      case let .created(ws) = try await local.execute(
        .newWorkspace(NewWorkspaceRequest(name: "local", launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "create") }
    let pane = try #require(ws.tabs.first).activePane
    guard
      case let .attached(attachment, attached) = try await local.execute(
        .attach(AttachRequest(.id(ws.id)))
      )
    else { throw MuxError(.invalidRequest, "attach") }
    #expect(attached.attachmentRole == .controller)
    _ = try await local.execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: attached.layoutRevision,
          generation: 1,
          entries: [.init(pane: pane, columns: 40, rows: 8)]
        )
      )
    )
    let observer = try await observe(h, ws.id, panes: [pane])
    let first = try await observer.frame(of: pane, label: "observer-initial") {
      !$0.lines.contains { $0.contains("LOCAL-PUMP-TOKEN") }
    }
    try FrameValidator.validate(first)
    // The status request follows the frame ack on this connection, so the
    // service has retired the in-flight frame before the next write.
    guard case .status = try await observer.execute(.status) else {
      throw MuxError(.invalidRequest, "status")
    }
    try await local.send(
      .text("echo LOCAL-PUMP-TOKEN\r"),
      attachment: attachment,
      pane: pane
    )
    let next = try await observer.frame(of: pane, label: "observer-pumped") {
      $0.identity.revision > first.identity.revision
        && $0.lines.contains { $0.contains("LOCAL-PUMP-TOKEN") }
    }
    try FrameValidator.validate(next)
    #expect(next.identity.revision > first.identity.revision)
    #expect(next.lines.contains { $0.contains("LOCAL-PUMP-TOKEN") })
    _ = try await local.execute(.endWorkspace(.id(ws.id)))
    await local.close()
    await observer.close()
  }

  @Test
  func observerSearchFrameMatchesTheSearchReply() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 80, rows: 24)
    try await c.send(
      .text(
        "printf 'ALPHA-MATCH one\\nALPHA-MATCH two\\nALPHA-MATCH three\\n'\r"
      ),
      to: pane
    )
    _ = try await c.frame(of: pane) {
      $0.lines.contains { $0.contains("ALPHA-MATCH three") }
    }
    let observer = try await observe(h, ws, panes: [pane])
    _ = try await observer.frame(of: pane) { _ in true }
    guard
      case let .search(found) = try await observer.execute(
        .search(pane: pane, query: "ALPHA-MATCH")
      )
    else { throw MuxError(.invalidRequest, "search") }
    #expect(found.matchCount >= 3)
    #expect(found.selected == found.matchCount - 1)
    let highlighted = try await observer.frame(of: pane, label: "search") {
      $0.search?.selected == found.selected && $0.search?.selectedVisible != nil
    }
    try FrameValidator.validate(highlighted)
    #expect(highlighted.search?.matchCount == found.matchCount)
    #expect(highlighted.search?.selected == found.selected)
    let visible = try #require(highlighted.search?.selectedVisible)
    let spans = try #require(highlighted.search?.visible)
    #expect(spans.indices.contains(visible))
    #expect(highlighted.lines[spans[visible].startRow].contains("ALPHA-MATCH"))

    guard
      case let .search(stepped) = try await observer.execute(
        .searchStep(pane: pane, forward: false)
      )
    else { throw MuxError(.invalidRequest, "step") }
    #expect(stepped.selected == (found.selected ?? 0) - 1)
    let steppedFrame = try await observer.frame(of: pane, label: "search-step") {
      $0.search?.selected == stepped.selected && $0.search?.selectedVisible != nil
    }
    try FrameValidator.validate(steppedFrame)
    #expect(steppedFrame.search?.selected == stepped.selected)
    #expect(steppedFrame.search?.selected != found.selected)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }

  @Test
  func observerEndSearchClearsHighlights() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let (ws, pane) = try await create(c)
    try await c.attachAndShow(.id(ws), columns: 80, rows: 24)
    try await c.send(.text("echo END-SEARCH-TOKEN\r"), to: pane)
    _ = try await c.frame(of: pane) {
      $0.lines.contains { $0.contains("END-SEARCH-TOKEN") }
    }
    let observer = try await observe(h, ws, panes: [pane])
    _ = try await observer.frame(of: pane) { _ in true }
    guard
      case .search = try await observer.execute(
        .search(pane: pane, query: "END-SEARCH-TOKEN")
      )
    else { throw MuxError(.invalidRequest, "search") }
    let highlighted = try await observer.frame(of: pane, label: "highlighted") {
      !($0.search?.visible.isEmpty ?? true)
    }
    #expect(highlighted.search?.visible.isEmpty == false)
    guard
      case let .search(ended) = try await observer.execute(
        .endSearch(pane: pane)
      )
    else { throw MuxError(.invalidRequest, "end search") }
    #expect(ended.matchCount == 0)
    #expect(ended.selected == nil)
    let cleared = try await observer.frame(of: pane, label: "end-search") {
      $0.search == nil || $0.search?.visible.isEmpty == true
    }
    try FrameValidator.validate(cleared)
    #expect(cleared.identity.revision > highlighted.identity.revision)
    #expect(cleared.search == nil || cleared.search?.visible.isEmpty == true)
    try await c.execute(.endWorkspace(.id(ws)))
    await c.close()
    await observer.close()
  }
}

private final class LeakFlag: @unchecked Sendable {
  var value = false
}

private func create(_ c: MuxConnection) async throws -> (WorkspaceID, PaneID) {
  guard
    case let .created(ws) = try await c.execute(
      .newWorkspace(NewWorkspaceRequest(name: "ext", launch: shellLaunch()))
    )
  else { throw MuxError(.invalidRequest, "create") }
  return (ws.id, ws.tabs[0].activePane)
}

private func observe(
  _ h: Harness,
  _ ws: WorkspaceID,
  panes: [PaneID]
) async throws -> MuxConnection {
  let c = try await h.connect()
  guard
    case let .attached(_, snap) = try await c.execute(
      .attach(AttachRequest(.id(ws), role: .observer))
    )
  else { throw MuxError(.invalidRequest, "observe") }
  #expect(snap.attachmentRole == .observer)
  try await c.execute(.setSubscriptions(panes))
  return c
}

private func leaseGeneration(
  _ c: MuxConnection,
  _ id: WorkspaceID
) async throws -> UInt64 {
  guard
    case let .workspaces(list) = try await c.execute(.listWorkspaces),
    let summary = list.first(where: { $0.id == id })
  else { throw MuxError(.notFound, "workspace") }
  return summary.leaseGeneration
}

private func rejection(
  _ body: () async throws -> Void
) async -> MuxError.Code? {
  do {
    try await body()
    return nil
  } catch let error as MuxError {
    return error.code
  } catch { return nil }
}

private func waitInstall(
  _ c: MuxConnection,
  pane: PaneID
) async throws -> PaneFrame {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if let frame = await c.installation.visible[pane] { return frame }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw MuxError(.notFound, "frame")
}

private func pin(
  _ c: MuxConnection,
  pane: PaneID,
  anchor: Int? = nil,
  followTail: Bool = false,
  generation: UInt64,
  rows: Int? = nil,
  columns: Int? = nil
) async throws {
  try await c.execute(
    .setViewport(
      ViewportRequest(
        pane: pane,
        anchorRow: anchor,
        followTail: followTail,
        historyGeneration: generation,
        rows: rows,
        columns: columns
      )
    )
  )
}

/// Resizes the PTY, then requires the viewer's old anchor to fail closed.
private func expectReflowDropsAnchor(
  controller: MuxConnection,
  viewer: MuxConnection,
  pane: PaneID,
  layoutRevision: UInt64,
  generation: UInt64,
  anchor: Int
) async throws {
  try await controller.execute(
    .setGeometry(
      GeometryBatch(
        layoutRevision: layoutRevision,
        generation: 2,
        entries: [.init(pane: pane, columns: 50, rows: 8)]
      )
    )
  )
  var replaced = false
  var unavailable = false
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline, !unavailable {
    let event: MuxEvent?
    do {
      event = try await viewer.nextEvent(timeout: .milliseconds(200))
    } catch is MuxConnection.EventWaitError {
      continue
    }
    switch event {
    case let .frameUnavailable(id, error) where id == pane:
      unavailable = error.code == .historyUnavailable
    case let .frame(frame) where frame.identity.pane == pane:
      if frame.history.generation != generation,
        frame.lines.contains(where: { $0.contains("tail-marker-99") })
      {
        replaced = true
      }
    default: break
    }
  }
  #expect(unavailable)
  #expect(!replaced)
  #expect(
    await rejection {
      try await pin(viewer, pane: pane, anchor: anchor, generation: generation)
    } == .historyUnavailable
  )
}

private func expectObserverCannotMutate(
  _ observer: MuxConnection,
  pane: PaneID,
  tab: TabID,
  workspace: WorkspaceID,
  generation: UInt64
) async {
  #expect(
    await rejection {
      try await observer.send(.text("echo observer-write\r"), to: pane)
    } == .unauthorized
  )
  #expect(
    await rejection {
      try await observer.send(.focus(true), to: pane)
    } == .unauthorized
  )
  #expect(
    await rejection { _ = try await observer.paste("observer-paste", to: pane) }
      == .unauthorized
  )
  #expect(
    await rejection {
      try await observer.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: 1,
            generation: 9,
            entries: [.init(pane: pane, columns: 20, rows: 4)]
          )
        )
      )
    } == .unauthorized
  )
  #expect(
    await rejection { try await observer.execute(.focusPane(pane)) }
      == .unauthorized
  )
  #expect(
    await rejection {
      try await observer.execute(.split(pane: pane, axis: .leftRight, launch: nil))
    } == .unauthorized
  )
  #expect(
    await rejection { try await observer.execute(.toggleZoom(tab)) } == .unauthorized
  )
  #expect(
    await rejection {
      _ = try await observer.execute(
        .takeover(.id(workspace), expectedLease: generation)
      )
    } == .unauthorized
  )
  #expect(
    await rejection { try await observer.execute(.endPane(pane)) } == .unauthorized
  )
  #expect(
    await rejection { try await observer.execute(.endWorkspace(.id(workspace))) }
      == .unauthorized
  )
}

private func waitReady(_ c: MuxConnection) async throws -> ReadyNotice {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if let ready = await c.readiness { return ready }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw MuxError(.notFound, "ready")
}

/// In-process controller. Frames stay on the XPC observer; this client
/// only drives the lease.
private final class LocalController: @unchecked Sendable {
  private let queue = DispatchQueue(label: "swiftmux.local-controller")
  private var connection: MuxLocalConnection?
  private var nextRequest: UInt64 = 1
  private var requests: [UInt64: CheckedContinuation<MuxResult, Never>] = [:]
  private var nextInput: UInt64 = 1
  private var inputs: [UInt64: CheckedContinuation<MuxError?, Never>] = [:]
  private var welcomeWait: CheckedContinuation<Welcome, Error>?
  private var closed = false

  func connect(_ service: MuxService) async throws -> Welcome {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        let sink = LocalClientSink(
          onMessage: { [weak self] message in
            guard let self else { return }
            self.queue.async { self.receive(message) }
          },
          onPaneChanged: { _ in },
          onClosed: { [weak self] reason in
            guard let self else { return }
            self.queue.async {
              self.finish(MuxError(.connectionLost, reason))
            }
          }
        )
        let connection = service.connectLocal(remote: false, sink: sink)
        self.connection = connection
        self.welcomeWait = continuation
        connection.send(.hello(Hello(frontend: .native)))
      }
    }
  }

  func execute(_ command: MuxCommand) async throws -> MuxReply {
    let result = await withCheckedContinuation { continuation in
      queue.async {
        guard let connection = self.connection, !self.closed else {
          continuation.resume(
            returning: MuxResult.failure(MuxError(.connectionLost))
          )
          return
        }
        let id = self.nextRequest
        self.nextRequest += 1
        self.requests[id] = continuation
        connection.sendRequest(id: id, command: command)
      }
    }
    return try result.get()
  }

  func send(
    _ input: MuxInput,
    attachment: AttachmentID,
    pane: PaneID
  ) async throws {
    let error = await withCheckedContinuation {
      (continuation: CheckedContinuation<MuxError?, Never>) in
      queue.async {
        guard let connection = self.connection, !self.closed else {
          continuation.resume(returning: MuxError(.connectionLost))
          return
        }
        let sequence = self.nextInput
        self.nextInput += 1
        self.inputs[sequence] = continuation
        connection.send(
          .input(
            InputRecord(
              sequence: sequence,
              attachment: attachment,
              pane: pane,
              payload: .input(input)
            )
          )
        )
      }
    }
    if let error { throw error }
  }

  func close() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async {
        guard let connection = self.connection else {
          self.finish(MuxError(.connectionLost, "closed"))
          continuation.resume()
          return
        }
        self.connection = nil
        self.finish(MuxError(.connectionLost, "closed"))
        connection.close { continuation.resume() }
      }
    }
  }

  private func receive(_ message: ServerMessage) {
    switch message {
    case let .welcome(welcome):
      welcomeWait?.resume(returning: welcome)
      welcomeWait = nil
    case let .rejected(error):
      welcomeWait?.resume(throwing: error)
      welcomeWait = nil
      finish(error)
    case let .reply(id, result):
      requests.removeValue(forKey: id)?.resume(returning: result)
    case let .inputAck(sequence, error):
      inputs.removeValue(forKey: sequence)?.resume(returning: error)
    case .event: break
    }
  }

  private func finish(_ error: MuxError) {
    guard !closed else { return }
    closed = true
    let pending = requests
    requests = [:]
    for continuation in pending.values {
      continuation.resume(returning: .failure(error))
    }
    let pendingInputs = inputs
    inputs = [:]
    for continuation in pendingInputs.values {
      continuation.resume(returning: error)
    }
    if let welcomeWait {
      self.welcomeWait = nil
      welcomeWait.resume(throwing: error)
    }
  }
}
