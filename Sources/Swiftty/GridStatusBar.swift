import AppKit

/// What the status bar prints: machine state only, never a sentence.
struct GridStatus: Equatable {
  var theme: String
  var tab: String
  var columns: Int
  var rows: Int
  /// nil while the program runs.
  var exitStatus: Int32?

  var sizeText: String { "\(columns)x\(rows)" }

  var exitText: String {
    exitStatus.map { "exit \($0)" } ?? "running"
  }

  var exitColor: NSColor {
    switch exitStatus {
    case nil: Grid.live
    case 0: Grid.success
    default: Grid.danger
    }
  }

  /// 24-hour with seconds, as the system prints times.
  static func clock(_ date: Date) -> String {
    let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
    return String(
      format: "%02d:%02d:%02d",
      c.hour ?? 0,
      c.minute ?? 0,
      c.second ?? 0
    )
  }
}

/// The bottom rail: theme and tab at the left, a dotted leader, then size,
/// clock and exit state at the right.
@MainActor
final class GridStatusBar: NSView {
  static let height: CGFloat = 28
  private let left = GridStatusBar.label(Grid.accent)
  private let tab = GridStatusBar.label(Grid.ink200)
  private let size = GridStatusBar.label(Grid.ink200)
  private let clock = GridStatusBar.label(Grid.ink200)
  private let exit = GridStatusBar.label(Grid.live)
  private let leader = GridLeader()
  private var timer: Timer?

  var status = GridStatus(
    theme: "GRID",
    tab: "",
    columns: 0,
    rows: 0,
    exitStatus: nil
  ) {
    didSet {
      guard status != oldValue else { return }
      render()
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    let row = NSStackView(views: [left, tab, leader, size, clock, exit])
    row.orientation = .horizontal
    row.spacing = 16
    row.alignment = .centerY
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    leader.translatesAutoresizingMaskIntoConstraints = false
    leader.setContentHuggingPriority(.defaultLow, for: .horizontal)
    leader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
      leader.heightAnchor.constraint(equalToConstant: 8),
      leader.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
    ])
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
    setAccessibilityLabel("Status")
    render()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var wantsUpdateLayer: Bool { true }

  /// A `line-200` hairline on the top edge, over the void.
  override func updateLayer() {
    guard let layer else { return }
    layer.backgroundColor = Grid.surface0.cgColor
    layer.sublayers?.removeAll { $0.name == "top-rule" }
    let rule = CALayer()
    rule.name = "top-rule"
    rule.backgroundColor = Grid.line200.cgColor
    rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    layer.addSublayer(rule)
  }

  override func layout() {
    super.layout()
    needsDisplay = true
  }

  /// Ticks the clock once a second while attached to a window.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    timer?.invalidate()
    timer = nil
    guard window != nil else { return }
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    tick()
  }

  private func tick() {
    let text = GridStatus.clock(Date())
    if clock.stringValue != text { clock.stringValue = text }
  }

  private func render() {
    left.stringValue = status.theme
    tab.stringValue = status.tab
    size.stringValue = status.sizeText
    exit.stringValue = status.exitText
    exit.textColor = status.exitColor
    tick()
  }

  private static func label(_ color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.setAccessibilityElement(true)
    field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    return field
  }
}

/// The dotted leader: 1px, `line-300`, centred in its box.
@MainActor
final class GridLeader: NSView {
  override func draw(_ dirtyRect: NSRect) {
    Grid.line300.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1
    path.setLineDash([1, 3], count: 2, phase: 0)
    let y = (bounds.midY).rounded() + 0.5
    path.move(to: NSPoint(x: 0, y: y))
    path.line(to: NSPoint(x: bounds.width, y: y))
    path.stroke()
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 8)
  }
}
