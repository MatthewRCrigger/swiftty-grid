/// Program-reported text shown in native chrome (tab and pane titles).
public enum DisplayText {
  public static let maxTitleCharacters = 120

  /// Drops controls, bidi overrides and other invisible format scalars,
  /// folds whitespace runs to one space and bounds the length, so a
  /// program cannot inject layout or spoof chrome through OSC titles.
  public static func sanitize(
    _ text: String,
    limit: Int = maxTitleCharacters
  ) -> String {
    var out = String.UnicodeScalarView()
    var space = false
    for scalar in text.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse,
        .surrogate, .unassigned:
        space = space || scalar.properties.isWhitespace
        continue
      case .spaceSeparator:
        space = true
        continue
      default: break
      }
      if space, !out.isEmpty { out.append(" ") }
      space = false
      out.append(scalar)
    }
    let result = String(out)
    guard result.count > limit else { return result }
    return String(result.prefix(max(0, limit - 1))) + "…"
  }
}

extension LayoutGeometry {
  /// The smallest extent along `axis` that keeps every pane in `node` at
  /// least `pane` units, with `divider` between siblings.
  public static func minimumExtent(
    _ node: LayoutNode,
    axis: SplitAxis,
    pane: Int,
    divider: Int
  ) -> Int {
    switch node {
    case .pane: return pane
    case let .split(ax, _, a, b):
      let ma = minimumExtent(a, axis: axis, pane: pane, divider: divider)
      let mb = minimumExtent(b, axis: axis, pane: pane, divider: divider)
      return ax == axis ? ma + mb + divider : max(ma, mb)
    }
  }

  /// `ratio` for the split at `path` clamped so both children keep their
  /// minimum extents inside `rect`. When the area is too small for both,
  /// the space is shared in proportion to the minimums.
  public static func clampedRatio(
    _ ratio: Double,
    at path: [Bool],
    of root: LayoutNode,
    in rect: LayoutRect,
    minimum: (columns: Int, rows: Int),
    divider: Int
  ) -> Double {
    var node = root
    var area = rect
    for step in path {
      guard case let .split(axis, r, a, b) = node else { return ratio }
      let length = axis == .leftRight ? area.width : area.height
      let (first, second) = partition(length, ratio: r, divider: divider)
      switch (axis, step) {
      case (.leftRight, false): area.width = first
      case (.leftRight, true):
        area.x += first + divider
        area.width = second
      case (.topBottom, false): area.height = first
      case (.topBottom, true):
        area.y += first + divider
        area.height = second
      }
      node = step ? b : a
    }
    guard case let .split(axis, _, a, b) = node else { return ratio }
    let unit = axis == .leftRight ? minimum.columns : minimum.rows
    let length = axis == .leftRight ? area.width : area.height
    let usable = Double(max(1, length - divider))
    let ma = Double(minimumExtent(a, axis: axis, pane: unit, divider: divider))
    let mb = Double(minimumExtent(b, axis: axis, pane: unit, divider: divider))
    let lower = ma / usable
    let upper = 1 - mb / usable
    let bounded =
      lower <= upper ? min(upper, max(lower, ratio)) : ma / max(1, ma + mb)
    return min(0.95, max(0.05, bounded))
  }
}
