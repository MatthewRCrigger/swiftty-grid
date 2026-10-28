#if os(macOS)
import ScreenProtocol
import SessionCore
import SwifttyCore
@testable import TerminalHost
import Testing

/// History windows exported for one RST/1 attachment (`historyViewport`).
struct ScreenExporterHistoryTests {
  let session = SessionID(bytes: Array(repeating: 7, count: 16))!

  func terminal() -> TerminalSession {
    let terminal = TerminalSession(columns: 20, rows: 4)
    var text = ""
    for i in 0 ..< 50 { text += "line-\(i)\r\n" }
    text += "prompt$ "
    terminal.feed(Array(text.utf8))
    return terminal
  }

  @Test
  func `windows clamp to history and return to live output`() {
    let t = terminal()
    t.withState { state in
      let first = state.firstAbsoluteRow
      let live = first + state.scrollbackCount
      #expect(ScreenExporter.historyTop(state, from: nil, moving: 0) == nil)
      #expect(
        ScreenExporter.historyTop(state, from: nil, moving: 5) == live - 5
      )
      #expect(
        ScreenExporter.historyTop(state, from: live - 5, moving: -5) == nil
      )
      #expect(
        ScreenExporter.historyTop(state, from: live - 5, moving: -99) == nil
      )
      #expect(
        ScreenExporter.historyTop(state, from: nil, moving: 10_000) == first
      )
      #expect(
        ScreenExporter.historyTop(state, from: nil, moving: .max) == first
      )
      #expect(ScreenExporter.historyTop(state, from: nil, moving: .min) == nil)
    }
  }

  @Test
  func `a window shows history without moving the terminal's viewport`() throws
  {
    let t = terminal()
    let (live, window, offset) = t.withState { state in
      let top = ScreenExporter.historyTop(state, from: nil, moving: 10)
      return (
        ScreenExporter.export(state, stamp: .init(sessionID: session)),
        ScreenExporter.export(
          state,
          stamp: .init(sessionID: session),
          historyTop: top
        ), state.viewportOffset
      )
    }
    try window.validate()
    #expect(offset == 0)
    #expect(live.textLines.last?.hasPrefix("prompt$") == true)
    #expect(live.cursor.visible)
    // Ten lines back from the live screen: line-37 … line-40.
    #expect(window.textLines == ["line-37", "line-38", "line-39", "line-40"])
    #expect(!window.cursor.visible)
    let decoded = try SnapshotFrame.decode(SnapshotFrame.encode(window))
    #expect(decoded == window)
  }

  @Test
  func `the alternate screen has no history window`() {
    let t = terminal()
    t.feed(Array("\u{1B}[?1049h\u{1B}[HALT".utf8))
    t.withState { state in
      #expect(ScreenExporter.historyTop(state, from: nil, moving: 5) == nil)
      let shot = ScreenExporter.export(
        state,
        stamp: .init(sessionID: session),
        historyTop: 3
      )
      #expect(shot.textLines.first == "ALT")
    }
  }
}
#endif
