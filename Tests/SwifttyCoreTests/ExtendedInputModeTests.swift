@testable import SwifttyCore
@testable import SwifttyEngine
import Testing

/// DECBKM, modifyOtherKeys, the numeric keypad, lock modifiers and the
/// URXVT/SGR-pixel mouse formats, checked against Ghostty's encoder tests.
struct ExtendedInputModeTests {
  private func encode(
    _ input: TerminalInput,
    modes: Modes = .initial,
    flags: UInt8 = 0
  ) -> String? {
    var out: [UInt8] = []
    guard
      InputEncoder.encode(input, modes: modes, keyboardFlags: flags, into: &out)
    else { return nil }
    return String(decoding: out, as: UTF8.self)
  }

  private func key(
    _ key: Key,
    _ modifiers: KeyModifiers = [],
    text: String? = nil,
    modes: Modes = .initial,
    flags: UInt8 = 0
  ) -> String? {
    encode(
      .key(KeyEvent(key, modifiers: modifiers, text: text)),
      modes: modes,
      flags: flags
    )
  }

  // MARK: DECBKM

  @Test
  func `DECBKM swaps backspace and ctrl backspace`() {
    let bkm = Modes.initial.union(.backarrowKey)
    #expect(key(.backspace) == "\u{7F}")
    #expect(key(.backspace, .control) == "\u{08}")
    #expect(key(.backspace, modes: bkm) == "\u{08}")
    #expect(key(.backspace, .control, modes: bkm) == "\u{7F}")
    #expect(key(.backspace, .alt, modes: bkm) == "\u{1B}\u{08}")
  }

  @Test
  func `mode 67 sets resets and reports DECBKM`() {
    var vt = VT()
    vt.feed("\u{1B}[?67$p")
    #expect(vt.takeOutput() == "\u{1B}[?67;2$y")
    vt.feed("\u{1B}[?67h\u{1B}[?67$p")
    #expect(vt.state.modes.contains(.backarrowKey))
    #expect(vt.takeOutput() == "\u{1B}[?67;1$y")
    vt.feed("\u{1B}c")
    #expect(!vt.state.modes.contains(.backarrowKey))
  }

  // MARK: modifyOtherKeys

