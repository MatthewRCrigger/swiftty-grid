import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import SwifttyEngine
import Testing

@Suite
struct EngineIdentityTests {
  func replies(
    _ input: String,
    configure: (inout TerminalState) -> Void
  ) -> String {
    var state = TerminalState(columns: 20, rows: 4)
    configure(&state)
    var parser = Parser()
    parser.consume(Array(input.utf8).span, into: &state)
    return String(decoding: state.output, as: UTF8.self)
  }

  @Test
  func identityFollowsConfiguration() {
    let out = replies("\u{1B}[>q\u{1B}P+q544e\u{1B}\\") {
      $0.terminalVersion = "swmux 0.2"
      $0.terminfoName = "swmux-256color"
    }
    #expect(out.contains("\u{1B}P>|swmux 0.2\u{1B}\\"))
    // XTGETTCAP TN = hex("swmux-256color")
    let hex = "swmux-256color".utf8.map { String(format: "%02X", $0) }.joined()
    #expect(out.uppercased().contains(hex))
  }

  @Test
  func disabledKeyboardProtocolIsNotOffered() {
    let off = replies("\u{1B}[>1u\u{1B}[?u") {
      $0.keyboardProtocolEnabled = false
    }
    #expect(off.isEmpty)
    let on = replies("\u{1B}[>1u\u{1B}[?u") { _ in }
    #expect(on == "\u{1B}[?1u")
  }

  @Test
  func clipboardCapabilityCanBeWithheld() {
    let hexMs = "Ms".utf8.map { String(format: "%02x", $0) }.joined()
    let off = replies("\u{1B}P+q\(hexMs)\u{1B}\\") {
      $0.clipboardWritesAdvertised = false
    }
    #expect(off.hasPrefix("\u{1B}P0+r"))
  }
}

/// Reads a terminal reply inside the pane: raw mode, send the query, read
/// until `terminator`, print it escaped.
func probe(_ query: String, until terminator: String) -> LaunchSpec {
  var spec = shellLaunch()
  spec.command = [
    "/bin/bash", "-c",
    "stty raw -echo; printf '\(query)'; IFS= read -r -s -d \(terminator) -t 5 r; stty sane; printf 'reply=%q\\n' \"$r\"; exec cat",
  ]
  return spec
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct InnerProfileTests {
  func reply(
    _ h: Harness,
    _ c: MuxConnection,
    _ spec: LaunchSpec
  ) async throws -> String {
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: spec))
      )
    else { return "" }
    let pane = ws.tabs[0].activePane
    for _ in 0 ..< 200 {
      if let line = await h.service.screenLines(pane)?
        .first(where: { $0.hasPrefix("reply=") })
      {
        return line
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    return ""
  }

  @Test
  func programsSeeOneConsistentIdentity() async throws {
    let h = try Harness()
    let c = try await h.connect(.control)
    let version = try await reply(h, c, probe("\\033[>q", until: "'\\\\'"))
    #expect(version.contains("swmux"))
    #expect(!version.contains("swiftty"))
    // The kitty query gets no reply; the DA1 that follows does.
    let kitty = try await reply(h, c, probe("\\033[?u\\033[c", until: "c"))
    #expect(!kitty.contains("u"))
    #expect(kitty.contains("?"))
  }

  @Test
  func themeUpdatesReportedDefaultColours() async throws {
    let h = try Harness()
    let c = try await h.connect(.control)
    var colors = [UInt32](repeating: 0, count: 256)
    colors[1] = 0xAB_CD_EF
    try await c.execute(
      .setTheme(
        MuxTheme(
          palette: FramePalette(
            colors: colors,
            foreground: 0xEE_EE_EE,
            background: 0x12_34_56,
            cursor: 0xFF_FFFF
          ),
          dark: true
        )
      )
    )
    let bg = try await reply(h, c, probe("\\033]11;?\\007", until: "$'\\a'"))
    #expect(bg.contains("1212/3434/5656"))
  }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct BarrierAndTruncationTests {
  @Test
  func barrierRefusesMutationsButAllowsStatusAndEnding() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(name: "b", launch: shellLaunch()))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    try await c.execute(.quiesce(true))
    for command: MuxCommand in [
      .renameWorkspace(.id(ws.id), name: "x"),
      .split(pane: pane, axis: .leftRight, launch: nil),
      .newTab(name: nil, launch: nil), .renameTab(ws.tabs[0].id, name: "t"),
      .toggleZoom(ws.tabs[0].id),
    ] {
      do {
        try await c.execute(command)
        Issue.record("admitted at barrier: \(command)")
      } catch let e as MuxError { #expect(e.code == .quiescing) }
    }
    guard case .status = try await c.execute(.status) else { return }
    try await c.execute(.endPane(pane))
  }

  @Test
  func forcedTerminationIsReportedAsTruncated() async throws {
    let h = try Harness()
    let c = try await h.connect()
    var stubborn = shellLaunch()
    stubborn.command = [
      "/bin/sh", "-c", "trap '' HUP; while :; do sleep 1; done",
    ]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: stubborn))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    try await Task.sleep(for: .milliseconds(200))
    // A second tab keeps the workspace (and the attachment) alive.
    try await c.execute(.newTab(name: nil, launch: shellLaunch()))
    try await c.execute(.endPane(pane))
    var truncated: Bool?
    let deadline = ContinuousClock.now + .seconds(8)
    while truncated == nil, ContinuousClock.now < deadline {
      if case let .paneExited(id, _, t)? = try await c.nextEvent(), id == pane {
        truncated = t
      }
    }
    #expect(truncated == true)
  }
}
