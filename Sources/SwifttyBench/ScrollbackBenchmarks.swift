import Foundation
import SwifttyCore

/// Fixed corpora for scrollback storage cases. Each prints its byte count
/// and a hash so results are reproducible.
private let scrollbackCorpora: [(String, @Sendable () -> [UInt8])] = [
  ("ascii", asciiChunk), ("compiler-log", compilerLogChunk),
  ("cat-source", sourceChunk), ("csi-heavy", csiChunk), ("osc-heavy", oscChunk),
  ("styled-links", styledLinkChunk), ("utf8", utf8Chunk),
  ("random-cells", randomCellChunk),
]

/// Styled text, dense OSC 8 links, CJK, combining marks, emoji and long
/// logical lines that cross compression units.
private func styledLinkChunk() -> [UInt8] {
  var s = ""
  for i in 0 ..< 200 {
    s += "\u{1B}[3\(i % 8);4\((i + 3) % 8)mstyled \(i)\u{1B}[0m "
    s += "\u{1B}]8;;https://example.com/\(i % 61)\u{1B}\\link \(i)"
    s += "\u{1B}]8;;\u{1B}\\ 漢字 e\u{301} 👩‍👩‍👧 "
    if i % 25 == 0 { s += String(repeating: "wrap-", count: 120) }
    s += "\r\n"
  }
  return Array(s.utf8)
}

/// Incompressible cell patterns: random colors, flags and scalars.
private func randomCellChunk() -> [UInt8] {
  var random = LCG()
  var s = ""
  for _ in 0 ..< 200 {
    for _ in 0 ..< 60 {
      s +=
        "\u{1B}[38;2;\(random.next(256));\(random.next(256));\(random.next(256))m"
      s += String(UnicodeScalar(UInt32(0x4E00 + random.next(0x5000)))!)
    }
    s += "\u{1B}[0m\r\n"
  }
  return Array(s.utf8)
}

private func hash(_ bytes: [UInt8]) -> String {
  var h: UInt64 = 0xCBF2_9CE4_8422_2325
  for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
  return String(h, radix: 16)
}

private func mib(_ bytes: Int) -> String { fmt(Double(bytes) / 1_048_576, 2) }

private func settle(
  _ state: inout TerminalState
) -> (steps: Int, encodeNs: [Double]) {
  var steps = 0
  var samples: [Double] = []
  while true {
    let before = state.scrollbackStatistics
    let result = state.maintainScrollback()
    let after = state.scrollbackStatistics
    if after.compressions > before.compressions {
      samples.append(
        Double(after.compressNanoseconds - before.compressNanoseconds)
      )
    }
    steps += 1
    if result != .pending { break }
  }
  return (steps, samples)
}

private func fill(
  _ state: inout TerminalState,
  _ parser: inout Parser,
  _ chunk: [UInt8],
  rows: Int
) {
  // Enough output to fill the ring once.
  var written = 0
  while state.grid.historyCount < state.grid.historyCapacity || written == 0 {
    parser.consume(chunk.span, into: &state)
    written += chunk.count
    if written > 1 << 30 { break }
  }
  _ = rows
}

private func stage(
  _ name: String,
  corpus: String,
  compression: Bool,
  _ state: borrowing TerminalState
) {
  let s = state.scrollbackStatistics
  let process = ProcessMemorySample.current()
  row(
    "scrollback-memory",
    [
      ("corpus", corpus), ("compression", compression ? "on" : "off"),
      ("stage", name), ("history-rows", "\(state.scrollbackCount)"),
      ("logical-MiB", mib(s.logicalHistoryCellBytes)),
      ("resident-MiB", mib(s.residentUnitBytes)),
      ("compressed-MiB", mib(s.compressedPayloadBytes)),
      ("eligible-MiB", mib(s.eligibleUnitBytes)),
      ("protected-MiB", mib(s.protectedUnitBytes)),
      ("reclaimed-MiB", mib(s.reclaimedFreeBytes)),
      ("metadata-MiB", mib(s.metadataBytes)),
      ("workspace-KiB", fmt(Double(s.workspaceBytes) / 1024, 1)),
      ("rss-MiB", mib(process.residentBytes)),
      ("footprint-MiB", mib(process.physicalFootprintBytes)),
      ("restores", "\(s.restores)"), ("scan-decodes", "\(s.scanDecodes)"),
    ]
  )
}