  @Test
  func `modifyOtherKeys state 2 encodes modified characters`() {
    let m = Modes.initial.union(.modifyOtherKeys)
    #expect(key(.character("p"), .control, modes: m) == "\u{1B}[27;5;112~")
    #expect(key(.character("p"), .control) == "\u{10}")
    #expect(
      key(.character("h"), [.control, .shift], text: "H", modes: m)
        == "\u{1B}[27;6;72~"
    )
    #expect(
      key(.character("8"), .alt, text: "8", modes: m) == "\u{1B}[27;3;56~"
    )
    #expect(
      key(.character(" "), .shift, text: " ", modes: m) == "\u{1B}[27;2;32~"
    )
    // Shift alone still types its text.
    #expect(key(.character("a"), .shift, text: "A", modes: m) == "A")
    #expect(key(.character("a"), text: "a", modes: m) == "a")
    // Command never selects an encoding.
    #expect(
      key(.character("p"), [.control, .command], modes: m) == "\u{1B}[27;5;112~"
    )
  }

  @Test
  func `modifyOtherKeys state 2 encodes modified control keys`() {
    let m = Modes.initial.union(.modifyOtherKeys)
    #expect(key(.enter, .shift, modes: m) == "\u{1B}[27;2;13~")
    #expect(key(.enter, .control, modes: m) == "\u{1B}[27;5;13~")
    #expect(key(.escape, .alt, modes: m) == "\u{1B}[27;3;27~")
    #expect(key(.tab, .alt, modes: m) == "\u{1B}[27;3;9~")
    #expect(key(.tab, .control, modes: m) == "\u{1B}[27;5;9~")
    #expect(key(.tab, .shift, modes: m) == "\u{1B}[Z")
    #expect(
      key(.backspace, [.control, .alt, .shift], modes: m) == "\u{1B}[27;8;127~"
    )
    #expect(key(.backspace, .control, modes: m) == "\u{08}")
    #expect(key(.enter, modes: m) == "\r")
    // Function keys keep their PC-style encodings.
    #expect(key(.up, .control, modes: m) == "\u{1B}[1;5A")
    #expect(key(.delete, .control, modes: m) == "\u{1B}[3;5~")
  }

  // Arguments omit ESC so test output stays free of terminal controls.
  @Test(arguments: [
    ("[>4;2m", true), ("[>4;1m", false), ("[>4m", false), ("[>m", false),
    ("[>1m", false), ("[>3m", true), ("[>4;2;1m", true),
  ])
  func `XTMODKEYS enables only state 2 and ignores invalid requests`(
    _ request: String,
    _ enabled: Bool
  ) {
    var vt = VT()
    vt.feed("\u{1B}[>4;2m")
    #expect(vt.state.modes.contains(.modifyOtherKeys))
    vt.feed("\u{1B}" + request)
    #expect(vt.state.modes.contains(.modifyOtherKeys) == enabled)
    vt.feed("\u{1B}c")
    #expect(!vt.state.modes.contains(.modifyOtherKeys))
  }

  // MARK: Keypad

  @Test
  func `numeric keypad types digits unless the application keypad applies`() {
    let app = Modes.initial.union(.keypadApplication)
      .subtracting(.ignoreKeypadWithNumLock)
    #expect(key(.keypad(.one), text: "1") == "1")
    #expect(key(.keypad(.one)) == "1")
    #expect(key(.keypad(.enter)) == "\r")
    #expect(key(.keypad(.one), modes: app) == "\u{1B}Oq")
    #expect(key(.keypad(.one), .numLock, modes: app) == "\u{1B}Oq")
    #expect(key(.keypad(.one), .control, modes: app) == "\u{1B}O5q")
    #expect(key(.keypad(.enter), modes: app) == "\u{1B}OM")
    #expect(key(.keypad(.add), modes: app) == "\u{1B}Ok")
    // Mode 1035 (on by default) keeps DECKPAM keys numeric.
    let ignored = Modes.initial.union(.keypadApplication)
    #expect(key(.keypad(.one), modes: ignored) == "1")
    // Navigation keys follow the cursor keys.
    #expect(key(.keypad(.end)) == "\u{1B}[F")
    #expect(key(.keypad(.end), modes: app.union(.cursorKeys)) == "\u{1B}OF")
    #expect(key(.keypad(.begin)) == "\u{1B}[E")
    #expect(key(.keypad(.begin), .shift) == "\u{1B}[1;2E")
    #expect(key(.keypad(.pageUp)) == "\u{1B}[5~")
  }

  @Test
  func `modifyOtherKeys leaves numeric keypad text alone`() {
    let m = Modes.initial.union(.modifyOtherKeys)
    #expect(key(.keypad(.one), .control, text: "1", modes: m) == "1")
    let app = m.union(.keypadApplication).subtracting(.ignoreKeypadWithNumLock)
    #expect(key(.keypad(.one), .control, text: "1", modes: app) == "\u{1B}O5q")
  }

  @Test
  func `keypad modes are set by DECKPAM DECNKM and mode 1035`() {
    var vt = VT()
    #expect(vt.state.modes.contains(.ignoreKeypadWithNumLock))
    vt.feed("\u{1B}=")
    #expect(vt.state.modes.contains(.keypadApplication))
    vt.feed("\u{1B}[?66l")
    #expect(!vt.state.modes.contains(.keypadApplication))
    vt.feed("\u{1B}[?66h\u{1B}[?1035l")
    #expect(vt.state.modes.contains(.keypadApplication))
    #expect(!vt.state.modes.contains(.ignoreKeypadWithNumLock))
    vt.feed("\u{1B}[?66$p\u{1B}[?1035$p")
    #expect(vt.takeOutput() == "\u{1B}[?66;1$y\u{1B}[?1035;2$y")
    vt.feed("\u{1B}c")
    #expect(vt.state.modes.contains(.ignoreKeypadWithNumLock))
    #expect(!vt.state.modes.contains(.keypadApplication))
  }

  @Test
  func `kitty reports keypad keys by their functional codes`() {
    #expect(
      key(.keypad(.one), text: "1", flags: 0b11111) == "\u{1B}[57400;1;49u"
    )
    #expect(key(.keypad(.one), text: "1", flags: 1) == "1")
    #expect(key(.keypad(.one), .control, flags: 1) == "\u{1B}[57400;5u")
    #expect(key(.keypad(.enter), flags: 1) == "\u{1B}[57414u")
    #expect(key(.keypad(.begin), flags: 1) == "\u{1B}[57427u")
    #expect(key(.keypad(.one), .numLock, flags: 8) == "\u{1B}[57400;129u")
  }

  // MARK: Lock modifiers

  @Test
  func `kitty reports caps lock without blocking text`() {
    let caps = KeyModifiers.capsLock
    let all: UInt8 = 0b11111
    #expect(
      encode(
        .key(KeyEvent(.character("j"), modifiers: caps, text: "J")),
        flags: all
      ) == "\u{1B}[106;65;74u"
    )
    #expect(key(.character("j"), caps, text: "J", flags: 1) == "J")
    #expect(key(.enter, caps, flags: 1) == "\r")
    #expect(key(.up, caps, flags: 1) == "\u{1B}[1;65A")
    #expect(
      key(.character("c"), [.control, .capsLock], flags: 1) == "\u{1B}[99;69u"
    )
  }

  @Test
  func `legacy encodings ignore lock modifiers`() {
    #expect(key(.up, .capsLock) == "\u{1B}[A")
    #expect(key(.character("c"), [.control, .capsLock]) == "\u{03}")
    #expect(key(.function(5), [.numLock]) == "\u{1B}[15~")
    #expect(key(.enter, .capsLock) == "\r")
  }

  @Test
  func `bindings ignore lock modifiers and match keypad keys as typed`() {
    #expect(
      KeyTrigger(.character("a"), modifiers: [.control, .capsLock])
        == KeyTrigger(.character("a"), modifiers: .control)
    )
    #expect(KeyTrigger(.keypad(.enter)) == KeyTrigger(.enter))
    #expect(KeyTrigger(.keypad(.one)) == KeyTrigger(.character("1")))
  }

  // MARK: Mouse formats

  private func mouse(
    _ action: MouseEvent.Action,
    _ button: MouseEvent.Button,
    format: Modes,
    modifiers: KeyModifiers = [],
    pixel: (Int, Int)? = nil
  ) -> String? {
    encode(
      .mouse(
        MouseEvent(
          action,
          button,
          column: 4,
          row: 2,
          modifiers: modifiers,
          pixelX: pixel?.0,
          pixelY: pixel?.1
        )
      ),
      modes: [.mouseAny, format]
    )
  }

  @Test
  func `URXVT reports decimal coordinates with legacy releases`() {
    #expect(
      mouse(.press, .left, format: .mouseURXVT, modifiers: .shift)
        == "\u{1B}[36;5;3M"
    )
    #expect(mouse(.release, .right, format: .mouseURXVT) == "\u{1B}[35;5;3M")
    #expect(mouse(.motion, .none, format: .mouseURXVT) == "\u{1B}[67;5;3M")
    var out: [UInt8] = []
    InputEncoder.encode(
      .mouse(MouseEvent(.press, .left, column: 300, row: 400)),
      modes: [.mouseNormal, .mouseURXVT],
      into: &out
    )
    #expect(String(decoding: out, as: UTF8.self) == "\u{1B}[32;301;401M")
  }

  @Test
  func `SGR pixels reports terminal-space pixels and keeps release buttons`() {
    #expect(
      mouse(.press, .left, format: .mouseSGRPixels, pixel: (10, 20))
        == "\u{1B}[<0;10;20M"
    )
    #expect(
      mouse(.release, .right, format: .mouseSGRPixels, pixel: (10, 20))
        == "\u{1B}[<2;10;20m"
    )
    #expect(
      mouse(.motion, .none, format: .mouseSGRPixels, pixel: (-3, 7))
        == "\u{1B}[<35;-3;7M"
    )
    #expect(mouse(.press, .left, format: .mouseSGRPixels) == nil)
  }

  @Test
  func `mouse formats are exclusive and any reset returns to X10`() {
    var vt = VT()
    vt.feed("\u{1B}[?1006h\u{1B}[?1015h")
    #expect(vt.state.modes.intersection(Modes.mouseFormats) == .mouseURXVT)
    vt.feed("\u{1B}[?1016h")
    #expect(vt.state.modes.intersection(Modes.mouseFormats) == .mouseSGRPixels)
    vt.feed("\u{1B}[?1015$p\u{1B}[?1016$p")
    #expect(vt.takeOutput() == "\u{1B}[?1015;2$y\u{1B}[?1016;1$y")
    vt.feed("\u{1B}[?1005l")
    #expect(vt.state.modes.isDisjoint(with: Modes.mouseFormats))
  }
}
