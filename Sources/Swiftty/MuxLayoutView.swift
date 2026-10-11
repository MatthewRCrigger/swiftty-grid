import AppKit
import SwiftMuxProtocol

/// Lays out pane views from the logical split tree; dividers drag.
@MainActor
final class MuxLayoutView: NSView {
  static let divider = 4
  weak var controller: MuxWorkspaceController?
  private(set) var dividers: [LayoutDivider] = []
  private var dragging: LayoutDivider?
  private var dividerElements: [MuxDividerElement] = []

  override var isFlipped: Bool { false }

  override func layout() {
    super.layout()
    guard let controller else { return }
    let (panes, dividers) = controller.layout(in: bounds)
    self.dividers = dividers
    let shown = Set(panes.map { ObjectIdentifier($0.0) })
    for view in subviews where !shown.contains(ObjectIdentifier(view)) {
      view.isHidden = true
    }
    for (view, frame) in panes {
      view.isHidden = false
      view.frame = frame
    }
    window?.invalidateCursorRects(for: self)
    dividerElements = dividers.map { d in
      let element = MuxDividerElement(divider: d, in: self)
      element.setAccessibilityFrameInParentSpace(appKitRect(d.rect))
      return element
    }
  }

  func appKitRect(_ r: LayoutRect) -> NSRect {
    NSRect(
      x: r.x,
      y: Int(bounds.height) - r.maxY,
      width: r.width,
      height: r.height
    )
  }

  override func accessibilityChildren() -> [Any]? {
    (super.accessibilityChildren() ?? []) + dividerElements
  }

  private func flippedY(_ p: NSPoint) -> Int { Int(bounds.height - p.y) }

  override func resetCursorRects() {
    for d in dividers {
      addCursorRect(
        appKitRect(d.rect),
        cursor: d.axis == .leftRight ? .resizeLeftRight : .resizeUpDown
      )
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if dividers.contains(where: {
      $0.rect.contains(x: Int(local.x), y: flippedY(local))
    }) {
      return self
    }
    return super.hitTest(point)
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    dragging = dividers.first { $0.rect.contains(x: Int(p.x), y: flippedY(p)) }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let d = dragging else { return }
    let p = convert(event.locationInWindow, from: nil)
    let ratio =
      d.axis == .leftRight
      ? (Double(p.x) - Double(d.parent.x)) / Double(max(1, d.parent.width))
      : (Double(flippedY(p)) - Double(d.parent.y))
        / Double(max(1, d.parent.height))
    controller?.setRatio(ratio, path: d.path)
  }

  override func mouseUp(with event: NSEvent) { dragging = nil }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    bounds.fill()
  }
}

/// A split handle for assistive technologies: its value is the first
/// child's share; increment and decrement move it in 5% steps.
/// AppKit calls accessibility on the main thread.
final class MuxDividerElement: NSAccessibilityElement {
  let divider: LayoutDivider
  private weak var layoutView: MuxLayoutView?

  @MainActor
  init(divider: LayoutDivider, in view: MuxLayoutView) {
    self.divider = divider
    layoutView = view
    super.init()
    setAccessibilityParent(view)
    setAccessibilityRole(.splitter)
    setAccessibilityOrientation(
      divider.axis == .leftRight ? .vertical : .horizontal
    )
    setAccessibilityLabel(
      divider.axis == .leftRight ? "Left/right divider" : "Top/bottom divider"
    )
  }

  override func accessibilityValue() -> Any? {
    let (view, path) = (layoutView, divider.path)
    return MainActor.assumeIsolated { view?.controller?.ratio(at: path) }
      .map { $0 as NSNumber }
  }

  override func accessibilityPerformIncrement() -> Bool { move(0.05) }
  override func accessibilityPerformDecrement() -> Bool { move(-0.05) }

  private func move(_ delta: Double) -> Bool {
    let (view, path) = (layoutView, divider.path)
    return MainActor.assumeIsolated {
      guard let controller = view?.controller,
        let ratio = controller.ratio(at: path)
      else { return false }
      controller.setRatio(ratio + delta, path: path)
      return true
    }
  }
}

struct RatioProposal: Equatable {
  var tab: TabID
  var path: [Bool]
  var ratio: Double
}

struct MuxUnavailable: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}