/// Stages within one process with equal retained rows: empty → filled →
/// idle-compressed → cold-scroll → full-search/copy → resumed-output →
/// resized → cleared → closed, for compression on and off.
func runScrollbackMemoryBenchmarks() {
  guard selected("scrollback-memory") else { return }
  runScrollbackPaneBenchmarks()
  let columns = 120
  let rows = 40
  for (name, make) in scrollbackCorpora {
    let chunk = make()
    row(
      "scrollback-corpus",
      [("corpus", name), ("bytes", "\(chunk.count)"), ("fnv1a", hash(chunk))]
    )
    for compression in [false, true] {
      do {
        var state = TerminalState(columns: columns, rows: rows)
        state.setScrollbackCompression(compression)
        var parser = Parser()
        stage("empty", corpus: name, compression: compression, state)
        fill(&state, &parser, chunk, rows: rows)
        stage("filled", corpus: name, compression: compression, state)
        _ = settle(&state)
        stage("idle-compressed", corpus: name, compression: compression, state)
        for offset in stride(from: 0, to: state.scrollbackCount, by: 5_000) {
          state.scrollViewport(by: offset - state.viewportOffset)
          _ = state.captureOwnedScreen()
        }
        state.scrollViewportToBottom()
        stage("cold-scroll", corpus: name, compression: compression, state)
        _ = settle(&state)
        state.search("e")
        let first = state.firstAbsoluteRow
        let text = state.text(
          from: TerminalPoint(row: first, column: 0),
          to: TerminalPoint(
            row: first + state.addressableRows - 1,
            column: columns - 1
          )
        )
        stage("full-search-copy", corpus: name, compression: compression, state)
        _ = text.utf8.count
        parser.consume(chunk.span, into: &state)
        stage("resumed-output", corpus: name, compression: compression, state)
        _ = settle(&state)
        state.resize(columns: 100, rows: rows)
        stage("resized", corpus: name, compression: compression, state)
        _ = settle(&state)
        parser.consume(Array("\u{1B}[3J".utf8).span, into: &state)
        state.releaseScrollbackWorkspace()
        stage("cleared", corpus: name, compression: compression, state)
      }
      let process = ProcessMemorySample.current()
      row(
        "scrollback-memory",
        [
          ("corpus", name), ("compression", compression ? "on" : "off"),
          ("stage", "closed"), ("rss-MiB", mib(process.residentBytes)),
          ("footprint-MiB", mib(process.physicalFootprintBytes)),
        ]
      )
    }
  }
}

/// Many panes: idle panes compressed together, then all resuming at
/// once; and the residual after clearing versus an equivalent fresh pane.
private func runScrollbackPaneBenchmarks() {
  let chunk = compilerLogChunk()
  for count in [1, 16, 64] {
    var panes: [TerminalStateBox] = (0 ..< count)
      .map { _ in TerminalStateBox(TerminalState(columns: 120, rows: 40)) }
    func report(_ stage: String) {
      var total = ScrollbackStatistics()
      for pane in panes { total += pane.state.scrollbackStatistics }
      let process = ProcessMemorySample.current()
      row(
        "scrollback-panes",
        [
          ("panes", "\(count)"), ("stage", stage),
          ("logical-MiB", mib(total.logicalHistoryCellBytes)),
          ("resident-MiB", mib(total.residentUnitBytes)),
          ("compressed-MiB", mib(total.compressedPayloadBytes)),
          ("workspace-KiB", fmt(Double(total.workspaceBytes) / 1024, 1)),
          ("metadata-MiB", mib(total.metadataBytes)),
          ("footprint-MiB", mib(process.physicalFootprintBytes)),
          ("restores", "\(total.restores)"),
        ]
      )
    }
    for i in panes.indices {
      fill(&panes[i].state, &panes[i].parser, chunk, rows: 40)
    }
    report("filled")
    for i in panes.indices { _ = settle(&panes[i].state) }
    report("idle-compressed")
    let start = DispatchTime.now().uptimeNanoseconds
    for i in panes.indices {
      panes[i].parser.consume(chunk.span, into: &panes[i].state)
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    report("resumed-together")
    row("scrollback-panes", [("panes", "\(count)"), ("resume-ms", fmt(ms, 2))])
    for i in panes.indices { _ = settle(&panes[i].state) }
    for i in panes.indices {
      panes[i].parser
        .consume(Array("\u{1B}[3J".utf8).span, into: &panes[i].state)
      panes[i].state.releaseScrollbackWorkspace()
    }
    report("cleared")
    panes.removeAll()
  }
  // Clear residual: a filled, compressed, cleared pane against a fresh one.
  let fresh = TerminalState(columns: 120, rows: 40)
  var used = TerminalState(columns: 120, rows: 40)
  var parser = Parser()
  fill(&used, &parser, chunk, rows: 40)
  _ = settle(&used)
  parser.consume(Array("\u{1B}[3J".utf8).span, into: &used)
  used.releaseScrollbackWorkspace()
  let a = fresh.scrollbackStatistics
  let b = used.scrollbackStatistics
  row(
    "scrollback-clear-residual",
    [
      (
        "resident-KiB",
        fmt(Double(b.residentUnitBytes - a.residentUnitBytes) / 1024, 1)
      ), ("payload-KiB", fmt(Double(b.compressedPayloadBytes) / 1024, 1)),
      (
        "workspace-KiB",
        fmt(Double(b.workspaceBytes - a.workspaceBytes) / 1024, 1)
      ),
      (
        "metadata-KiB", fmt(Double(b.metadataBytes - a.metadataBytes) / 1024, 1)
      ), ("reserved-MiB", mib(b.reservedMappingBytes - a.reservedMappingBytes)),
      ("reclaimed-MiB", mib(b.reclaimedFreeBytes)),
      ("mixed-units", "\(b.residentUnits)"),
    ]
  )
}

/// Holds a noncopyable terminal and parser so many fit in an array.
private final class TerminalStateBox {
  var state: TerminalState
  var parser = Parser()
  init(_ state: consuming TerminalState) { self.state = state }
}

/// Encode cost per unit, accounted savings over eligible cold storage,
/// and cold/warm 120×80 viewport capture latency.
func runScrollbackCompressionBenchmarks() {
  guard selected("scrollback-compression") else { return }
  for (name, make) in scrollbackCorpora {
    let chunk = make()
    var state = TerminalState(columns: 120, rows: 80)
    var parser = Parser()
    fill(&state, &parser, chunk, rows: 80)
    let eligible = state.scrollbackStatistics.eligibleUnitBytes
    let (_, encode) = settle(&state)
    let s = state.scrollbackStatistics
    let saved =
      eligible > 0
      ? 1 - Double(s.compressedPayloadBytes + s.workspaceBytes)
        / Double(eligible) : 0
    var cold: [Double] = []
    var warm: [Double] = []
    let history = state.scrollbackCount
    var random = LCG()
    for i in 0 ..< 1_000 {
      let offset = 80 + random.next(max(1, history - 160))
      state.scrollViewport(by: offset - state.viewportOffset)
      let start = DispatchTime.now().uptimeNanoseconds
      _ = state.captureOwnedScreen()
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start)
      // Every other sample re-captures the now-warm viewport.
      if i % 2 == 0 {
        cold.append(elapsed)
        let again = DispatchTime.now().uptimeNanoseconds
        _ = state.captureOwnedScreen()
        warm.append(Double(DispatchTime.now().uptimeNanoseconds - again))
      } else {
        cold.append(elapsed)
      }
      state.scrollViewportToBottom()
      if i % 50 == 0 { _ = settle(&state) }
    }
    row(
      "scrollback-compression",
      [
        ("corpus", name), ("units", "\(s.compressedUnits)"),
        ("unprofitable", "\(s.unprofitableAttempts)"),
        ("eligible-MiB", mib(eligible)),
        ("payload-MiB", mib(s.compressedPayloadBytes)),
        ("saved", fmt(saved * 100, 1) + "%"),
        ("encode-p50-us", fmt(percentile(encode, 0.5) / 1000, 1)),
        ("encode-p99-us", fmt(percentile(encode, 0.99) / 1000, 1)),
        ("capture-p95-ms", fmt(percentile(cold, 0.95) / 1e6, 3)),
        ("capture-p99-ms", fmt(percentile(cold, 0.99) / 1e6, 3)),
        ("warm-p95-ms", fmt(percentile(warm, 0.95) / 1e6, 3)),
      ]
    )
  }
}

