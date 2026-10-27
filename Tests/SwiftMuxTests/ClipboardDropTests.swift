import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

/// Kitty clipboard (OSC 5522) requests and drag-and-drop (OSC 72) across
/// the service: the controller answers, and programs see the replies.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ClipboardDropTests {
  private func nextClipboardEvent(_ c: MuxConnection) async throws -> MuxEvent {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      guard let event = try await c.nextEvent(timeout: .seconds(1)) else {
        continue
      }
      switch event {
      case .clipboardRead, .clipboardWrite: return event
      default: continue
      }
    }
    throw MuxError(.notFound, "no clipboard event")
  }

  private func create(
    _ c: MuxConnection,
    _ script: String
  ) async throws -> PaneID {
    var launch = shellLaunch()
    launch.command = ["/bin/sh", "-c", script]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      )
    else { throw MuxError(.invalidRequest, "create") }
    try await c.attachAndShow(.id(ws.id), columns: 200)
    return ws.tabs[0].activePane
  }

  /// Requests text/plain, then echoes the reply it reads.
  private static let reader = """
    stty raw -echo; printf '\\033]5522;type=read:id=r1;dGV4dC9wbGFpbg==\\007'; \
    exec cat -v
    """

  @Test
  func `controllers answer reads and programs receive the data`() async throws {
    let h = try Harness()
    let c = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: ClientCapabilities.supported.union(.clipboardRequests)
    )
    #expect(await c.welcome?.features.contains(.kittyClipboard) == true)
    let pane = try await create(c, Self.reader)
    guard case let .clipboardRead(request) = try await nextClipboardEvent(c)
    else { return }
    #expect(request.pane == pane)
    #expect(request.mimes == ["text/plain"])
    #expect(!request.granted)
    try await c.execute(
      .clipboardReadResult(
        pane: pane,
        token: request.token,
        .success(
          available: ["text/plain"],
          contents: [
            MuxClipboardContent(mime: "text/plain", data: Data("Ghostty".utf8))
          ],
          remember: false
        )
      )
    )
    _ = try await c.frame(of: pane, label: "reply") {
      $0.lines.joined()
        .contains(
          "type=read:status=DATA:id=r1:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ=="
        )
    }
  }

  @Test
  func `reads are denied without a controller that answers`() async throws {
    let h = try Harness()
    let c = try await h.connect()
    let pane = try await create(c, Self.reader)
    _ = try await c.frame(of: pane, label: "denial") {
      $0.lines.joined().contains("type=read:status=EPERM:id=r1")
    }
  }

  @Test
  func `controllers answer writes`() async throws {
    let h = try Harness()
    let c = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: ClientCapabilities.supported.union(.clipboardRequests)
    )
    let pane = try await create(
      c,
      """
      stty raw -echo; printf '\\033]5522;type=write:id=w\\007\
      \\033]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\\007\
      \\033]5522;type=wdata\\007'; exec cat -v
      """
    )
    guard case let .clipboardWrite(request) = try await nextClipboardEvent(c)
    else { return }
    #expect(
      request.contents == [
        MuxClipboardContent(mime: "text/plain", data: Data("Ghost".utf8))
      ]
    )
    try await c.execute(
      .clipboardWriteResult(pane: pane, token: request.token, .denied)
    )
    _ = try await c.frame(of: pane, label: "write reply") {
      $0.lines.joined().contains("type=write:status=EPERM:id=w")
    }
  }

  @Test
  func `paste events and drops reach registered programs`() async throws {
    let h = try Harness()
    let c = try await MuxConnection.connect(
      endpoint: h.endpoint,
      frontend: .native,
      capabilities: ClientCapabilities.supported.union(.clipboardRequests)
    )
    #expect(await c.welcome?.features.contains(.dropTargets) == true)
    let pane = try await create(
      c,
      """
      stty raw -echo; printf '\\033[?5522h\\033]72;t=a;text/plain\\007READY'; \
      exec cat -v
      """
    )
    let registered = try await c.frame(of: pane, label: "registered") {
      $0.dropTarget?.types == ["text/plain"]
        && $0.modes.contains(.kittyPasteEvents)
    }
    #expect(registered.dropTarget?.accepted == nil)
    try await c.send(.clipboardPaste(types: ["text/plain"]), to: pane)
    _ = try await c.frame(of: pane, label: "paste event") {
      $0.lines.joined().contains("type=read:status=OK:pw=")
    }
    let position = MuxDragPosition(
      column: 2,
      row: 1,
      pixelX: 20,
      pixelY: 18,
      allowsCopy: true,
      allowsMove: false
    )
    try await c.send(
      .drag(
        .drop(
          position,
          items: [
            MuxClipboardContent(mime: "text/plain", data: Data("hi".utf8))
          ]
        )
      ),
      to: pane
    )
    _ = try await c.frame(of: pane, label: "drop") {
      $0.lines.joined().contains("t=M:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain ")
    }
  }

  @Test
  func `oversized clipboard input is refused`() async throws {
    let types = (0 ..< 17).map { "a/\($0)" }
    #expect(!MuxService.clipboardInputIsBounded(.clipboardPaste(types: types)))
    #expect(
      MuxService.clipboardInputIsBounded(.clipboardPaste(types: ["text/plain"]))
    )
    #expect(
      !MuxService.clipboardInputIsBounded(
        .drag(
          .move(
            MuxDragPosition(
              column: 0,
              row: 0,
              pixelX: 0,
              pixelY: 0,
              allowsCopy: true,
              allowsMove: true
            ),
            types: [""]
          )
        )
      )
    )
    #expect(
      PaneRuntime.replyFits(
        [MuxClipboardContent(mime: "text/plain", data: Data(count: 1000))],
        reserve: 64 << 10
      )
    )
    #expect(
      !PaneRuntime.replyFits(
        [MuxClipboardContent(mime: "text/plain", data: Data(count: 60 << 10))],
        reserve: 64 << 10
      )
    )
  }
}
