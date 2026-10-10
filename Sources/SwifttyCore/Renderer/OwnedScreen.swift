/// A complete, independently owned copy of the visible terminal state.
///
/// Captured in one operation on the terminal's owner, so cells and metadata
/// describe the same state. Grapheme cells refer to `graphemes` by
/// index rather than to the terminal's pooled table; `links` are dropped.
/// Used by SwiftMux to export pane frames and, in the other direction, to
/// build renderer snapshots from validated frames.
package struct OwnedScreen: Sendable, Equatable {
  package var columns: Int
  package var rows: Int
  /// Row-major, `columns * rows` cells.
  package var cells: [Cell]
  package var wrapped: [Bool]
  package var graphemes: [[UInt32]]
  package var cursor: CursorState
  package var palette: Palette
  package var underlineColors: [TerminalColor]
  package var modes: Modes
  package var title: String
  package var isAlternateScreen: Bool
  /// History addressing: rows change meaning when this changes.
  package var addressingGeneration: UInt64
  /// Absolute row of the oldest available line.
  package var firstAbsoluteRow: Int
  /// Absolute row shown at viewport row 0.
  package var viewportTopRow: Int
  package var viewportOffset: Int
  package var scrollbackCount: Int
  package var searchMatches: [HighlightSpan]
  package var selectedSearchMatch: Int?
  package var searchMatchCount: Int

  package init(
    columns: Int,
    rows: Int,
    cells: [Cell],
    wrapped: [Bool],
    graphemes: [[UInt32]],
    cursor: CursorState,
    palette: Palette,
    underlineColors: [TerminalColor] = [],
    modes: Modes,
    title: String = "",
    isAlternateScreen: Bool = false,
    addressingGeneration: UInt64 = 0,
    firstAbsoluteRow: Int = 0,
    viewportTopRow: Int = 0,
    viewportOffset: Int = 0,
    scrollbackCount: Int = 0,
    searchMatches: [HighlightSpan] = [],
    selectedSearchMatch: Int? = nil,
    searchMatchCount: Int = 0,
  ) {
    self.columns = columns
    self.rows = rows
    self.cells = cells
    self.wrapped = wrapped
    self.graphemes = graphemes
    self.cursor = cursor
    self.palette = palette
    self.underlineColors = underlineColors
    self.modes = modes
    self.title = title
    self.isAlternateScreen = isAlternateScreen
    self.addressingGeneration = addressingGeneration
    self.firstAbsoluteRow = firstAbsoluteRow
    self.viewportTopRow = viewportTopRow
    self.viewportOffset = viewportOffset
    self.scrollbackCount = scrollbackCount
    self.searchMatches = searchMatches
    self.selectedSearchMatch = selectedSearchMatch
    self.searchMatchCount = searchMatchCount
  }

  /// Text of row `y` with trailing blanks trimmed.
  package func text(row y: Int) -> String {
    var s = String.UnicodeScalarView()
    for x in 0 ..< columns {
      let cell = cells[y * columns + x]
      if cell.isSpacer { continue }
      if cell.isGrapheme {
        for v in graphemes[Int(cell.glyph)] {
          s.append(Unicode.Scalar(v) ?? "\u{FFFD}")
        }
      } else {
        s.append(cell.glyph == 0 ? " " : Unicode.Scalar(cell.glyph) ?? " ")
      }
    }
    var line = String(s)
    while line.last == " " { line.removeLast() }
    return line
  }
}