/// Output throughput into a full ring, compressed versus uncompressed, in
/// alternating runs with restoration inside the timed interval.
func runScrollbackResumeBenchmarks() {
  guard selected("scrollback-resume") else { return }
  for (name, make) in scrollbackCorpora where name != "random-cells" {
    let chunk = make()
    var input: [UInt8] = []
    while input.count < streamBytes { input += chunk }
    var results: [Bool: [Double]] = [false: [], true: []]
    var restores = 0
    var restoreNs: UInt64 = 0
    for run in 0 ..< max(2, options.repeats) * 2 {
      let compression = run % 2 == 1
      var state = TerminalState(columns: 120, rows: 40)
      state.setScrollbackCompression(compression)
      var parser = Parser()
      fill(&state, &parser, chunk, rows: 40)
      _ = settle(&state)
      let start = DispatchTime.now().uptimeNanoseconds
      parser.consume(input.span, into: &state)
      let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
      results[compression]!.append(Double(input.count) / 1_048_576 / seconds)
      if compression {
        restores += state.scrollbackStatistics.restores
        restoreNs += state.scrollbackStatistics.restoreNanoseconds
      }
    }
    func spread(_ v: [Double]) -> String {
      "\(fmt(v.min() ?? 0))..\(fmt(v.max() ?? 0))"
    }
    let off = percentile(results[false]!, 0.5)
    let on = percentile(results[true]!, 0.5)
    row(
      "scrollback-resume",
      [
        ("corpus", name), ("off-MB/s", fmt(off)), ("on-MB/s", fmt(on)),
        ("ratio", fmt(on / max(off, 1e-9) * 100, 1) + "%"),
        ("off-spread", spread(results[false]!)),
        ("on-spread", spread(results[true]!)), ("restores", "\(restores)"),
        (
          "restore-us",
          fmt(Double(restoreNs) / Double(max(1, restores)) / 1000, 1)
        ),
      ]
    )
  }
}
