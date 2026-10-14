import Metal
@testable import SwifttyCore
import Testing

struct RendererCoordinateTests {
  @Test(.enabled(if: RendererTests.device != nil), arguments: [false, true])
  func publicSnapshotsBeyondSixteenBitCoordinatesRender(_ tall: Bool) throws {
    let device = try #require(RendererTests.device)
    let renderer = try MetalRenderer(
      device: device,
      fontManager: CoreTextFontManager(),
      font: FontDescriptor(),
    )
    let session = TerminalSession(
      columns: tall ? 1 : 65537,
      rows: tall ? 65537 : 1,
    )
    let snapshot = session.snapshot()
    #expect(snapshot.columns == (tall ? 1 : 65537))
    #expect(snapshot.rowCount == (tall ? 65537 : 1))
    let actual = try RendererTests()
      .render(renderer, snapshot, width: 16, height: 16, )
    let reference = TerminalSession(columns: 1, rows: 1)
    let expected = try RendererTests()
      .render(renderer, reference.snapshot(), width: 16, height: 16, )
    #expect(actual.pixels == expected.pixels)
  }
}