extension TerminalState {
  /// Copies the visible viewport and its metadata into owned values.
  /// - Complexity: O(columns * rows) plus visible grapheme scalars.
  package func captureOwnedScreen() -> OwnedScreen {
    var cells: [Cell] = []
    cells.reserveCapacity(columns * rows)
    var wrapped: [Bool] = []
    wrapped.reserveCapacity(rows)
    var graphemes: [[UInt32]] = []
    for y in 0 ..< rows {
      let (row, isWrapped) = viewportRow(y)
      wrapped.append(isWrapped)
      for x in 0 ..< columns {
        guard x < row.count else {
          cells.append(.blank)
          continue
        }
        var cell = row[x]
        if cell.isGrapheme {
          let scalars = graphemeScalars(cell.glyph)
          var copy: [UInt32] = []
          copy.reserveCapacity(scalars.count)
          for i in 0 ..< scalars.count { copy.append(scalars[i]) }
          cell.glyph = UInt32(graphemes.count)
          graphemes.append(copy)
        }
        cell.attributes.link = 0
        cells.append(cell)
      }
    }
    let top = absoluteRow(viewportRow: 0)
    var matches: [HighlightSpan] = []
    var selected: Int?
    for (i, m) in searchMatches.enumerated() {
      let start = viewportRow(absoluteRow: m.start.row)
      let end = viewportRow(absoluteRow: m.end.row)
      guard end >= 0, start < rows else { continue }
      if i == searchSelected { selected = matches.count }
      matches.append(
        HighlightSpan(
          startRow: start,
          startColumn: m.start.column,
          endRow: end,
          endColumn: m.end.column
        )
      )
    }
    return OwnedScreen(
      columns: columns,
      rows: rows,
      cells: cells,
      wrapped: wrapped,
      graphemes: graphemes,
      cursor: CursorState(
        x: min(cursor.x, columns - 1),
        y: min(cursor.y, rows - 1),
        isVisible: modes.contains(.cursorVisible) && viewportOffset == 0,
        style: cursorStyle,
        isBlinking: modes.contains(.cursorBlink),
      ),
      palette: palette,
      underlineColors: underlineColors,
      modes: modes,
      title: title,
      isAlternateScreen: isAlternateScreen,
      addressingGeneration: addressingGeneration,
      firstAbsoluteRow: firstAbsoluteRow,
      viewportTopRow: top,
      viewportOffset: viewportOffset,
      scrollbackCount: scrollbackCount,
      searchMatches: matches,
      selectedSearchMatch: selected,
      searchMatchCount: searchMatches.count,
    )
  }
}

extension RenderSnapshot {
  /// An immutable snapshot with its own storage and full damage, built
  /// from an owned (already validated) screen. Grapheme cells must index
  /// `screen.graphemes`.
  package init(
    owned screen: OwnedScreen,
    selection: HighlightSpan? = nil,
    sequence: UInt64
  ) {
    let storage = SnapshotStorage()
    storage.load(screen)
    self.init(
      storage: storage,
      source: SnapshotSource(),
      columns: screen.columns,
      rowCount: screen.rows,
      overscanRows: 0,
      cursor: screen.cursor,
      selection: selection,
      searchMatches: screen.searchMatches,
      selectedSearchMatch: screen.selectedSearchMatch,
      searchMatchCount: screen.searchMatchCount,
      searchSelectedIndex: nil,
      damage: .full,
      palette: screen.palette,
      underlineColors: screen.underlineColors,
      modes: screen.modes,
      viewportOffset: screen.viewportOffset,
      scrollbackCount: screen.scrollbackCount,
      sequence: sequence,
    )
  }
}

extension SnapshotStorage {
  /// Fills this fresh storage from an owned screen.
  func load(_ screen: OwnedScreen) {
    ensureSize(columns: screen.columns, rows: screen.rows)
    var ids: [UInt32] = []
    ids.reserveCapacity(screen.graphemes.count)
    for scalars in screen.graphemes {
      ids.append(appendGrapheme(scalars.span))
      hasGraphemes = true
    }
    for y in 0 ..< screen.rows {
      rowRecords[y] = RowSnapshot(isDirty: true, isWrapped: screen.wrapped[y])
      let dst = cells + y * screen.columns
      for x in 0 ..< screen.columns {
        var cell = screen.cells[y * screen.columns + x]
        if cell.isGrapheme { cell.glyph = ids[Int(cell.glyph)] }
        dst[x] = cell
      }
    }
    pending = .none
  }
}
