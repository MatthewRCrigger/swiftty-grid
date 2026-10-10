import Foundation
import SwiftMuxProtocol
import SwifttyCore

/// Converts a consistent owned capture into a `PaneFrame`.
public enum FrameExporter {
  /// - Throws: `resourceLimit` when valid state exceeds an export budget;
  ///   cells are never silently omitted.
  package static func frame(
    from screen: OwnedScreen,
    identity: FrameIdentity,
    limits: MuxLimits = .standard
  ) throws(MuxError) -> PaneFrame {
    guard
      let count = limits.cellCount(columns: screen.columns, rows: screen.rows)
    else {
      throw MuxError(
        .resourceLimit,
        "pane \(screen.columns)x\(screen.rows) exceeds frame dimensions"
      )
    }
    var glyphs = [UInt32](repeating: 0, count: count)
    var styleIndex = [UInt16](repeating: 0, count: count)
    var kinds = [UInt8](repeating: CellKind.narrow.rawValue, count: count)
    var styles: [FrameStyle] = [.plain]
    var lookup: [FrameStyle: UInt16] = [.plain: 0]
    var graphemes: [[UInt32]] = []
    for i in 0 ..< count {
      let cell = screen.cells[i]
      let a = cell.attributes
      var flags = a.flags
      flags.subtract(.structural)
      let style = FrameStyle(
        foreground: a.foreground.rawValue,
        background: a.background.rawValue,
        flags: flags.rawValue,
        underlineColor: a.underlineColor
      )
      if let idx = lookup[style] {
        styleIndex[i] = idx
      } else {
        guard styles.count < limits.maxStyles else {
          throw MuxError(.resourceLimit, "frame style table")
        }
        lookup[style] = UInt16(styles.count)
        styleIndex[i] = UInt16(styles.count)
        styles.append(style)
      }
      if cell.flags.contains(.spacerTail) {
        kinds[i] = CellKind.continuation.rawValue
      } else if cell.flags.contains(.spacerHead) {
        kinds[i] = CellKind.padding.rawValue
      } else {
        if cell.width == 2 { kinds[i] = CellKind.wideLead.rawValue }
        if cell.isGrapheme {
          let scalars = screen.graphemes[Int(cell.glyph)]
          guard scalars.count <= limits.maxGraphemeScalars else {
            throw MuxError(.resourceLimit, "grapheme cluster length")
          }
          glyphs[i] = FrameGrid.graphemeFlag | UInt32(graphemes.count)
          graphemes.append(scalars)
        } else {
          glyphs[i] = cell.glyph
        }
      }
    }
    repairCellStructure(
      &kinds,
      &glyphs,
      columns: screen.columns,
      rows: screen.rows
    )
    let p = screen.palette
    var colors: [UInt32] = []
    colors.reserveCapacity(256)
    for i in 0 ..< 256 { colors.append(p.colors[i]) }
    let modes = viewModes(screen)
    let search = searchState(screen)
    var title = screen.title
    if title.utf8.count > 4096 {
      title = String(decoding: title.utf8.prefix(4096), as: UTF8.self)
    }
    return PaneFrame(
      identity: identity,
      grid: FrameGrid(
        columns: screen.columns,
        rows: screen.rows,
        alternateScreen: screen.isAlternateScreen,
        wrapped: Data(screen.wrapped.map { $0 ? 1 : 0 }),
        glyphs: glyphs.withUnsafeBytes { Data($0) },
        styles: styleIndex.withUnsafeBytes { Data($0) },
        kinds: Data(kinds)
      ),
      graphemes: graphemes,
      styles: styles,
      underlineColors: screen.underlineColors.map(\.rawValue),
      palette: FramePalette(
        colors: colors,
        foreground: p.foreground,
        background: p.background,
        cursor: p.cursor,
        cursorText: p.cursorText,
        selectionForeground: p.selectionForeground,
        selectionBackground: p.selectionBackground
      ),
      cursor: FrameCursor(
        x: screen.cursor.x,
        y: screen.cursor.y,
        visible: screen.cursor.isVisible,
        style: screen.cursor.style.rawValue,
        blinking: screen.cursor.isBlinking
      ),
      modes: modes,
      history: HistoryWindow(
        generation: screen.addressingGeneration,
        firstRow: screen.firstAbsoluteRow,
        availableRows: screen.scrollbackCount + screen.rows,
        viewportTop: screen.viewportTopRow,
        viewportOffset: screen.viewportOffset,
        scrollbackRows: screen.scrollbackCount
      ),
      search: search,
      title: title
    )
  }

