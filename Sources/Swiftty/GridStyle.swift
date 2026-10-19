import AppKit

/// GRID design-system tokens for AppKit chrome: true-black void, hairline
/// strokes, one amber accent that means "selected". Values are the
/// system's `tokens.json` defaults; signals are the sRGB form of its
/// OKLCH plane.
enum Grid {
  private static func hex(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
      green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255,
      alpha: alpha
    )
  }

  static let surface0 = hex(0x000000)
  static let surface1 = hex(0x060809)
  static let surface2 = hex(0x0c1013)
  static let surface3 = hex(0x141a1e)

  static let line100 = hex(0xd6eaf2)
  static let line200 = hex(0x8fa8b4)
  static let line300 = hex(0x4a5a63)
  static let line400 = hex(0x202a2f)

  static let ink100 = hex(0xe4f2f8)
  static let ink200 = hex(0xa8bcc6)
  static let ink300 = hex(0x6b7c85)

  /// Selected · primary.
  static let accent = hex(0xf4be4f)
  /// The accent while the app is in the background (`signal-amber-dim`).
  static let accentDim = hex(0x98742b)
  /// The accent now: dimmed while the app is not active, as macOS dims its
  /// own selection.
  @MainActor static var accentNow: NSColor {
    (NSApp?.isActive ?? true) ? accent : accentDim
  }
  /// Calls `selector` on `observer` when the app is activated or deactivated.
  @MainActor static func observeActivity(_ observer: NSObject, _ selector: Selector) {
    for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      NotificationCenter.default.addObserver(observer, selector: selector, name: name, object: nil)
    }
  }
  /// Ink on a solid accent fill.
  static let accentOn = hex(0x000000)
  /// Live · running · focus.
  static let live = hex(0x44daff)
  /// Nominal · exit 0.
  static let success = hex(0x74e29f)
  /// Alarm · non-zero exit.
  static let danger = hex(0xff655a)

  /// `type-label`: 12px · 600, tracked caps-style label face.
  static func labelFont(_ size: CGFloat = 12) -> NSFont {
    NSFont.systemFont(ofSize: max(12, size), weight: .semibold)
  }

  /// Tracked caps for interface labels (`type-label`: 0.18em). Display
  /// only: the model string is never changed.
  static func setCaps(_ field: NSTextField, _ text: String, color: NSColor) {
    let font = labelFont()
    field.attributedStringValue = NSAttributedString(
      string: text.uppercased(),
      attributes: [
        .font: font, .foregroundColor: color, .kern: font.pointSize * 0.18,
      ]
    )
  }

  /// Hairline stroke width; panel borders in the round profile are 2px.
  static let stroke: CGFloat = 1
  static let panelStroke: CGFloat = 2
  static let panelRadius: CGFloat = 8
  static let chipRadius: CGFloat = 2
}

/// A flat, hairline-framed view: the GRID replacement for a glass
/// container. Fill and stroke are resolved at draw time so they follow
/// state changes without re-layout.
@MainActor
class GridFlatView: NSView {
  var fillColor: NSColor? { didSet { needsDisplay = true } }
  var strokeColor: NSColor? { didSet { needsDisplay = true } }
  var strokeWidth: CGFloat = Grid.stroke { didSet { needsDisplay = true } }
  var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
  /// Subviews live here, as in the glass views this replaces.
  var contentView: NSView? {
    didSet {
      oldValue?.removeFromSuperview()
      guard let contentView else { return }
      contentView.frame = bounds
      contentView.autoresizingMask = [.width, .height]
      addSubview(contentView)
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    Grid.observeActivity(self, #selector(gridActivityChanged))
  }

  /// The app was activated or deactivated: subclasses redraw their accent.
  @objc func gridActivityChanged() { needsDisplay = true }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    guard let layer else { return }
    layer.cornerRadius = cornerRadius
    layer.borderWidth = strokeColor == nil ? 0 : strokeWidth
    layer.borderColor = strokeColor?.cgColor
    layer.backgroundColor = fillColor?.cgColor
  }
}
