import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import Testing

/// Pieces of the native workspace UI that live below AppKit: title
/// sanitizing, minimum split sizes and hidden-pane activity.
struct WorkspaceUITests {
  @Test
  func titlesAreSanitizedAndBounded() {
    #expect(DisplayText.sanitize("vim  main.swift") == "vim main.swift")
    // Controls, line breaks and bidi overrides never reach the chrome.
    #expect(DisplayText.sanitize("a\u{1b}[31mb\nc\td") == "a[31mb c d")
    #expect(DisplayText.sanitize("evil\u{202E}txt.exe") == "eviltxt.exe")
    #expect(DisplayText.sanitize("\u{200B}  lead  ") == "lead")
    #expect(DisplayText.sanitize("🐍 snake") == "🐍 snake")
    let long = DisplayText.sanitize(String(repeating: "x", count: 500))
    #expect(long.count == DisplayText.maxTitleCharacters)
    #expect(long.hasSuffix("…"))
  }

  /// The reference composition: a left stack of two panes beside one
  /// tall pane.
  static func reference() -> (LayoutNode, [PaneID]) {
    let (a, b, c) = (PaneID(), PaneID(), PaneID())
    let tree = LayoutNode.split(
      axis: .leftRight,
      ratio: 0.54,
      first: .split(
        axis: .topBottom,
        ratio: 0.47,
        first: .pane(a),
        second: .pane(b)
      ),
      second: .pane(c)
    )
    return (tree, [a, b, c])
  }

  @Test
  func referenceLayoutGeometry() {
    let (tree, ids) = Self.reference()
    let area = LayoutRect(x: 0, y: 0, width: 1000, height: 600)
    let frames = LayoutGeometry.frames(tree, in: area, divider: 4)
    let (a, b, c) = (frames[ids[0]]!, frames[ids[1]]!, frames[ids[2]]!)
    #expect(a.x == 0 && b.x == 0 && a.width == b.width)
    #expect(a.maxY < b.y && b.maxY == 600)
    #expect(c.x > a.maxX && c.height == 600 && c.maxX == 1000)
    #expect(abs(Double(a.width) / 996 - 0.54) < 0.01)
    #expect(
      LayoutGeometry.neighbor(
        of: ids[1],
        direction: .right,
        frames: frames,
        order: tree.panes
      ) == ids[2]
    )
    #expect(
      LayoutGeometry.neighbor(
        of: ids[2],
        direction: .left,
        frames: frames,
        order: tree.panes
      ) == ids[0]  // ties go to the pane overlapping the centre line
        || LayoutGeometry.neighbor(
          of: ids[2],
          direction: .left,
          frames: frames,
          order: tree.panes
        ) == ids[1]
    )
  }

  @Test
  func dividerRatiosKeepMinimumPaneSizes() {
    let (tree, _) = Self.reference()
    let area = LayoutRect(x: 0, y: 0, width: 1000, height: 600)
    let minimum = (columns: 100, rows: 50)
    #expect(
      LayoutGeometry.minimumExtent(
        tree,
        axis: .leftRight,
        pane: 100,
        divider: 4
      ) == 204
    )
    #expect(
      LayoutGeometry.minimumExtent(tree, axis: .topBottom, pane: 50, divider: 4)
        == 104
    )
    // Dragging the outer divider to an edge stops at the minimum.
    let left = LayoutGeometry.clampedRatio(
      0.01,
      at: [],
      of: tree,
      in: area,
      minimum: minimum,
      divider: 4
    )
    #expect(abs(left - 100.0 / 996) < 0.001)
    let right = LayoutGeometry.clampedRatio(
      0.99,
      at: [],
      of: tree,
      in: area,
      minimum: minimum,
      divider: 4
    )
    #expect(abs(right - (1 - 100.0 / 996)) < 0.001)
    // The nested split is clamped within its own (left) area.
    let inner = LayoutGeometry.clampedRatio(
      0.99,
      at: [false],
      of: tree,
      in: area,
      minimum: minimum,
      divider: 4
    )
    #expect(abs(inner - (1 - 50.0 / 596)) < 0.001)
    // Free ratios pass through unchanged.
    #expect(
      LayoutGeometry.clampedRatio(
        0.4,
        at: [],
        of: tree,
        in: area,
        minimum: minimum,
        divider: 4
      ) == 0.4
    )
  }

  /// Output in a hidden tab is reported once, and again only after the
  /// pane has been shown.
  @Test(.timeLimit(.minutes(1)))
  func hiddenPaneActivityIsReportedOnce() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    let hidden = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    _ = try await c.frame(of: hidden) { $0.lines.first?.hasPrefix("$") == true }
    guard
      case let .layout(after) = try await c.execute(
        .newTab(name: nil, launch: shellLaunch())
      )
    else { return }
    let shown = try #require(after.activeTabSnapshot?.activePane)
    try await c.execute(.setSubscriptions([shown]))
    try await c.send(
      .text("echo h1; sleep 0.2; echo h2; sleep 0.2; echo h3\r"),
      to: hidden
    )
    try await Task.sleep(for: .seconds(1))
    // Events are ordered: count reports until the visible pane's marker.
    try await c.send(.text("echo sentinel-$((1+1))\r"), to: shown)
    var reports = 0
    while let event = try await c.nextEvent() {
      if case let .activity(pane) = event {
        #expect(pane == hidden)
        reports += 1
      }
      if case let .frame(frame) = event, frame.identity.pane == shown,
        frame.lines.contains("sentinel-2")
      {
        break
      }
    }
    #expect(reports == 1)
    // Showing the pane resets the report.
    try await c.execute(.setSubscriptions([shown, hidden]))
    try await c.execute(.setSubscriptions([shown]))
    try await c.send(.text("echo again\r"), to: hidden)
    var again = false
    while !again, let event = try await c.nextEvent() {
      if case let .activity(pane) = event { again = pane == hidden }
    }
    #expect(again)
  }
}