  static func viewModes(_ screen: OwnedScreen) -> SupportedViewModes {
    var modes: SupportedViewModes = []
    if screen.modes.contains(.cursorKeys) { modes.insert(.cursorKeys) }
    if screen.modes.contains(.bracketedPaste) { modes.insert(.bracketedPaste) }
    if screen.isAlternateScreen { modes.insert(.alternateScreen) }
    if screen.modes.contains(.reverseVideo) { modes.insert(.reverseVideo) }
    if screen.modes.contains(.focusEvents) { modes.insert(.focusEvents) }
    if screen.modes.contains(.keypadApplication) {
      modes.insert(.keypadApplication)
    }
    return modes
  }

  static func searchState(_ screen: OwnedScreen) -> FrameSearch? {
    var search: FrameSearch?
    if screen.searchMatchCount > 0 || !screen.searchMatches.isEmpty {
      search = FrameSearch(
        matchCount: screen.searchMatchCount,
        selected: nil,
        visible: screen.searchMatches.compactMap { m in
          let startRow = max(0, m.startRow)
          let endRow = min(screen.rows - 1, m.endRow)
          guard startRow <= endRow else { return nil }
          return FrameSpan(
            startRow: startRow,
            startColumn: m.startRow < 0
              ? 0 : min(m.startColumn, screen.columns - 1),
            endRow: endRow,
            endColumn: m.endRow >= screen.rows
              ? screen.columns - 1 : min(m.endColumn, screen.columns - 1)
          )
        },
        selectedVisible: screen.selectedSearchMatch
      )
      if let s = search, s.visible.count != screen.searchMatches.count {
        search?.selectedVisible = nil
      }
    }
    return search
  }

  /// The engine guarantees lead/continuation pairs; repair defensively
  /// at row edges so the exported frame always validates.
  static func repairCellStructure(
    _ kinds: inout [UInt8],
    _ glyphs: inout [UInt32],
    columns: Int,
    rows: Int
  ) {
    for y in 0 ..< rows {
      for x in 0 ..< columns {
        let i = y * columns + x
        if kinds[i] == CellKind.wideLead.rawValue,
          x == columns - 1 || kinds[i + 1] != CellKind.continuation.rawValue
        {
          kinds[i] = CellKind.narrow.rawValue
        }
        if kinds[i] == CellKind.continuation.rawValue,
          x == 0 || kinds[i - 1] != CellKind.wideLead.rawValue
        {
          kinds[i] = CellKind.narrow.rawValue
          glyphs[i] = 0
        }
        if kinds[i] == CellKind.padding.rawValue, x != columns - 1 {
          kinds[i] = CellKind.narrow.rawValue
          glyphs[i] = 0
        }
      }
    }
  }
}

