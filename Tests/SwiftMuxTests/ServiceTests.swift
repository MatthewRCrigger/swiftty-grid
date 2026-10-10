import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ServiceTests {
  @Test
  func createAttachRenderAndType() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(name: "t", launch: shellLaunch()))
      )
    else {
      Issue.record("no workspace");
      return
    }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    try await c.send(.text("echo mux-$((40+2))\r"), to: pane)
    let frame = try await c.frame(of: pane) { $0.lines.contains("mux-42") }
    #expect(frame.grid.columns == 80)
    #expect(frame.identity.geometryGeneration == 1)
    let server = await c.welcome?.server
    #expect(frame.identity.server == server)
    try FrameValidator.validate(frame)
  }

  @Test
  func reattachKeepsSameShell() async throws {
    let h = try Harness()
    let c1 = try await h.connect()
    guard
      case let .created(ws) = try await c1.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c1.attachAndShow(.id(ws.id))
    try await c1.send(.text("X=persist; echo pid=$$\r"), to: pane)
    let first = try await c1.frame(of: pane) { f in
      f.lines.contains { $0.hasPrefix("pid=") }
    }
    let pid = first.lines.first { $0.hasPrefix("pid=") }!
    // A second interactive attachment is rejected while the first lives.
    let c2 = try await h.connect()
    await #expect(throws: MuxError.self) {
      try await c2.execute(.attach(.id(ws.id)))
    }
    // Client death releases the lease; the shell keeps running.
    await c1.close()
    try await Task.sleep(for: .milliseconds(200))
    try await c2.attachAndShow(.id(ws.id))
    try await c2.send(.text("echo again=$X pid=$$\r"), to: pane)
    let again = try await c2.frame(of: pane) { f in
      f.lines.contains { $0.hasPrefix("again=persist") }
    }
    #expect(again.lines.contains("again=persist \(pid)"))
  }

  @Test
  func staleGeometryAndAttachmentAreRejected() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    let shown = try await c.attachAndShow(.id(ws.id), generation: 5)
    // Older generation.
    await #expect(throws: MuxError.self) {
      try await c.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: shown.layoutRevision,
            generation: 4,
            entries: [.init(pane: pane, columns: 40, rows: 10)]
          )
        )
      )
    }
    // Stale layout revision after a split.
    _ = try await c.execute(
      .split(pane: pane, axis: .leftRight, launch: shellLaunch())
    )
    do {
      try await c.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: shown.layoutRevision,
            generation: 6,
            entries: [.init(pane: pane, columns: 40, rows: 10)]
          )
        )
      )
      Issue.record("stale layout accepted")
    } catch let e as MuxError { #expect(e.code == .staleGeometry) }
    // Zero-sized panes are never applied.
    await #expect(throws: MuxError.self) {
      try await c.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: 99,
            generation: 7,
            entries: [.init(pane: pane, columns: 0, rows: 0)]
          )
        )
      )
    }
  }

  @Test
  func splitZoomAndEndPane() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    let first = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    guard
      case let .layout(after) = try await c.execute(
        .split(pane: first, axis: .topBottom, launch: shellLaunch())
      )
    else { return }
    let tab = after.tabs[0]
    #expect(tab.layout.panes.count == 2)
    #expect(tab.activePane != first)
    guard case let .layout(zoomed) = try await c.execute(.toggleZoom(tab.id))
    else { return }
    #expect(zoomed.tabs[0].zoomedPane == tab.activePane)
    guard
      case let .layout(ended) = try await c.execute(.endPane(tab.activePane))
    else { return }
    #expect(ended.tabs[0].layout == .pane(first))
    #expect(ended.tabs[0].zoomedPane == nil)
  }

  @Test
  func naturalExitDrainsFinalOutput() async throws {
    let h = try Harness()
    let c = try await h.connect()
    var spec = shellLaunch()
    spec.command = ["/bin/sh", "-c", "printf 'final-line\\n'; exit 3"]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: spec, remainOnExit: true))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    var status: Int32?
    var sawFinal = false
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline, status == nil || !sawFinal {
      switch try await c.nextEvent() {
      case let .frame(f)?: sawFinal = sawFinal || f.lines.contains("final-line")
      case let .paneExited(_, s, _)?: status = s
      default: break
      }
    }
    #expect(status == 3)
    #expect(sawFinal)
    _ = pane
  }

  @Test
  func launchFailureIsReported() async throws {
    let h = try Harness()
    let c = try await h.connect()
    var spec = shellLaunch()
    spec.command = ["/nonexistent/program"]
    do {
      try await c.execute(.newWorkspace(NewWorkspaceRequest(launch: spec)))
      Issue.record("launch should fail")
    } catch let e as MuxError { #expect(e.code == .launchFailed) }
    guard case let .workspaces(list) = try await c.execute(.listWorkspaces)
    else { return }
    #expect(list.isEmpty)
  }

  @Test
  func controllingTerminalAndJobControl() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    // tty is the slave; /dev/tty opens; the shell leads its session.
    try await c.send(
      .text(
        "tty | sed 's/^/tty=/'; (echo ok > /dev/tty) && echo devtty-ok; ps -o sess= -o pgid= -p $$ | awk '{print ($1==$2)?\"leader\":\"no\"}'\r"
      ),
      to: pane
    )
    let f = try await c.frame(of: pane) { f in
      f.lines.contains("leader") || f.lines.contains("no")
    }
    #expect(f.lines.contains { $0.hasPrefix("tty=/dev/ttys") })
    #expect(f.lines.contains("devtty-ok"))
    // Ctrl-C reaches the foreground job through the line discipline.
    try await c.send(.text("sleep 30\r"), to: pane)
    try await Task.sleep(for: .milliseconds(300))
    try await c.send(.key(.character(0x63), .control), to: pane)
    try await c.send(.text("echo interrupted-$?\r"), to: pane)
    let g = try await c.frame(of: pane) { f in
      f.lines.contains { $0.contains("interrupted-130") }
    }
    #expect(g.lines.contains { $0.contains("interrupted-130") })
  }

  @Test
  func bracketedPasteAndCancelOnDisconnect() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    // `cat -v` shows the envelope the program receives.
    try await c.send(.text("printf '\\033[?2004h'; cat -v\r"), to: pane)
    try await Task.sleep(for: .milliseconds(300))
    let state = try await c.paste("one\ntwo", to: pane)
    #expect(state == .completed)
    try await c.send(.text("\r"), to: pane)
    let f = try await c.frame(of: pane) { f in
      f.lines.contains { $0.contains("^[[201~") }
    }
    let text = f.lines.joined(separator: "\n")
    #expect(text.contains("^[[200~one"))
    #expect(text.contains("two^[[201~"))
  }

  @Test
  func historyScrollAndSearch() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id), columns: 40, rows: 10)
    try await c.send(
      .text("i=0; while [ $i -lt 60 ]; do echo row-$i; i=$((i+1)); done\r"),
      to: pane
    )
    _ = try await c.frame(of: pane) { $0.lines.contains("row-59") }
    guard
      case let .search(result) = try await c.execute(
        .search(pane: pane, query: "row-7")
      )
    else { return }
    #expect(result.matchCount >= 1)
    let found = try await c.frame(of: pane) { $0.lines.contains("row-7") }
    #expect(found.history.viewportOffset > 0)
    let address = found.history.address(viewportRow: 0, alternateScreen: false)
    try await c.execute(.scroll(pane: pane, .bottom))
    _ = try await c.frame(of: pane) { $0.history.viewportOffset == 0 }
    // A valid address scrolls back exactly.
    try await c.execute(.scroll(pane: pane, .top(address)))
    let back = try await c.frame(of: pane) {
      $0.history.viewportTop == address.row
    }
    #expect(back.lines == found.lines)
    // A stale generation is refused rather than reinterpreted.
    var stale = address
    stale.generation &+= 99
    do {
      try await c.execute(.scroll(pane: pane, .top(stale)))
      Issue.record("stale address accepted")
    } catch let e as MuxError { #expect(e.code == .historyUnavailable) }
  }

  @Test
  func incompatibleVersionIsRejected() async throws {
    let h = try Harness()
    await #expect(throws: MuxError.self) {
      _ = try await MuxConnection.connect(
        endpoint: h.endpoint,
        frontend: .terminal,
        terminalProfile: "some-other-terminal"
      )
    }
  }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LateSpawnTests {
  /// A split whose target pane ends while the new shell is starting: the
  /// successful late child is terminated and reaped, never attached.
  @Test
  func lateSpawnIntoEndedPaneIsReaped() async throws {
    let h = try Harness()
    let c = try await h.connect()
    var keep = shellLaunch()
    keep.command = ["/bin/sh", "-c", "exec sleep 60"]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: keep))
      )
    else { return }
    let target = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    // A second tab keeps the workspace alive after the target ends.
    try await c.execute(.newTab(name: "other", launch: keep))
    var slow = shellLaunch()
    slow.command = ["/bin/sh", "-c", "exec sleep 60"]
    // Ordered on one connection: the split is admitted, then the target
    // ends before the spawn completes.
    let split = Task {
      try await c.execute(.split(pane: target, axis: .leftRight, launch: slow))
    }
    c.enqueue(.endPane(target))
    do { _ = try await split.value } catch let e as MuxError {
      #expect(e.code == .notFound)
    }
    // Only the other tab's pane survives; the late child was reaped.
    var panes = -1
    for _ in 0 ..< 200 {
      guard case let .status(s) = try await c.execute(.status) else { return }
      panes = s.panes
      if panes == 1 { break }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(panes == 1)
    guard case let .workspaces(list) = try await c.execute(.listWorkspaces)
    else { return }
    #expect(list.first?.paneCount == 1)
  }
}

@Suite(.timeLimit(.minutes(1)))
struct PeerIdentityTests {
  /// A peer failing the code-signing requirement is never served, and the
  /// client fails its handshake instead of waiting forever.
  @Test
  func refusedPeerFailsFast() async throws {
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.peerRequirement = "identifier \"com.example.not-this-client\""
    let service = MuxService(configuration: config)
    let endpoint = service.listenAnonymously()
    let start = ContinuousClock.now
    await #expect(throws: MuxError.self) {
      _ = try await MuxConnection.connect(
        endpoint: endpoint,
        frontend: .control
      )
    }
    #expect(
      ContinuousClock.now - start < .seconds(MuxConnection.handshakeTimeout + 2)
    )
  }
}
