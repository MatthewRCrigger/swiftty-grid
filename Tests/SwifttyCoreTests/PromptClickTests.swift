@testable import SwifttyCore
@testable import SwifttyEngine
import Testing

/// OSC 133 ; A `cl` and kitty `click_events` options (Ghostty's
/// `Terminal: OSC133A click_events` and `cl` checks).
struct PromptClickTests {
  @Test(arguments: [
    ("", PromptClick.none), (";aid=123", .none),
    (";click_events=1", .events(relative: false)),
    (";click_events=2", .events(relative: true)), (";click_events=0", .none),
    (";click_events=yes", .none), (";cl=line", .cursorKeys(.line)),
    (";cl=m", .cursorKeys(.multiple)),
    (";cl=v", .cursorKeys(.conservativeVertical)),
    (";cl=w", .cursorKeys(.smartVertical)), (";cl=invalid", .none),
    (";click_events=1;cl=m", .events(relative: false)),
    (";cl=m;click_events=2", .events(relative: true)),
    (";click_events=0;cl=v", .cursorKeys(.conservativeVertical)),
    (";aid=foo;cl=line", .cursorKeys(.line)),
  ])
  func `prompt start options select click handling`(
    _ options: String,
    _ expected: PromptClick
  ) {
    var vt = VT(20, 5)
    #expect(vt.state.promptClick == .none)
    vt.feed("\u{1B}]133;A\(options)\u{7}")
    #expect(vt.state.promptClick == expected)
  }

  @Test
  func
    `later prompts keep the setting unless they change it and reset clears it`()
  {
    var vt = VT(20, 5)
    vt.feed("\u{1B}]133;A;cl=m\u{7}$ \u{1B}]133;B\u{7}\r\n")
    vt.feed("\u{1B}]133;A\u{7}$ ")
    #expect(vt.state.promptClick == .cursorKeys(.multiple))
    vt.feed("\u{1B}]133;A;click_events=1\u{7}")
    #expect(vt.state.promptClick == .events(relative: false))
    vt.feed("\u{1B}]133;B\u{7}")
    #expect(vt.state.promptClick == .events(relative: false))
    vt.feed("\u{1B}c")
    #expect(vt.state.promptClick == .none)
  }

  @Test(arguments: [nil, ";cl=line", ";cl=m", ";cl=v", ";cl=w"])
  func `cursor-key settings move along the command line`(_ options: String?) {
    var vt = VT(20, 5)
    vt.feed("\u{1B}]133;A\(options ?? "")\u{7}$ \u{1B}]133;B\u{7}abcdef")
    vt.feed("\u{1B}[3D")
    let row = vt.state.absoluteRow(viewportRow: 0)
    #expect(
      vt.state.promptClickAction(at: TerminalPoint(row: row, column: 3))
        == .moves(-2)
    )
    #expect(ClickToMove.inputs(.moves(-2)).count == 2)
  }

  @Test(arguments: [false, true])
  func `click events report SGR presses at or below the prompt`(
    _ relative: Bool
  ) {
    var vt = VT(20, 5)
    vt.feed("one\r\ntwo\r\n")
    vt.feed(
      "\u{1B}]133;A;click_events=\(relative ? 2 : 1)\u{7}$ \u{1B}]133;B\u{7}ab"
    )
    let promptRow = vt.state.absoluteRow(viewportRow: 2)
    let below = TerminalPoint(row: promptRow + 1, column: 7)
    let expectedRow = relative ? 2 : 4
    #expect(
      vt.state.promptClickAction(at: below)
        == .report(Array("\u{1B}[<0;8;\(expectedRow)M".utf8))
    )
    #expect(
      vt.state.promptClickAction(at: TerminalPoint(row: promptRow, column: 0))
        == .report(Array("\u{1B}[<0;1;\(relative ? 1 : 3)M".utf8))
    )
    // Clicks above the prompt are not the shell's.
    #expect(
      vt.state.promptClickAction(
        at: TerminalPoint(row: promptRow - 1, column: 0)
      ) == nil
    )
    // Reports also apply while the prompt itself is drawn.
    vt.feed("\r\n\u{1B}]133;C\u{7}out\r\n\u{1B}]133;D;0\u{7}")
    #expect(vt.state.promptClickAction(at: below) == nil)
    vt.feed("\u{1B}]133;A\u{7}")
    let next = vt.state.absoluteRow(viewportRow: vt.cursor.y)
    #expect(
      vt.state.promptClickAction(at: TerminalPoint(row: next, column: 2)) != nil
    )
  }

  @Test
  func `click event reports become bytes`() {
    let bytes = Array("\u{1B}[<0;1;1M".utf8)
    guard case let .bytes(sent)? = ClickToMove.inputs(.report(bytes)).first
    else {
      Issue.record("expected raw bytes")
      return
    }
    #expect(sent == bytes)
  }
}
