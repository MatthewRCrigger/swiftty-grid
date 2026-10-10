/// `leftRight` places children side by side; `topBottom` stacks them.
public enum SplitAxis: String, Codable, Sendable, Hashable {
  case leftRight, topBottom
}

public enum Direction: String, Codable, Sendable, Hashable {
  case left, right, up, down
}

/// A tab's logical split tree. Persisted by the service; frontends map it
/// onto their own pixels or cells.
public indirect enum LayoutNode: Codable, Sendable, Hashable {
  case pane(PaneID)
  /// `ratio` is the share given to `first`, in (0, 1).
  case split(
    axis: SplitAxis,
    ratio: Double,
    first: LayoutNode,
    second: LayoutNode
  )

  /// Panes in display order (depth first, first child before second).
  public var panes: [PaneID] {
    switch self {
    case let .pane(id): [id]
    case let .split(_, _, a, b): a.panes + b.panes
    }
  }

  public func contains(_ pane: PaneID) -> Bool {
    switch self {
    case let .pane(id): id == pane
    case let .split(_, _, a, b): a.contains(pane) || b.contains(pane)
    }
  }

  public var depth: Int {
    switch self {
    case .pane: 0
    case let .split(_, _, a, b): 1 + max(a.depth, b.depth)
    }
  }

  /// Replaces `pane` with a split holding it first and `newPane` second.
  public func splitting(
    _ pane: PaneID,
    axis: SplitAxis,
    newPane: PaneID,
    ratio: Double = 0.5
  ) -> LayoutNode {
    switch self {
    case let .pane(id) where id == pane:
      .split(axis: axis, ratio: ratio, first: self, second: .pane(newPane))
    case .pane: self
    case let .split(ax, r, a, b):
      .split(
        axis: ax,
        ratio: r,
        first: a.splitting(pane, axis: axis, newPane: newPane, ratio: ratio),
        second: b.splitting(pane, axis: axis, newPane: newPane, ratio: ratio)
      )
    }
  }

  /// The tree without `pane`; its sibling takes the parent's place.
  /// Nil when `pane` was the only leaf.
  public func removing(_ pane: PaneID) -> LayoutNode? {
    switch self {
    case let .pane(id): return id == pane ? nil : self
    case let .split(ax, r, a, b):
      let na = a.removing(pane)
      let nb = b.removing(pane)
      switch (na, nb) {
      case let (x?, y?): return .split(axis: ax, ratio: r, first: x, second: y)
      case let (x?, nil): return x
      case let (nil, y?): return y
      case (nil, nil): return nil
      }
    }
  }

  /// The split at `path` (false = first, true = second), if any.
  public func node(at path: [Bool]) -> LayoutNode? {
    guard let step = path.first else { return self }
    guard case let .split(_, _, a, b) = self else { return nil }
    return (step ? b : a).node(at: Array(path.dropFirst()))
  }

  /// Sets the ratio of the split at `path`; nil if no split is there.
  public func settingRatio(_ ratio: Double, at path: [Bool]) -> LayoutNode? {
    guard case let .split(ax, r, a, b) = self else { return nil }
    guard let step = path.first else {
      return .split(axis: ax, ratio: ratio, first: a, second: b)
    }
    let rest = Array(path.dropFirst())
    if step {
      guard let nb = b.settingRatio(ratio, at: rest) else { return nil }
      return .split(axis: ax, ratio: r, first: a, second: nb)
    }
    guard let na = a.settingRatio(ratio, at: rest) else { return nil }
    return .split(axis: ax, ratio: r, first: na, second: b)
  }

  /// Path to the innermost split along `axis` enclosing `pane`, plus
  /// whether the pane lies in its first child.
  public func enclosingSplit(
    of pane: PaneID,
    axis: SplitAxis
  ) -> (path: [Bool], paneIsFirst: Bool, ratio: Double)? {
    guard case let .split(ax, r, a, b) = self else { return nil }
    if a.contains(pane) {
      if let inner = a.enclosingSplit(of: pane, axis: axis) {
        return ([false] + inner.path, inner.paneIsFirst, inner.ratio)
      }
      return ax == axis ? ([], true, r) : nil
    }
    if b.contains(pane) {
      if let inner = b.enclosingSplit(of: pane, axis: axis) {
        return ([true] + inner.path, inner.paneIsFirst, inner.ratio)
      }
      return ax == axis ? ([], false, r) : nil
    }
    return nil
  }

  /// Whether ratios are finite and in (0, 1) and no pane repeats.
  public func isValid(maxDepth: Int = 32) -> Bool {
    guard depth <= maxDepth else { return false }
    let ids = panes
    guard Set(ids).count == ids.count else { return false }
    return ratiosValid
  }

  private var ratiosValid: Bool {
    switch self {
    case .pane: true
    case let .split(_, r, a, b):
      r.isFinite && r > 0 && r < 1 && a.ratiosValid && b.ratiosValid
    }
  }
}

/// An integer rectangle in cells or points.
public struct LayoutRect: Codable, Sendable, Hashable {
  public var x: Int
  public var y: Int
  public var width: Int
  public var height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public var maxX: Int { x + width }
  public var maxY: Int { y + height }

