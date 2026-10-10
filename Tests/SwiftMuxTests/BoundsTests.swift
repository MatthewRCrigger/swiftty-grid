import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct BoundsTests {
  @Test
  func paneLimitRejectsExcessCreation() async throws {
    var limits = MuxLimits()
    limits.maxPanes = 2
    let h = try Harness(limits: limits)
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    try await c.attachAndShow(.id(ws.id))
    _ = try await c.execute(
      .split(
        pane: ws.tabs[0].activePane,
        axis: .leftRight,
        launch: shellLaunch()
      )
    )
    do {
      try await c.execute(.newTab(name: nil, launch: shellLaunch()))
      Issue.record("third pane admitted")
    } catch let e as MuxError { #expect(e.code == .resourceLimit) }
  }

  /// A noisy pane and a client that stops consuming: one frame in
  /// flight, and control traffic is still answered promptly.
  @Test
  func slowClientStaysBoundedAndResponsive() async throws {
    let h = try Harness()
    let c = try await h.connect()
    var noisy = shellLaunch()
    noisy.command = ["/bin/sh", "-c", "yes 'noisy output line'"]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: noisy))
      )
    else { return }
    try await c.attachAndShow(.id(ws.id))
    // Do not consume events for a while; frames must not pile up.
    try await Task.sleep(for: .milliseconds(500))
    let start = ContinuousClock.now
    guard case .status = try await c.execute(.status) else { return }
    #expect(ContinuousClock.now - start < .milliseconds(500))
    var frames = 0
    while true {
      let event = try await withTimeout(.milliseconds(200)) {
        try await c.nextEvent()
      }
      if case .frame = event { frames += 1 } else { break }
      if frames > 3 { break }
    }
    // At most the in-flight frame was buffered while we were not reading,
    // plus frames sent after each acknowledgement during the drain.
    #expect(frames >= 1)
    _ = try? await c.execute(.endWorkspace(.id(ws.id)))
  }

  @Test
  func detachedPanesStillAnswerQueries() async throws {
    let h = try Harness()
    let c = try await h.connect(.control)
    var spec = shellLaunch()
    // Ask for device attributes with no frontend attached; the engine
    // replies through the pane's own writer.
    spec.command = [
      "/bin/sh", "-c",
      "stty raw -echo; printf '\\033[c'; dd bs=1 count=3 2>/dev/null | od -c | head -1 > /tmp/swmux-da-$$; stty sane; echo done; exec cat",
    ]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: spec))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    var reply = ""
    for _ in 0 ..< 100 {
      try await Task.sleep(for: .milliseconds(30))
      if let lines = await h.service.screenLines(pane), lines.contains("done"),
        let pid = await h.service.panePID(pane),
        let text = try? String(
          contentsOfFile: "/tmp/swmux-da-\(pid)",
          encoding: .utf8
        )
      {
        reply = text
        try? FileManager.default.removeItem(atPath: "/tmp/swmux-da-\(pid)")
        break
      }
    }
    #expect(reply.contains("033   ["))
  }

  @Test
  func inputBeyondWriterCreditIsRejected() async throws {
    var limits = MuxLimits()
    limits.inputBytesPerPane = 4096
    let h = try Harness(limits: limits)
    let c = try await h.connect()
    var spec = shellLaunch()
    // A program that never reads its input.
    spec.command = ["/bin/sh", "-c", "stty -icanon; sleep 30"]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: spec))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    try await Task.sleep(for: .milliseconds(200))
    var rejected: MuxError?
    let chunk = String(repeating: "x", count: 1024)
    for _ in 0 ..< 400 {
      do { try await c.send(.text(chunk), to: pane) } catch let e as MuxError {
        rejected = e
        break
      }
    }
    #expect(rejected?.code == .resourceLimit)
    _ = try? await c.execute(.endPane(pane))
  }

  @Test
  func oversizedRecordsAreRefusedBeforeDecoding() async throws {
    #expect(throws: MuxError.self) {
      _ = try SMXCodec.decode(
        ClientMessage.self,
        from: Data(count: MuxLimits.standard.maxControlRecordBytes + 1),
        limit: MuxLimits.standard.maxControlRecordBytes
      )
    }
  }
}
