import SwiftMuxProtocol
import SwiftMuxService
import Testing

@Suite
struct PermanentInputCapacityTests {
  @Test
  func textLargerThanTheChunkOrPaneBudgetCannotFit() {
    var limits = MuxLimits()
    limits.maxPasteChunkBytes = 4
    limits.inputBytesPerPane = 100
    #expect(MuxService.permanentlyExceedsText(utf8Count: 5, limits: limits))
    #expect(!MuxService.permanentlyExceedsText(utf8Count: 4, limits: limits))
    limits.maxPasteChunkBytes = 100
    limits.inputBytesPerPane = 4
    #expect(MuxService.permanentlyExceedsText(utf8Count: 5, limits: limits))
    #expect(!MuxService.permanentlyExceedsText(utf8Count: 4, limits: limits))
  }

  @Test
  func pasteExpansionCountsNewlinesAndMarkers() {
    var limits = MuxLimits()
    limits.maxPasteChunkBytes = 8
    limits.inputBytesPerPane = 20
    // 8 text bytes fit the chunk. Two newlines plus 12 marker bytes do not
    // fit a 20-byte pane even when nothing else is outstanding.
    #expect(
      MuxService.permanentlyExceedsPaste(
        utf8Count: 8,
        newlineCount: 2,
        limits: limits
      )
    )
    limits.inputBytesPerPane = 22
    #expect(
      !MuxService.permanentlyExceedsPaste(
        utf8Count: 8,
        newlineCount: 2,
        limits: limits
      )
    )
  }

  @Test
  func aKeyNeedsRoomInAnEmptyPaneBudget() {
    var limits = MuxLimits()
    limits.inputBytesPerPane = 31
    #expect(MuxService.permanentlyExceedsKey(limits: limits))
    limits.inputBytesPerPane = 32
    #expect(!MuxService.permanentlyExceedsKey(limits: limits))
  }
}
