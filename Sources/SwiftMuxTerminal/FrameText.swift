import SwiftMuxProtocol

/// Selection text from one frozen frame: immutable cells, graphemes and
/// wrap flags. New output never changes it.
public enum FrameText {
  /// Last nonblank display cell, keeping wide and combining characters
  /// on their leading cell. An empty line starts at column zero.
  static func lineEnd(_ frame: PaneFrame, row: Int) -> Int {
    for column in stride(from: frame.grid.columns - 1, through: 0, by: -1) {
      let scalars = frame.scalars(row: row, column: column)
      if !scalars.isEmpty, scalars != [" "] { return column }
    }
    return 0
  }

  /// Inclusive range; soft-wrapped rows join without a newline and
  /// trailing blanks of each hard line are trimmed.
  public static func text(
    _ frame: PaneFrame,
    from a: (row: Int, column: Int),
    to b: (row: Int, column: Int),
    lines: Bool = false
  ) -> String {
    let g = frame.grid
    var (start, end) = (a, b)
    if (end.row, end.column) < (start.row, start.column) { swap(&start, &end) }
    start.row = min(max(start.row, 0), g.rows - 1)
    end.row = min(max(end.row, 0), g.rows - 1)
    var out = ""
    for row in start.row ... end.row {
      var lo =
        lines || row != start.row ? 0 : min(max(start.column, 0), g.columns - 1)
      let hi =
        lines || row != end.row
        ? g.columns - 1 : min(max(end.column, 0), g.columns - 1)
      if lo > 0, g.kind(at: row * g.columns + lo) == .continuation { lo -= 1 }
      var line = String.UnicodeScalarView()
      if lo <= hi {
        for x in lo ... hi {
          line.append(contentsOf: frame.scalars(row: row, column: x))
        }
      }
      var s = String(line)
      let joins = g.isWrapped(row: row) && row != end.row
      if !joins { while s.last == " " { s.removeLast() } }
      out += s
      if !joins, row != end.row { out += "\n" }
    }
    return out
  }

  /// Word bounds around a cell (letters, digits and a few path characters).
  public static func word(
    _ frame: PaneFrame,
    row: Int,
    column: Int
  ) -> (Int, Int) {
    let g = frame.grid
    func isWord(_ x: Int) -> Bool {
      guard let s = frame.scalars(row: row, column: x).first else {
        return g.kind(at: row * g.columns + x) == .continuation
      }
      return s.properties.isAlphabetic || s.properties.numericType != nil
        || "_-./~:@".unicodeScalars.contains(s)
    }
    guard isWord(column) else { return (column, column) }
    var lo = column
    var hi = column
    while lo > 0, isWord(lo - 1) { lo -= 1 }
    while hi < g.columns - 1, isWord(hi + 1) { hi += 1 }
    return (lo, hi)
  }
}
