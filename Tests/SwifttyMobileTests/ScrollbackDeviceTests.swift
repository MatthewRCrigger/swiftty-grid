#if SWIFTTY_REQUIRE_SCROLLBACK_BENCHMARK
import Foundation
import SwifttyCore
import Testing

/// Scrollback compression gates (spec.scrollback.md §13) on a physical
/// device. Built only by `Scripts/test-ipad-scrollback.sh`.
@Suite(.serialized)
struct ScrollbackDeviceTests {
  static let columns = 120
  static let rows = 80

  static func corpus(_ kind: String) -> [UInt8] {
    var s = ""
    for i in 0 ..< 2_000 {
      switch kind {
      case "ascii":
        s += "line \(i) the quick brown fox jumps over the lazy dog \(i % 97)"
      case "compiler-log":
        s +=
          "\u{1B}[1mSources/Module\(i % 40)/File\(i % 13).swift:\(i):7:"
          + "\u{1B}[0m \u{1B}[33mwarning:\u{1B}[0m unused variable 'v\(i)'"
      default:
        s +=
          "\u{1B}[3\(i % 8)mstyled \(i)\u{1B}[0m 漢字 e\u{301} 👩‍💻 "
          + "\u{1B}]8;;https://example.com/\(i % 50)\u{1B}\\link\u{1B}]8;;\u{1B}\\"
      }
      s += "\r\n"
    }
    return Array(s.utf8)
  }

  static func fill(
    _ state: inout TerminalState,
    _ parser: inout Parser,
    _ c: [UInt8]
  ) {
    while state.scrollbackCount < state.grid.historyCapacity {
      parser.consume(c.span, into: &state)
    }
  }

  static func settle(_ state: inout TerminalState) -> [Double] {
    var encode: [Double] = []
    while true {
      let before = state.scrollbackStatistics
      let result = state.maintainScrollback()
      let after = state.scrollbackStatistics
      if after.compressions > before.compressions {
        encode.append(
          Double(after.compressNanoseconds - before.compressNanoseconds)
        )
      }
      if result != .pending { break }
    }
    return encode
  }

  static func percentile(_ v: [Double], _ p: Double) -> Double {
    let s = v.sorted()
    return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
  }

  static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  @Test(arguments: ["ascii", "compiler-log", "styled"])
  func `compression gates hold on device`(_ kind: String) {
    let chunk = Self.corpus(kind)
    var state = TerminalState(columns: Self.columns, rows: Self.rows)
    #expect(state.scrollbackCompression.effective)
    var parser = Parser()
    Self.fill(&state, &parser, chunk)
    let filled = ProcessMemorySample.current()
    let eligible = state.scrollbackStatistics.eligibleUnitBytes
    let encode = Self.settle(&state)
    let stats = state.scrollbackStatistics
    let idle = ProcessMemorySample.current()
    let saved =
      1 - Double(stats.compressedPayloadBytes + stats.workspaceBytes)
      / Double(max(1, eligible))
    // Cold 120×80 viewport preparation: borrow every visible row.
    var cold: [Double] = []
    var warm: [Double] = []
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    let history = state.scrollbackCount
    for i in 0 ..< 1_000 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      let offset = Self.rows + Int(seed >> 33) % max(1, history - 2 * Self.rows)
      state.scrollViewport(by: offset - state.viewportOffset)
      var start = Self.now()
      var sum = 0
      for y in 0 ..< Self.rows { sum &+= state.viewportCells(row: y).count }
      cold.append(Double(Self.now() - start))
      start = Self.now()
      for y in 0 ..< Self.rows { sum &+= state.viewportCells(row: y).count }
      warm.append(Double(Self.now() - start))
      precondition(sum > 0)
      state.scrollViewportToBottom()
      if i % 25 == 0 { _ = Self.settle(&state) }
    }
    // Resume: alternating uncompressed/compressed full rings.
    var input: [UInt8] = []
    while input.count < 100 << 20 { input += chunk }
    var rates: [Bool: [Double]] = [false: [], true: []]
    for run in 0 ..< 6 {
      let on = run % 2 == 1
      var ring = TerminalState(columns: Self.columns, rows: 40)
      ring.setScrollbackCompression(on)
      var p = Parser()
      Self.fill(&ring, &p, chunk)
      _ = Self.settle(&ring)
      let start = Self.now()
      p.consume(input.span, into: &ring)
      rates[on]!.append(Double(input.count) / Double(Self.now() - start))
    }
    let ratio =
      Self.percentile(rates[true]!, 0.5) / Self.percentile(rates[false]!, 0.5)
    print(
      "scrollback-device corpus=\(kind) units=\(stats.compressedUnits) "
        + "saved=\(String(format: "%.1f", saved * 100))% "
        + "encode-p99-us=\(String(format: "%.1f", Self.percentile(encode, 0.99) / 1000)) "
        + "cold-p95-ms=\(String(format: "%.3f", Self.percentile(cold, 0.95) / 1e6)) "
        + "cold-p99-ms=\(String(format: "%.3f", Self.percentile(cold, 0.99) / 1e6)) "
        + "warm-p95-ms=\(String(format: "%.3f", Self.percentile(warm, 0.95) / 1e6)) "
        + "resume=\(String(format: "%.1f", ratio * 100))% "
        + "footprint-MiB=\(filled.physicalFootprintBytes >> 20)->\(idle.physicalFootprintBytes >> 20) "
        + "restores=\(state.scrollbackStatistics.restores)"
    )
    #expect(saved >= 0.70)
    #expect(Self.percentile(encode, 0.99) < 1_000_000)
    #expect(Self.percentile(cold, 0.95) <= 4_000_000)
    #expect(Self.percentile(cold, 0.99) <= 8_000_000)
    #expect(ratio >= 0.98)
    #expect(idle.physicalFootprintBytes < filled.physicalFootprintBytes)
  }

  @Test
  func `clearing returns compressed history and settles idle`() {
    var state = TerminalState(columns: Self.columns, rows: Self.rows)
    var parser = Parser()
    Self.fill(&state, &parser, Self.corpus("ascii"))
    _ = Self.settle(&state)
    parser.consume(Array("\u{1B}[3J".utf8).span, into: &state)
    state.releaseScrollbackWorkspace()
    let s = state.scrollbackStatistics
    print(
      "scrollback-device clear resident-KiB=\(s.residentUnitBytes >> 10) "
        + "payload=\(s.compressedPayloadBytes) workspace=\(s.workspaceBytes) "
        + "reclaimed-MiB=\(s.reclaimedFreeBytes >> 20) restores=\(s.restores)"
    )
    #expect(s.compressedPayloadBytes == 0 && s.restores == 0)
    // After one settled pass, an unchanged terminal has no further work.
    _ = Self.settle(&state)
    #expect(state.maintainScrollback() == .idle)
  }
}
#endif
