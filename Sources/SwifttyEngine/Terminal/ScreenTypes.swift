public struct CursorState: Sendable, Equatable {
  public var x: Int
  public var y: Int
  public var isVisible: Bool
  public var style: CursorStyle
  public var isBlinking: Bool

  public init(
    x: Int,
    y: Int,
    isVisible: Bool,
    style: CursorStyle,
    isBlinking: Bool
  ) {
    self.x = x
    self.y = y
    self.isVisible = isVisible
    self.style = style
    self.isBlinking = isBlinking
  }
}

/// A highlighted span in snapshot rows (inclusive; rows may lie outside
/// the snapshot when the span is partly scrolled out).
public struct HighlightSpan: Sendable, Equatable {
  public var startRow: Int
  public var startColumn: Int
  public var endRow: Int
  public var endColumn: Int
  public var rectangle: Bool

  public init(
    startRow: Int,
    startColumn: Int,
    endRow: Int,
    endColumn: Int,
    rectangle: Bool = false
  ) {
    self.startRow = startRow
    self.startColumn = startColumn
    self.endRow = endRow
    self.endColumn = endColumn
    self.rectangle = rectangle
  }

  public func contains(row: Int, column: Int) -> Bool {
    guard row >= startRow, row <= endRow else { return false }
    if rectangle {
      return column >= min(startColumn, endColumn)
        && column <= max(startColumn, endColumn)
    }
    if row == startRow, column < startColumn { return false }
    if row == endRow, column > endColumn { return false }
    return true
  }
}