  public func contains(x px: Int, y py: Int) -> Bool {
    px >= x && px < maxX && py >= y && py < maxY
  }
}

/// A divider between two children of the split at `path`.
public struct LayoutDivider: Sendable, Hashable {
  public var rect: LayoutRect
  public var axis: SplitAxis
  public var path: [Bool]
  /// The extent shared by both children along the split axis.
  public var parent: LayoutRect
}

/// Maps a split tree onto an integer area. Both frontends use it with
/// their own units and divider thickness; the protocol has no mandatory
/// border. Areas too small for every pane yield zero-sized frames, which
/// frontends present clipped while retaining the previous pane sizes.
public enum LayoutGeometry {
  public static func frames(
    _ node: LayoutNode,
    in rect: LayoutRect,
    divider: Int
  ) -> [PaneID: LayoutRect] {
    var out: [PaneID: LayoutRect] = [:]
    var dividers: [LayoutDivider] = []
    walk(node, rect, divider, [], &out, &dividers)
    return out
  }

  public static func dividers(
    _ node: LayoutNode,
    in rect: LayoutRect,
    divider: Int
  ) -> [LayoutDivider] {
    var out: [PaneID: LayoutRect] = [:]
    var dividers: [LayoutDivider] = []
    walk(node, rect, divider, [], &out, &dividers)
    return dividers
  }

  /// Splits `length` minus the divider into first/second extents.
  public static func partition(
    _ length: Int,
    ratio: Double,
    divider: Int
  ) -> (first: Int, second: Int) {
    let usable = max(0, length - divider)
    let first = min(usable, max(0, Int((Double(usable) * ratio).rounded())))
    return (first, usable - first)
  }

  private static func walk(
    _ node: LayoutNode,
    _ rect: LayoutRect,
    _ divider: Int,
    _ path: [Bool],
    _ out: inout [PaneID: LayoutRect],
    _ dividers: inout [LayoutDivider]
  ) {
    switch node {
    case let .pane(id): out[id] = rect
    case let .split(axis, ratio, a, b):
      switch axis {
      case .leftRight:
        let (w1, w2) = partition(rect.width, ratio: ratio, divider: divider)
        let r1 = LayoutRect(
          x: rect.x,
          y: rect.y,
          width: w1,
          height: rect.height
        )
        let r2 = LayoutRect(
          x: rect.x + w1 + min(divider, rect.width),
          y: rect.y,
          width: w2,
          height: rect.height
        )
        dividers.append(
          LayoutDivider(
            rect: LayoutRect(
              x: rect.x + w1,
              y: rect.y,
              width: min(divider, rect.width),
              height: rect.height
            ),
            axis: axis,
            path: path,
            parent: rect
          )
        )
        walk(a, r1, divider, path + [false], &out, &dividers)
        walk(b, r2, divider, path + [true], &out, &dividers)
      case .topBottom:
        let (h1, h2) = partition(rect.height, ratio: ratio, divider: divider)
        let r1 = LayoutRect(x: rect.x, y: rect.y, width: rect.width, height: h1)
        let r2 = LayoutRect(
          x: rect.x,
          y: rect.y + h1 + min(divider, rect.height),
          width: rect.width,
          height: h2
        )
        dividers.append(
          LayoutDivider(
            rect: LayoutRect(
              x: rect.x,
              y: rect.y + h1,
              width: rect.width,
              height: min(divider, rect.height)
            ),
            axis: axis,
            path: path,
            parent: rect
          )
        )
        walk(a, r1, divider, path + [false], &out, &dividers)
        walk(b, r2, divider, path + [true], &out, &dividers)
      }
    }
  }

  /// The pane adjacent to `pane` in `direction`, choosing the neighbour
  /// overlapping the pane's centre line when several touch it.
  public static func neighbor(
    of pane: PaneID,
    direction: Direction,
    frames: [PaneID: LayoutRect],
    order: [PaneID]
  ) -> PaneID? {
    guard let r = frames[pane] else { return nil }
    var best: (PaneID, Int)?
    for id in order where id != pane {
      guard let o = frames[id] else { continue }
      let gap: Int
      let overlaps: Bool
      let centre: Bool
      switch direction {
      case .left:
        gap = r.x - o.maxX
        overlaps = o.y < r.maxY && o.maxY > r.y
        centre = (o.y ... o.maxY).contains(r.y + r.height / 2)
      case .right:
        gap = o.x - r.maxX
        overlaps = o.y < r.maxY && o.maxY > r.y
        centre = (o.y ... o.maxY).contains(r.y + r.height / 2)
      case .up:
        gap = r.y - o.maxY
        overlaps = o.x < r.maxX && o.maxX > r.x
        centre = (o.x ... o.maxX).contains(r.x + r.width / 2)
      case .down:
        gap = o.y - r.maxY
        overlaps = o.x < r.maxX && o.maxX > r.x
        centre = (o.x ... o.maxX).contains(r.x + r.width / 2)
      }
      guard gap >= 0, overlaps else { continue }
      let score = gap * 2 + (centre ? 0 : 1)
      if best == nil || score < best!.1 { best = (id, score) }
    }
    return best?.0
  }
}
