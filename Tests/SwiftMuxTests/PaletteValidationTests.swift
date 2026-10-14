import SwiftMuxProtocol
import Testing

struct PaletteValidationTests {
  enum Field: CaseIterable, Sendable {
    case firstIndexed, lastIndexed, foreground, background, cursor
    case cursorText, selectionForeground, selectionBackground

    func set(_ value: UInt32, in palette: inout FramePalette) {
      switch self {
      case .firstIndexed: palette.colors[0] = value
      case .lastIndexed: palette.colors[255] = value
      case .foreground: palette.foreground = value
      case .background: palette.background = value
      case .cursor: palette.cursor = value
      case .cursorText: palette.cursorText = value
      case .selectionForeground: palette.selectionForeground = value
      case .selectionBackground: palette.selectionBackground = value
      }
    }
  }

  @Test(arguments: Field.allCases, [UInt32(0x100_0000), UInt32.max])
  func `out of range colors are rejected in themes and decoded frames`(
    field: Field,
    value: UInt32
  ) throws {
    var frame = try BridgeTests.validFrame()
    field.set(value, in: &frame.palette)
    frame = try BridgeTests.roundTrip(frame)
    #expect(!MuxTheme(palette: frame.palette, dark: true).isValid)
    #expect(throws: MuxError.self) { try FrameValidator.validate(frame) }
    #expect(BridgeTests.rejects(frame))
  }

  @Test(arguments: Field.allCases, [UInt32(0), UInt32(0xFF_FFFF)])
  func `RGB bounds and absent optional colors remain valid`(
    field: Field,
    value: UInt32
  ) throws {
    var frame = try BridgeTests.validFrame()
    frame.palette.cursorText = nil
    frame.palette.selectionForeground = nil
    frame.palette.selectionBackground = nil
    field.set(value, in: &frame.palette)
    #expect(MuxTheme(palette: frame.palette, dark: false).isValid)
    try FrameValidator.validate(frame)
    #expect(!BridgeTests.rejects(frame))
  }

  @Test
  func `service rejects malformed colors without closing the connection`()
    async throws
  {
    let h = try Harness()
    let c = try await h.connect(.control)
    do {
      let palette = try BridgeTests.validFrame().palette
      try await c.execute(.setTheme(MuxTheme(palette: palette, dark: true)))
      for field in Field.allCases {
        for value: UInt32 in [0x100_0000, .max] {
          var invalid = palette
          field.set(value, in: &invalid)
          await #expect {
            try await c.execute(
              .setTheme(MuxTheme(palette: invalid, dark: true))
            )
          } throws: { error in (error as? MuxError)?.code == .invalidRequest }
        }
      }
      try await c.execute(.setTheme(MuxTheme(palette: palette, dark: false)))
    } catch {
      await c.close()
      throw error
    }
    await c.close()
  }
}
