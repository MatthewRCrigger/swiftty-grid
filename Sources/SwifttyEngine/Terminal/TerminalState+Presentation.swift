/// Presentation frames: screens produced by another terminal, installed
/// cell for cell without parsing (spec.roaming.md §A.4.3).
extension TerminalState {
  /// Replaces everything visible with `frame`, which must be valid
  /// (`PresentationFrame.isValid`). Keeps the frame's layout: rows are not
  /// reflowed and widths are not recalculated. Discards history, the
  /// selection, search results, modes and the inactive screen, and
  /// damages the whole screen.
  package mutating func installPresentation(_ frame: PresentationFrame) {
    // Reset first: resizing the blank screen then has nothing to reflow.
    fullReset()
    resize(columns: frame.columns, rows: frame.rows)
    endSearch()
    let attributes = frame.styles.map { style in
      var attributes = CellAttributes(
        foreground: Self.presentationColor(style.foreground),
        background: Self.presentationColor(style.background),
        flags: style.flags.subtracting(.structural),
      )
      if let underline = style.underlineColor {
        attributes.underlineColor = internUnderlineColor(
          Self.presentationColor(underline)
        )
      }
      return attributes
    }
    var cluster: [UInt32] = []
    for y in 0 ..< rows {
      let row = grid._unsafeRow(y)
      let base = y * columns
      var extent = 0
      for x in 0 ..< columns {
        let source = frame.cells[base + x]
        var cell: Cell
        if source.width == 0 {
          // A continuation takes its lead's pen, as when printing.
          var tail = row[x - 1].attributes
          tail.flags.subtract(.structural)
          tail.flags.insert(.spacerTail)
          cell = Cell(glyph: 0, attributes: tail, width: 0)
        } else {
          cell = Cell(
            glyph: 0,
            attributes: attributes[source.style],
            width: source.width
          )
          cluster.removeAll(keepingCapacity: true)
          for scalar in source.text.unicodeScalars {
            cluster.append(scalar.value)
          }
          if cluster.count == 1 {
            cell.glyph = cluster[0]
          } else if cluster.count > 1 {
            cell.glyph = graphemes.insert(cluster)
            cell.attributes.flags.insert(.grapheme)
          }
        }
        row[x] = cell
        if !cell.isBlank { extent = x + 1 }
      }
      grid.extend(y, to: extent)
      grid.setWrapped(y, frame.wrapped[y])
    }
    cursor.x = frame.cursorX
    cursor.y = frame.cursorY
    cursor.pendingWrap = false
    cursorStyle = frame.cursorStyle
    modes.update(.cursorVisible, frame.cursorVisible)
    modes.update(.cursorBlink, frame.cursorBlinking)
    modes.update(.reverseVideo, frame.reverseVideo)
    modes.update(.alternateScreen, frame.alternateScreen)
    if title != frame.title {
      titleBytes = Array(frame.title.utf8)
      titleChanged = true
    }
    damage.setFull()
    _checkInvariants()
  }

  private static func presentationColor(_ rgb: UInt32?) -> TerminalColor {
    guard let rgb else { return .default }
    return .rgb(
      UInt8(truncatingIfNeeded: rgb >> 16),
      UInt8(truncatingIfNeeded: rgb >> 8),
      UInt8(truncatingIfNeeded: rgb)
    )
  }
}

extension Modes {
  fileprivate mutating func update(_ mode: Modes, _ on: Bool) {
    if on { insert(mode) } else { remove(mode) }
  }
}
