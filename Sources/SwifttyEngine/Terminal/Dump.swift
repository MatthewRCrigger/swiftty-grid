extension TerminalState {
  /// The primary screen and its history as UTF-8 text with SGR styling,
  /// oldest line first. Soft-wrapped rows are joined, so replaying the
  /// dump into a terminal of any width reflows it. Empty when blank.
  public func dumpPrimaryANSI() -> [UInt8] {
    isAlternateScreen
      ? dump(inactiveGrid, cursorRow: inactivePrimaryCursor.y)
      : dump(grid, cursorRow: cursor.y)
  }

  /// Streams history through scoped reads: no pointer outlives its row
  /// and dumped history stays cold.
  private func dump(_ screen: borrowing Grid, cursorRow: Int?) -> [UInt8] {
    var last = screen.rows - 1
    while last >= 0, screen._unsafeCells(row: last).allSatisfy(\.isBlank) {
      last -= 1
    }
    if let cursorRow { last = max(last, cursorRow) }
    let lineCount = screen.historyCount + last + 1
    var out: [UInt8] = []
    var pen = CellAttributes.default
    func emit(_ index: Int, _ cells: UnsafeBufferPointer<Cell>, _ wrapped: Bool)
    {
      var end = cells.count
      if !wrapped { while end > 0, cells[end - 1].isBlank { end -= 1 } }
      for x in 0 ..< end {
        let cell = cells[x]
        if cell.isSpacer { continue }
        var attrs = cell.attributes
        attrs.flags.subtract(.structural)
        attrs.link = 0
        if attrs != pen {
          appendSGR(attrs, to: &out)
          pen = attrs
        }
        if cell.isGrapheme {
          var appended = false
          let scalars = graphemeScalars(cell.glyph)
          for point in scalars {
            if let scalar = Unicode.Scalar(point) {
              out.append(contentsOf: scalar.utf8)
              appended = true
            }
          }
          if !appended { out.append(0x20) }
        } else if cell.glyph != 0, let scalar = Unicode.Scalar(cell.glyph) {
          out.append(contentsOf: scalar.utf8)
        } else {
          out.append(0x20)
        }
      }
      if !wrapped, index < lineCount - 1 {
        if pen != .default {
          out.append(contentsOf: "\u{1B}[0m".utf8)
          pen = .default
        }
        out.append(contentsOf: "\r\n".utf8)
      }
    }
    for i in 0 ..< screen.historyCount {
      screen.withHistoryLine(i) { cells, wrapped in emit(i, cells, wrapped) }
    }
    if last >= 0 {
      for y in 0 ... last {
        emit(
          screen.historyCount + y,
          screen._unsafeCells(row: y),
          screen.isWrapped(y)
        )
      }
    }
    if pen != .default { out.append(contentsOf: "\u{1B}[0m".utf8) }
    return out
  }

  private func appendSGR(_ a: CellAttributes, to out: inout [UInt8]) {
    var params = ["0"]
    let flags: [(CellFlags, String)] = [
      (.bold, "1"), (.faint, "2"), (.italic, "3"), (.blink, "5"),
      (.inverse, "7"), (.invisible, "8"), (.strikethrough, "9"),
      (.overline, "53"),
    ]
    for (flag, code) in flags where a.flags.contains(flag) {
      params.append(code)
    }
    if a.flags.contains(.doubleUnderline) {
      params.append("4:2")
    } else if a.flags.contains(.underline) {
      switch (
        a.flags.contains(.underlineStyleA), a.flags.contains(.underlineStyleB)
      ) {
      case (true, false): params.append("4:3")
      case (false, true): params.append("4:4")
      case (true, true): params.append("4:5")
      case (false, false): params.append("4")
      }
    }
    if let underline = underlineColor(a.underlineColor) {
      switch underline.kind {
      case .default: break
      case let .palette(i): params.append("58;5;\(i)")
      case let .rgb(v):
        params.append("58;2;\(v >> 16 & 0xFF);\(v >> 8 & 0xFF);\(v & 0xFF)")
      }
    }
    func color(_ c: TerminalColor, _ base: Int) {
      switch c.kind {
      case .default: break
      case let .palette(i) where i < 8: params.append("\(base + Int(i))")
      case let .palette(i) where i < 16:
        params.append("\(base + 60 + Int(i) - 8)")
      case let .palette(i): params.append("\(base + 8);5;\(i)")
      case let .rgb(v):
        params.append(
          "\(base + 8);2;\(v >> 16 & 0xFF);\(v >> 8 & 0xFF);\(v & 0xFF)"
        )
      }
    }
    color(a.foreground, 30)
    color(a.background, 40)
    out.append(contentsOf: "\u{1B}[\(params.joined(separator: ";"))m".utf8)
  }
}
