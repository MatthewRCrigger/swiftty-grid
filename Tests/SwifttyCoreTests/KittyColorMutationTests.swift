@testable import SwifttyCore
import SwifttyEngine
import Testing
import TestSupport

struct KittyColorMutationTests {
  private static var theme: Palette {
    var palette = Palette.standard
    palette.foreground = 0x102030
    palette.background = 0x405060
    palette.cursor = 0x708090
    palette.cursorText = 0xA0B0C0
    palette.selectionForeground = 0x123456
    palette.selectionBackground = 0x654321
    palette.colors[1] = 0x112233
    return palette
  }

  @Test(arguments: [false, true])
  func bareKeysResetEveryImplementedColor(fragmented: Bool) {
    for terminator in ["\u{07}", "\u{1B}\\"] {
      var vt = VT()
      vt.state.setDefaultPalette(Self.theme)
      let keys = [
        "foreground", "background", "cursor", "cursor_text",
        "selection_foreground", "selection_background", "1",
      ]
      vt.feed(
        "\u{1B}]21;" + keys.map { "\($0)=#abcdef" }.joined(separator: ";")
          + terminator
      )
      let request = "\u{1B}]21;" + keys.joined(separator: ";") + terminator
      if fragmented {
        for byte in request.utf8 { vt.feed(bytes: [byte]) }
      } else {
        vt.feed(request)
      }
      #expect(vt.state.palette == Self.theme)
      #expect(vt.state.output.isEmpty)
    }
  }

  @Test(arguments: [false, true])
  func emptyOverridesAreDynamicAndBareKeysRestoreTheTheme(fragmented: Bool) {
    for terminator in ["\u{07}", "\u{1B}\\"] {
      var vt = VT()
      vt.state.setDefaultPalette(Self.theme)
      let request =
        "\u{1B}]21;cursor_text=;selection_foreground=;selection_background=;cursor_text=?;selection_foreground=?;selection_background=?"
        + terminator
      if fragmented {
        for byte in request.utf8 { vt.feed(bytes: [byte]) }
      } else {
        vt.feed(request)
      }
      #expect(vt.state.palette.cursorText == nil)
      #expect(vt.state.palette.selectionForeground == nil)
      #expect(vt.state.palette.selectionBackground == nil)
      #expect(
        TestFixture(vt.takeOutput())
          == TestFixture(
            "\u{1B}]21;cursor_text=;selection_foreground=;selection_background="
              + terminator,
          )
      )
      vt.feed(
        "\u{1B}]21;cursor_text;selection_foreground;selection_background"
          + terminator,
      )
      #expect(vt.state.palette == Self.theme)
    }
  }

  @Test
  func emptyValuesDoNotResetFixedColorsOrPaletteEntries() {
    var vt = VT()
    vt.state.setDefaultPalette(Self.theme)
    vt.feed(
      "\u{1B}]21;foreground=#abcdef;background=#abcdef;cursor=#abcdef;1=#abcdef\u{07}",
    )
    vt.feed("\u{1B}]21;foreground=;background=;cursor=;1=\u{07}")
    #expect(vt.state.palette.foreground == 0xABCDEF)
    #expect(vt.state.palette.background == 0xABCDEF)
    // This engine supports a fixed cursor color, so an unsupported dynamic
    // request must not silently act as a reset to the configured color.
    #expect(vt.state.palette.cursor == 0xABCDEF)
    #expect(vt.state.palette.colors[1] == 0xABCDEF)
  }

  @Test
  func mutationsAndQueriesAreAppliedInRequestOrder() {
    var vt = VT()
    vt.state.setDefaultPalette(Self.theme)
    vt.feed(
      "\u{1B}]21;cursor_text=#010203;cursor_text=?;cursor_text=;cursor_text=?;cursor_text;cursor_text=?\u{07}",
    )
    #expect(
      TestFixture(vt.takeOutput())
        == TestFixture(
          "\u{1B}]21;cursor_text=rgb:0101/0202/0303;cursor_text=;cursor_text=rgb:a0a0/b0b0/c0c0\u{07}",
        )
    )
    #expect(vt.state.palette == Self.theme)
  }

  @Test(.enabled(if: RendererTests.device != nil))
  func dynamicSelectionAndResetReachRenderedPixels() throws {
    let renderer = try MetalRenderer(
      device: #require(RendererTests.device),
      fontManager: CoreTextFontManager(),
      font: FontDescriptor(size: 13, scale: 2),
    )
    let helper = RendererTests()
    let session = TerminalSession(columns: 4, rows: 1)
    var theme = Self.theme
    theme.foreground = 0xFF0000
    theme.background = 0x000000
    theme.selectionForeground = 0xFFFFFF
    theme.selectionBackground = 0x00FF00
    session.mutate {
      $0.setDefaultPalette(theme)
      $0.setSelection(
        Selection(
          anchor: TerminalPoint(row: 0, column: 0),
          head: TerminalPoint(row: 0, column: 3),
        )
      )
    }
    session.feed(Array("\u{1B}[?25l".utf8))
    let width = Int(renderer.cellSize.width) * 4 + 16
    let height = Int(renderer.cellSize.height) + 16
    func background() throws -> UInt32 {
      let frame = try helper.render(
        renderer,
        session.snapshot(),
        width: width,
        height: height,
      )
      let pixel = frame.pixel(8 + Int(renderer.cellSize.width) * 3 + 2, 10)
      return UInt32(pixel.r) << 16 | UInt32(pixel.g) << 8 | UInt32(pixel.b)
    }
    #expect(try background() == 0x00FF00)
    session.feed(
      Array("\u{1B}]21;selection_foreground=;selection_background=\u{07}".utf8)
    )
    #expect(try background() == 0xFF0000)
    session.feed(
      Array("\u{1B}]21;selection_foreground;selection_background\u{07}".utf8)
    )
    #expect(try background() == 0x00FF00)
  }
}
