import AppKit
import Foundation
import MetalKit
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
@testable import Swiftty
import SwifttyCore
import Testing

/// Drives the native SwiftMux window against an in-process service with
/// real shells: Metal presentation, semantic input, IME, frozen selection,
/// accessibility, splits, divider ratios and close-to-detach.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MuxNativeTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  static func launcher() throws -> String {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
      for config in ["debug", "out/Products/Debug", "release"] {
        let path = dir.appending(path: ".build/\(config)/swmux-launcher").path
        if FileManager.default.isExecutableFile(atPath: path) { return path }
      }
      dir = dir.deletingLastPathComponent()
    }
    throw MuxError(.notFound, "build swmux-launcher first (swift build)")
  }

  struct Fixture {
    let service: MuxService
    let endpoint: SMXEndpoint
    let controller: MuxWorkspaceController
    let workspace: WorkspaceID
  }

  func open() async throws -> Fixture {
    _ = NSApplication.shared
    let service = MuxService(
      configuration: MuxServiceConfiguration(launcherPath: try Self.launcher())
    )
    let endpoint = service.listenAnonymously()
    let connection = try await MuxConnection.connect(
      endpoint: endpoint,
      frontend: .native
    )
    let launch = LaunchSpec(
      command: ["/bin/sh"],
      workingDirectory: "/tmp",
      environment: [
        "PATH": "/usr/bin:/bin", "PS1": "$ ", "HOME": NSTemporaryDirectory(),
      ]
    )
    guard
      case let .created(ws) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    else { throw MuxError(.invalidRequest) }
    let controller = try await MuxWorkspaceController.open(
      .id(ws.id),
      configuration: Configuration(),
      connection: connection
    )
    controller.window?.isReleasedWhenClosed = false
    controller.showWindow(nil)
    return Fixture(
      service: service,
      endpoint: endpoint,
      controller: controller,
      workspace: ws.id
    )
  }

  /// Draws (the display link is not running in tests) until `predicate`
  /// holds for the presentation the renderer accepted.
  func waitPresented(
    _ view: MuxPaneView,
    _ predicate: (PaneFrame) -> Bool
  ) async -> PaneFrame? {
    for _ in 0 ..< 300 {
      view.draw(in: view)
      if let frame = view.presented?.frame, predicate(frame) { return frame }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
  }

  func activeView(_ c: MuxWorkspaceController) -> MuxPaneView? {
    c.activePane.flatMap { c.views[$0] }
  }

  @Test(.enabled(if: hasMetal))
  func `frames render through Metal and drive accessibility`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let view = try #require(activeView(f.controller))
    f.controller.send(.text("echo native-$((2+3))\r"), to: view.pane)
    let frame = await waitPresented(view) { $0.lines.contains("native-5") }
    #expect(frame != nil)
    #expect(
      (view.accessibilityValue() as? String)?.contains("native-5") == true
    )
  }

  @Test(.enabled(if: hasMetal))
  func `committed IME text is sent once and compositions never leak`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let view = try #require(activeView(f.controller))
    _ = await waitPresented(view) { $0.lines.first?.hasPrefix("$") == true }
    let none = NSRange(location: NSNotFound, length: 0)
    // A composition stays local and is discarded on rebind.
    view.setMarkedText(
      "にほ",
      selectedRange: NSRange(location: 2, length: 0),
      replacementRange: none
    )
    #expect(view.hasMarkedText())
    view.cancelComposition()
    #expect(!view.hasMarkedText())
    // A committed composition reaches the shell exactly once.
    f.controller.send(.text("echo "), to: view.pane)
    view.setMarkedText(
      "にほん",
      selectedRange: NSRange(location: 3, length: 0),
      replacementRange: none
    )
    view.insertText("日本", replacementRange: none)
    f.controller.send(.key(.enter, []), to: view.pane)
    let frame = await waitPresented(view) { $0.lines.contains("日本") }
    let lines = try #require(frame?.lines)
    #expect(lines.contains("$ echo 日本"))
    #expect(!lines.joined().contains("にほ"))
    #expect(lines.filter { $0 == "日本" }.count == 1)
  }

  @Test(.enabled(if: hasMetal))
  func `word selection freezes the presented frame`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let view = try #require(activeView(f.controller))
    f.controller.send(.text("echo pick-me\r"), to: view.pane)
    let frame = try #require(
      await waitPresented(view) { $0.lines.contains("pick-me") }
    )
    let row = try #require(frame.lines.firstIndex(of: "pick-me"))
    let scale = view.window?.backingScaleFactor ?? 2
    let point = NSPoint(
      x: (view.renderer.options.paddingX + 2.5 * view.renderer.cellSize.width)
        / scale,
      y: view.bounds.height
        - (view.renderer.options.paddingY + (CGFloat(row) + 0.5)
          * view.renderer.cellSize.height)
        / scale
    )
    let location = view.convert(point, to: nil)
    let down = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 0,
        clickCount: 2,
        pressure: 1
      )
    )
    view.mouseDown(with: down)
    #expect(view.accessibilitySelectedText() == "pick-me")
    // New output does not change the frozen selection or its text.
    f.controller.send(.text("clear; echo replaced\r"), to: view.pane)
    try await Task.sleep(for: .milliseconds(300))
    view.draw(in: view)
    #expect(view.accessibilitySelectedText() == "pick-me")
    #expect(
      (view.accessibilityValue() as? String)?.contains("replaced") == false
    )
    view.clearSelection()
    #expect(await waitPresented(view) { $0.lines.contains("replaced") } != nil)
  }

  @Test(.enabled(if: hasMetal))
  func `splits, divider ratios and close detach keep the shell`() async throws {
    let f = try await open()
    let c = f.controller
    let first = try #require(c.activePane)
    let firstView = try #require(c.views[first])
    let full = try #require(await waitPresented(firstView) { _ in true })
    c.split(.leftRight)
    var second: PaneID?
    for _ in 0 ..< 200 where second == nil {
      if c.views.count == 2 { second = c.views.keys.first { $0 != first } }
      try await Task.sleep(for: .milliseconds(20))
    }
    let other = try #require(second)
    let otherView = try #require(c.views[other])
    // Geometry follows the native layout: both halves are narrower.
    let left = try #require(
      await waitPresented(firstView) { $0.grid.columns < full.grid.columns }
    )
    let right = try #require(
      await waitPresented(otherView) { $0.grid.columns < full.grid.columns }
    )
    #expect(abs(left.grid.columns - right.grid.columns) <= 2)
    // A divider ratio change resizes the panes.
    c.setRatio(0.25, path: [])
    let narrowed = await waitPresented(firstView) {
      $0.grid.columns < left.grid.columns - 4
    }
    #expect(narrowed != nil)
    // Closing the window only detaches; the workspace and shells remain.
    let pid = await f.service.panePID(first)
    c.close()
    let control = try await MuxConnection.connect(
      endpoint: f.endpoint,
      frontend: .control
    )
    var attached = true
    for _ in 0 ..< 100 where attached {
      if case let .status(s) = try await control.execute(.status) {
        attached = s.attached
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!attached)
    guard
      case let .workspaces(list) = try await control.execute(.listWorkspaces)
    else { return }
    #expect(list.first?.paneCount == 2)
    #expect(await f.service.panePID(first) == pid)
  }
}
