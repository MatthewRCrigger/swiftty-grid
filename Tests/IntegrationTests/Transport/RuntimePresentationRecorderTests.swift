import Foundation
import SwifttyCore
import Synchronization
import Testing
import TestSupport

struct RuntimePresentationRecorderTests {
  private struct WeakRecorder: Sendable {
    weak var value: RuntimePresentationRecorder<Int>?
  }

  private func frame() -> PresentationFrame {
    PresentationFrame(
      columns: 2,
      rows: 1,
      cells: [.init(text: "a"), .init(text: "b")],
      wrapped: [false],
      styles: [.init()],
      cursorX: 0,
      cursorY: 0,
    )
  }

  @Test
  func malformedFramesAreRefusedAndDiagnosticsKeepTheDisplayedScreen() {
    let display = TerminalSession(presentationColumns: 2, rows: 1)
    let recorder = RuntimePresentationRecorder<PresentationFrame>(
      install: { display.installPresentation($0) },
      snapshot: { display.snapshot().text },
    )
    #expect(recorder.install(frame()))
    let previous = display.snapshot().text
    for variant in 0 ..< 5 {
      var invalid = frame()
      switch variant {
      case 0: invalid.cells = []
      case 1: invalid.rows = -1
      case 2: invalid.columns = Int.max
      case 3: invalid.cells[0].style = 99
      default: invalid.wrapped = []
      }
      #expect(!recorder.install(invalid))
      #expect(display.snapshot().text == previous)
      #expect(recorder.summary.contains("ab"))
    }
    #expect(recorder.resultCounts.accepted == 1)
    #expect(recorder.resultCounts.refused == 5)
    #expect(recorder.resultCounts.last == false)
  }

  @Test
  func concurrentInstallsCountExactlyWithoutAccumulatingHistory() async {
    let recorder = RuntimePresentationRecorder<Int>(
      install: { $0.isMultiple(of: 2) },
      snapshot: { ["screen"] },
    )
    await withTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 8 {
        group.addTask { for value in 0 ..< 12500 { recorder.install(value) } }
      }
    }
    #expect(recorder.resultCounts.accepted == 50000)
    #expect(recorder.resultCounts.refused == 50000)
    #expect(recorder.install(0))
    #expect(recorder.resultCounts.accepted == 50001)
    #expect(recorder.resultCounts.last == true)
    #expect(recorder.summary.utf8.count < 200)
  }

  @Test
  func externalCallbacksCanReadCountsWithoutHoldingTheRecorderLock() {
    let weak = Mutex(WeakRecorder())
    let recorder = RuntimePresentationRecorder<Int>(
      install: { _ in
        let current = weak.withLock { $0.value }
        #expect(current?.resultCounts.accepted == 0)
        return true
      },
      snapshot: {
        let current = weak.withLock { $0.value }
        #expect(current?.resultCounts.accepted == 1)
        return ["prompt"]
      },
    )
    weak.withLock { $0.value = recorder }
    #expect(recorder.resultCounts.last == nil)
    #expect(recorder.install(0))
    #expect(recorder.summary.contains("prompt"))
  }

  @Test(arguments: [false, true])
  func longUnicodeLinesAndManyRowsHaveBoundedDiagnosticOutput(_ manyRows: Bool)
  {
    let lines =
      manyRows
      ? Array(repeating: "漢字🦊", count: 20000)
      : [String(repeating: "漢字🦊", count: 100_000)]
    let recorder = RuntimePresentationRecorder<Int>(
      install: { _ in true },
      snapshot: { lines },
    )
    let summary = recorder.summary
    #expect(summary.hasSuffix("\n[truncated]"))
    #expect(summary.utf8.count < 16 * 1024 + 200)
  }

  @Test
  func emptyRowsPreserveTheirPositionsAndSummaryReadsCurrentSnapshot() {
    let screen = Mutex(["", "first", "", "last", ""])
    let recorder = RuntimePresentationRecorder<Int>(
      install: { _ in true },
      snapshot: { screen.withLock { $0 } },
    )
    #expect(recorder.summary.hasSuffix("frame:\n\nfirst\n\nlast\n"))
    screen.withLock { $0 = ["changed without an install"] }
    #expect(recorder.summary.hasSuffix("changed without an install"))
    #expect(recorder.resultCounts.accepted == 0)
    #expect(recorder.resultCounts.refused == 0)
  }
}
