extension TerminalState {
  /// Debug check: cells past each row's extent are blank (both screens).
  func checkExtentInvariant() -> Bool {
    for y in 0 ..< rows {
      let row = grid._unsafeCells(row: y)
      for x in grid.extent(y) ..< columns where !row[x].isBlank { return false }
      let other = inactiveGrid._unsafeCells(row: y)
      for x in inactiveGrid.extent(y) ..< columns where !other[x].isBlank {
        return false
      }
    }
    return true
  }

  @inline(__always)
  func _checkInvariants() {
    #if SWIFTTY_INTERNAL_CHECKS
    precondition(
      grid.checkInvariants() && inactiveGrid.checkInvariants(),
      "invalid row ownership or extent"
    )
    func checkCells(_ cells: UnsafeBufferPointer<Cell>) -> String? {
      for x in cells.indices {
        let cell = cells[x]
        let flags = cell.attributes.flags.rawValue
        if cell.width == 1 && flags & CellFlags.structural.rawValue == 0 {
          continue
        }
        if cell.width == 2 {
          guard
            x + 1 < cells.count
              && cells[x + 1].attributes.flags.rawValue
                & CellFlags.spacerTail.rawValue != 0
          else {
            return
              "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
          }
        }
        if flags & CellFlags.spacerTail.rawValue != 0 {
          guard x > 0 && cells[x - 1].width == 2 && cell.width == 0 else {
            return
              "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
          }
        }
        if flags & CellFlags.spacerHead.rawValue != 0
          && (x != cells.count - 1 || cell.width != 1)
        {
          return
            "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
        }
        if flags & CellFlags.grapheme.rawValue != 0 {
          guard Int(cell.glyph) < graphemes.entries.count else {
            return
              "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
          }
          let entry = graphemes.entries[Int(cell.glyph)]
          let start = Int(entry >> 32)
          let count = Int(entry & 0xFFFF_FFFF)
          guard
            count >= 2 && start <= graphemes.scalars.count
              && count <= graphemes.scalars.count - start
          else {
            return
              "invalid cell at column \(x): width=\(cell.width), flags=\(cell.flags.rawValue)"
          }
        }
      }
      return nil
    }
    for y in 0 ..< rows {
      let active = checkCells(grid._unsafeCells(row: y))
      let inactive = checkCells(inactiveGrid._unsafeCells(row: y))
      precondition(
        active == nil && inactive == nil,
        "screen row \(y): \(active ?? inactive ?? "")"
      )
    }
    for i in 0 ..< grid.historyCount {
      let error = checkCells(grid.historyLine(i).cells)
      precondition(error == nil, "history row \(i): \(error ?? "")")
    }
    for i in 0 ..< inactiveGrid.historyCount {
      let error = checkCells(inactiveGrid.historyLine(i).cells)
      precondition(error == nil, "inactive history row \(i): \(error ?? "")")
    }
    #endif
  }
}
