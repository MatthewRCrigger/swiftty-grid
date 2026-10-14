import Foundation
import Testing

@testable import RoamingApp

@Suite
struct PreviewCaptureGateTests {
  @Test
  func aCaptureInsideTheIntervalSchedulesTheLatestScreen() {
    var gate = PreviewCaptureGate(
      lastCapture: Date(timeIntervalSince1970: 10),
      interval: 2
    )
    let first = gate.decide(now: Date(timeIntervalSince1970: 10), force: true)
    #expect(first == .capture(Date(timeIntervalSince1970: 10)))
    gate.didCapture(at: Date(timeIntervalSince1970: 10))
    let skipped = gate.decide(
      now: Date(timeIntervalSince1970: 11),
      force: false
    )
    #expect(skipped == .schedule(1))
    let again = gate.decide(
      now: Date(timeIntervalSince1970: 11.5),
      force: false
    )
    #expect(again == .skip)
    let forced = gate.decide(
      now: Date(timeIntervalSince1970: 11.5),
      force: true
    )
    #expect(forced == .capture(Date(timeIntervalSince1970: 11.5)))
  }

  @Test
  func aMissDoesNotConsumeTheInterval() {
    var gate = PreviewCaptureGate(lastCapture: .distantPast, interval: 2)
    let now = Date(timeIntervalSince1970: 30)
    #expect(gate.decide(now: now, force: false) == .capture(now))
    let soon = now.addingTimeInterval(0.2)
    #expect(gate.decide(now: soon, force: false) == .capture(soon))
  }
}
