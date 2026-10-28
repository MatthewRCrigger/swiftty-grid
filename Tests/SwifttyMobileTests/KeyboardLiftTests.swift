#if canImport(UIKit)
@testable import SwifttyMobile
import Testing
import UIKit

/// A docked keyboard lifts the terminal instead of shrinking its grid.
struct KeyboardLiftTests {
  // 2× scale, 4 pt padding, 10×20 pt cells.
  let geometry = GridGeometry(
    scale: 2,
    padding: CGPoint(x: 8, y: 8),
    cellSize: CGSize(width: 20, height: 40)
  )

  @Test
  func `no keyboard means no lift`() {
    #expect(
      TerminalUIView.keyboardLift(
        covered: 0,
        height: 800,
        cursorRow: 38,
        geometry: geometry
      ) == 0
    )
  }

  @Test
  func `a cursor above the keyboard stays put`() {
    // Row 5 ends at 4 + 6 × 20 = 124 pt, well above 800 − 300.
    #expect(
      TerminalUIView.keyboardLift(
        covered: 300,
        height: 800,
        cursorRow: 5,
        geometry: geometry
      ) == 0
    )
  }

  @Test
  func `a covered cursor lifts just above the keyboard`() {
    // Row 29 ends at 604 pt, plus 4 pt padding: 108 pt past 500.
    #expect(
      TerminalUIView.keyboardLift(
        covered: 300,
        height: 800,
        cursorRow: 29,
        geometry: geometry
      ) == 108
    )
  }

  @Test
  func `the lift never exceeds the covered height`() {
    #expect(
      TerminalUIView.keyboardLift(
        covered: 300,
        height: 800,
        cursorRow: 39,
        geometry: geometry
      ) == 300
    )
    #expect(
      TerminalUIView.keyboardLift(
        covered: 300,
        height: 800,
        cursorRow: nil,
        geometry: geometry
      ) == 300
    )
  }
}
#endif