/// Builds app-owned renderer input from a validated frame.
public enum FrameImporter {
  /// Validates, then converts. Never partially applies an invalid frame.
  package static func screen(
    from frame: PaneFrame,
    limits: MuxLimits = .standard
  ) throws(MuxError) -> OwnedScreen {
    try FrameValidator.validate(frame, limits: limits)
    let g = frame.grid
    let count = g.columns * g.rows
    var cells: [Cell] = []
    cells.reserveCapacity(count)
    for i in 0 ..< count {
      let s = frame.styles[g.style(at: i)]
      var attributes = CellAttributes(
        foreground: TerminalColor(rawValue: s.foreground),
        background: TerminalColor(rawValue: s.background),
        flags: CellFlags(rawValue: s.flags).subtracting(.structural)
      )
      attributes.underlineColor = s.underlineColor
      let glyph = g.glyph(at: i)
      var cell = Cell(glyph: 0, attributes: attributes, width: 1)
      switch g.kind(at: i) {
      case .continuation:
        cell.width = 0
        cell.attributes.flags.insert(.spacerTail)
      case .padding: cell.attributes.flags.insert(.spacerHead)
      case .narrow, .wideLead:
        cell.width = g.kind(at: i) == .wideLead ? 2 : 1
        if glyph & FrameGrid.graphemeFlag != 0 {
          cell.glyph = glyph & ~FrameGrid.graphemeFlag
          cell.attributes.flags.insert(.grapheme)
        } else {
          cell.glyph = glyph
        }
      }
      cells.append(cell)
    }
    var colors = InlineArray<256, UInt32>(repeating: 0)
    for i in 0 ..< 256 { colors[i] = frame.palette.colors[i] }
    let p = frame.palette
    var modes: Modes = []
    if frame.modes.contains(.cursorKeys) { modes.insert(.cursorKeys) }
    if frame.modes.contains(.bracketedPaste) { modes.insert(.bracketedPaste) }
    if frame.modes.contains(.alternateScreen) { modes.insert(.alternateScreen) }
    if frame.modes.contains(.reverseVideo) { modes.insert(.reverseVideo) }
    if frame.modes.contains(.focusEvents) { modes.insert(.focusEvents) }
    if frame.cursor.visible { modes.insert(.cursorVisible) }
    if frame.cursor.blinking { modes.insert(.cursorBlink) }
    modes.insert(.autowrap)
    let search = frame.search
    return OwnedScreen(
      columns: g.columns,
      rows: g.rows,
      cells: cells,
      wrapped: (0 ..< g.rows).map(g.isWrapped(row:)),
      graphemes: frame.graphemes,
      cursor: CursorState(
        x: frame.cursor.x,
        y: frame.cursor.y,
        isVisible: frame.cursor.visible,
        style: CursorStyle(rawValue: frame.cursor.style) ?? .block,
        isBlinking: frame.cursor.blinking
      ),
      palette: Palette(
        colors: colors,
        foreground: p.foreground,
        background: p.background,
        cursor: p.cursor,
        cursorText: p.cursorText,
        selectionForeground: p.selectionForeground,
        selectionBackground: p.selectionBackground
      ),
      underlineColors: frame.underlineColors.map {
        TerminalColor(rawValue: $0)
      },
      modes: modes,
      title: frame.title,
      isAlternateScreen: g.alternateScreen,
      addressingGeneration: frame.history.generation,
      firstAbsoluteRow: frame.history.firstRow,
      viewportTopRow: frame.history.viewportTop,
      viewportOffset: frame.history.viewportOffset,
      scrollbackCount: frame.history.scrollbackRows,
      searchMatches: (search?.visible ?? [])
        .map {
          HighlightSpan(
            startRow: $0.startRow,
            startColumn: $0.startColumn,
            endRow: $0.endRow,
            endColumn: $0.endColumn
          )
        },
      selectedSearchMatch: search?.selectedVisible,
      searchMatchCount: search?.matchCount ?? 0
    )
  }

  /// An independent renderer snapshot with full damage.
  public static func snapshot(
    from frame: PaneFrame,
    selection: HighlightSpan? = nil,
    sequence: UInt64,
    limits: MuxLimits = .standard
  ) throws(MuxError) -> RenderSnapshot {
    RenderSnapshot(
      owned: try screen(from: frame, limits: limits),
      selection: selection,
      sequence: sequence
    )
  }
}
