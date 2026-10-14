import Foundation
import SwiftMuxBridge
import SwiftMuxProtocol
import SwifttyCore
import Testing

struct BridgeTests {
  @Test
  func exportRejectsStyleIndexOverflowEvenWithUncheckedLimits() throws {
    var screen = Self.session().withState { $0.captureOwnedScreen() }
    screen.columns = 256
    screen.rows = 257
    screen.wrapped = Array(repeating: false, count: screen.rows)
    let cell = screen.cells[0]
    screen.cells = (0 ..< screen.columns * screen.rows)
      .map { index in
        var cell = cell
        cell.attributes.foreground.rawValue = 0x0200_0000 | UInt32(index)
        return cell
      }
    var limits = MuxLimits.standard
    limits.maxRows = screen.rows
    limits.maxStyles = Int.max
    #expect(throws: MuxError.self) {
      try FrameExporter.frame(
        from: screen,
        identity: Self.identity(),
        limits: limits
      )
    }
  }

  static let server = ServerInstanceID()
  static let attachment = AttachmentID()
  static let pane = PaneID()

  static func identity() -> FrameIdentity {
    FrameIdentity(
      server: server,
      attachment: attachment,
      pane: pane,
      revision: 1,
      layoutRevision: 1,
      geometryGeneration: 1,
      viewportRevision: 0
    )
  }

  /// Wide CJK, emoji clusters, combining marks, SGR colours, underline
  /// colours and a soft wrap.
  static func session() -> TerminalSession {
    let s = TerminalSession(columns: 12, rows: 6)
    s.feed(
      Array(
        "\u{1B}[1;31mred\u{1B}[0m \u{1B}[38;2;1;2;3;48;5;200mrgb\u{1B}[0m\r\n"
          .utf8
      )
    )
    s.feed(Array("漢字かな\r\n".utf8))
    s.feed(Array("e\u{301} 👍🏽 👨‍👩‍👧\r\n".utf8))
    s.feed(Array("\u{1B}[4:3;58:2::10:20:30mcurly\u{1B}[0m\r\n".utf8))
    s.feed(Array("0123456789abcdefgh".utf8))
    return s
  }

  static func roundTrip(_ frame: PaneFrame) throws -> PaneFrame {
    let data = try SMXCodec.encode(
      ServerMessage.event(.frame(frame)),
      limit: 16 << 20
    )
    let decoded = try SMXCodec.decode(
      ServerMessage.self,
      from: data,
      limit: 16 << 20
    )
    guard case let .event(.frame(f)) = decoded else {
      throw MuxError(.invalidRequest, "not a frame")
    }
    return f
  }

  @Test(arguments: [4092, 4093, 4094, 4095, 4096])
  func longMultibyteTitlesStayWithinTheFrameBudget(prefixLength: Int) throws {
    let session = Self.session()
    var screen = session.withState { $0.captureOwnedScreen() }
    let prefix = String(repeating: "a", count: prefixLength)
    screen.title = prefix + "🙂" + "tail"
    let frame = try FrameExporter.frame(from: screen, identity: Self.identity())
    #expect(frame.title == prefix + (prefixLength == 4092 ? "🙂" : ""))
    try FrameValidator.validate(frame)
  }

  @Test
  func keypadApplicationModeSurvivesImport() throws {
    var frame = try Self.validFrame()
    frame.modes.insert(.keypadApplication)
    let screen = try FrameImporter.screen(from: frame)
    #expect(screen.modes.contains(.keypadApplication))
  }

  @Test
  func exportImportParity() throws {
    let session = Self.session()
    let screen = session.withState { $0.captureOwnedScreen() }
    let direct = session.snapshot()
    let frame = try Self.roundTrip(
      FrameExporter.frame(from: screen, identity: Self.identity())
    )
    try FrameValidator.validate(frame)
    let imported = try FrameImporter.snapshot(from: frame, sequence: 1)

    #expect(imported.text == direct.text)
    #expect(imported.columns == direct.columns)
    #expect(imported.rowCount == direct.rowCount)
    #expect(imported.cursor == direct.cursor)
    #expect(imported.palette == direct.palette)
    #expect(imported.underlineColors == direct.underlineColors)
    for y in 0 ..< direct.rowCount {
      #expect(
        imported.rows[y].isWrapped == direct.rows[y].isWrapped,
        "row \(y) wrap"
      )
      let a = direct.cells(row: y)
      let b = imported.cells(row: y)
      for x in 0 ..< a.count {
        let ca = a[x]
        let cb = b[x]
        #expect(ca.width == cb.width, "width at \(x),\(y)")
        #expect(
          ca.attributes.foreground == cb.attributes.foreground,
          "fg at \(x),\(y)"
        )
        #expect(
          ca.attributes.background == cb.attributes.background,
          "bg at \(x),\(y)"
        )
        #expect(ca.attributes.underlineColor == cb.attributes.underlineColor)
        #expect(
          ca.attributes.flags == cb.attributes.flags,
          "flags at \(x),\(y)"
        )
        if ca.isGrapheme {
          #expect(cb.isGrapheme)
          let sa = direct.graphemeScalars(ca)
          let sb = imported.graphemeScalars(cb)
          #expect(sa.count == sb.count)
          for i in 0 ..< min(sa.count, sb.count) { #expect(sa[i] == sb[i]) }
        } else {
          #expect(ca.glyph == cb.glyph, "glyph at \(x),\(y)")
        }
      }
    }
    // Soft wrap of the last line survives.
    #expect(frame.grid.isWrapped(row: 4))
    #expect(frame.lines[1].hasPrefix("漢字かな"))
  }

  static func validFrame() throws -> PaneFrame {
    let s = TerminalSession(columns: 4, rows: 2)
    s.feed(Array("a漢".utf8))
    return try FrameExporter.frame(
      from: s.withState { $0.captureOwnedScreen() },
      identity: identity()
    )
  }

  static func kinds(_ f: inout PaneFrame, _ index: Int, _ kind: CellKind) {
    var k = [UInt8](f.grid.kinds)
    k[index] = kind.rawValue
    f.grid.kinds = Data(k)
  }

  static func glyph(_ f: inout PaneFrame, _ index: Int, _ value: UInt32) {
    var g = [UInt8](f.grid.glyphs)
    withUnsafeBytes(of: value.littleEndian) { bytes in
      for i in 0 ..< 4 { g[index * 4 + i] = bytes[i] }
    }
    f.grid.glyphs = Data(g)
  }

  static func rejects(_ frame: PaneFrame) -> Bool {
    (try? FrameImporter.snapshot(from: frame, sequence: 1)) == nil
  }

  @Test
  func validFrameImports() throws {
    let f = try Self.validFrame()
    #expect(!Self.rejects(f))
  }

  @Test
  func malformedFramesFailSafely() throws {
    let base = try Self.validFrame()

    var f = base
    f.grid.glyphs.removeLast()
    #expect(Self.rejects(f), "bad glyph length")

    f = base
    f.grid.wrapped = Data([0])
    #expect(Self.rejects(f), "bad wrap length")

    f = base
    Self.kinds(&f, 0, .continuation)
    #expect(Self.rejects(f), "orphan continuation")

    f = base
    Self.kinds(&f, 3, .wideLead)
    #expect(Self.rejects(f), "wide lead at row end")

    f = base
    Self.glyph(&f, 0, FrameGrid.graphemeFlag | 7)
    #expect(Self.rejects(f), "bad grapheme reference")

    f = base
    Self.glyph(&f, 0, 0xD800)
    #expect(Self.rejects(f), "surrogate scalar")

    f = base
    f.cursor.x = 4
    #expect(Self.rejects(f), "cursor out of range")

    f = base
    f.grid.columns = 100_000
    #expect(Self.rejects(f), "oversized dimensions")

    f = base
    f.palette.colors.removeLast()
    #expect(Self.rejects(f), "palette size")

    f = base
    var styles = [UInt8](f.grid.styles)
    styles[0] = 0xFF
    styles[1] = 0x7F
    f.grid.styles = Data(styles)
    #expect(Self.rejects(f), "style index")

    f = base
    f.graphemes = [[]]
    #expect(Self.rejects(f), "empty grapheme")
  }

  @Test
  func oversizedRecordsAreRejectedBeforeDecoding() {
    let data = Data(repeating: 0x20, count: 2048)
    #expect(throws: MuxError.self) {
      _ = try SMXCodec.decode(ClientMessage.self, from: data, limit: 1024)
    }
  }
}
