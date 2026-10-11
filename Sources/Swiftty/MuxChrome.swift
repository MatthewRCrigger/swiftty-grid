import AppKit
import SwiftMuxProtocol

/// Local presentation of one workspace tab. Icons are chosen here from a
/// fixed symbol set; nothing a program sends picks an image.
struct MuxTabItem: Equatable {
  var id: TabID
  var title: String
  var symbol: String
  var isActive: Bool
  var hasActivity: Bool
}

enum MuxIcons {
  /// An SF Symbol for a sanitized title, from a fixed local table.
  static func symbol(for title: String) -> String {
    let t = title.lowercased()
    let table: [([String], String)] = [
      (["git", "tig", "lazygit", "gitui"], "arrow.triangle.branch"),
      (["claude", "assistant", "codex", "aider", "copilot"], "sparkles"),
      (["snake", "game", "tetris", "nethack", "2048"], "gamecontroller"),
      (["vim", "nvim", "emacs", "nano", "hx", "helix"], "doc.text"),
      (["top", "htop", "btop"], "chart.bar"), (["ssh", "mosh"], "network"),
      (["less", "man", "more"], "book"),
    ]
    let words = t.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    for (keys, symbol) in table where keys.contains(where: words.contains) {
      return symbol
    }
    return "terminal"
  }

  static func image(_ symbol: String, _ label: String) -> NSImage? {
    NSImage(systemSymbolName: symbol, accessibilityDescription: label)
  }
}

/// A small filled circle marking unseen output.
@MainActor
final class MuxActivityDot: NSView {
  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.cornerRadius = 3
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 6),
      heightAnchor.constraint(equalToConstant: 6),
    ])
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func updateLayer() {
    layer?.backgroundColor = NSColor.controlAccentColor.cgColor
  }

  override var wantsUpdateLayer: Bool { true }
}

// MARK: Tab strip

/// The window-level tab strip: icon, title, activity marker and close
/// button per tab, plus a new-tab button. Double-click renames.
@MainActor
final class MuxTabStrip: NSGlassEffectContainerView {
  var onSelect: ((TabID) -> Void)?
  var onClose: ((TabID) -> Void)?
  var onRename: ((TabID, String) -> Void)?
  var onNew: (() -> Void)?

  private let stack = NSStackView()
  private let newButton = NSButton()
  private(set) var buttons: [MuxTabButton] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    let content = NSView(frame: bounds)
    content.autoresizingMask = [.width, .height]
    contentView = content
    stack.orientation = .horizontal
    stack.spacing = 2
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    newButton.image = MuxIcons.image("plus", "New Tab")
    newButton.bezelStyle = .glass
    newButton.target = self
    newButton.action = #selector(newClicked)
    newButton.toolTip = "New Tab"
    newButton.setAccessibilityLabel("New Tab")
    newButton.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    content.addSubview(newButton)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.trailingAnchor.constraint(
        lessThanOrEqualTo: newButton.leadingAnchor,
        constant: -4
      ),
      newButton.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -6
      ), newButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      heightAnchor.constraint(equalToConstant: 30),
    ])
    setAccessibilityRole(.tabGroup)
    setAccessibilityLabel("Workspace tabs")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  @objc
  private func newClicked() { onNew?() }

  func update(_ items: [MuxTabItem]) {
    while buttons.count > items.count {
      let b = buttons.removeLast()
      stack.removeArrangedSubview(b)
      b.removeFromSuperview()
    }
    while buttons.count < items.count {
      let b = MuxTabButton()
      b.strip = self
      buttons.append(b)
      stack.addArrangedSubview(b)
    }
    for (b, item) in zip(buttons, items) { b.item = item }
  }
}

@MainActor
final class MuxTabButton: NSGlassEffectView, NSTextFieldDelegate {
  weak var strip: MuxTabStrip?
  private let icon = NSImageView()
  let label = NSTextField(labelWithString: "")
  private let dot = MuxActivityDot()
  let closeButton = NSButton()
  private var editing = false

  var item: MuxTabItem? {
    didSet {
      guard let item, item != oldValue else { return }
      icon.image = MuxIcons.image(item.symbol, "")
      if !editing { label.stringValue = item.title }
      label.font =
        item.isActive
        ? .systemFont(ofSize: 12, weight: .semibold) : .systemFont(ofSize: 12)
      tintColor =
        item.isActive
        ? .selectedContentBackgroundColor.withAlphaComponent(0.18) : nil
      dot.isHidden = !item.hasActivity
      closeButton.setAccessibilityLabel("Close tab \(item.title)")
      setAccessibilityLabel(
        item.title + (item.hasActivity ? ", new output" : "")
      )
      needsDisplay = true
    }
  }

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    style = .regular
    cornerRadius = 6
    effectIsInteractive = true
    let content = NSView(frame: bounds)
    content.autoresizingMask = [.width, .height]
    contentView = content
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
    icon.setAccessibilityElement(false)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.delegate = self
    label.setAccessibilityElement(false)
    closeButton.image = MuxIcons.image("xmark", "Close tab")
    closeButton.isBordered = false
    closeButton.bezelStyle = .accessoryBarAction
    closeButton.target = self
    closeButton.action = #selector(closeClicked)
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    for v in [icon, label, dot, closeButton] as [NSView] {
      content.addSubview(v)
    }
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 24),
      widthAnchor.constraint(lessThanOrEqualToConstant: 220),
      widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.leadingAnchor.constraint(
        equalTo: dot.trailingAnchor,
        constant: 4
      ),
      closeButton.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -6
      ), closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setAccessibilityElement(true)
    setAccessibilityRole(.radioButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) {
    guard let item else { return }
    if event.clickCount == 2 {
      beginRename()
    } else {
      strip?.onSelect?(item.id)
    }
  }

  func beginRename() {
    editing = true
    label.isEditable = true
    label.isBezeled = false
    label.drawsBackground = false
    window?.makeFirstResponder(label)
    label.currentEditor()?.selectAll(nil)
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard editing, let item else { return }
    editing = false
    label.isEditable = false
    let name = DisplayText.sanitize(label.stringValue)
    if name.isEmpty || name == item.title {
      label.stringValue = item.title
    } else {
      strip?.onRename?(item.id, name)
    }
  }

  @objc
  private func closeClicked() { if let item { strip?.onClose?(item.id) } }

  override func accessibilityValue() -> Any? { item?.isActive == true }

  override func accessibilityPerformPress() -> Bool {
    guard let item else { return false }
    strip?.onSelect?(item.id)
    return true
  }
}

// MARK: Pane chrome

/// What the header shows for one pane.
struct MuxPaneHeaderState: Equatable {
  var title: String
  var isActive: Bool
  var hasActivity: Bool
  var isZoomed: Bool
  var hasExited: Bool
}

/// A pane's header (title, active marker, actions) above its Metal view.
@MainActor
final class MuxPaneContainer: NSView {
  static let headerHeight: CGFloat = 22
  let paneView: MuxPaneView
  let header = MuxPaneHeader()
  var showsHeader = true {
    didSet {
      header.isHidden = !showsHeader
      if oldValue != showsHeader { needsLayout = true }
    }
  }

  init(paneView: MuxPaneView) {
    self.paneView = paneView
    super.init(frame: .zero)
    addSubview(header)
    addSubview(paneView)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let h = showsHeader ? min(Self.headerHeight, bounds.height) : 0
    header.frame = NSRect(
      x: 0,
      y: bounds.height - h,
      width: bounds.width,
      height: h
    )
    // Re-adding a removed pane view (tests) must restore its frame.
    if paneView.superview === self {
      paneView.frame = NSRect(
        x: 0,
        y: 0,
        width: bounds.width,
        height: bounds.height - h
      )
    }
  }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    needsLayout = true
  }

  func update(_ state: MuxPaneHeaderState) {
    header.state = state
    setAccessibilityLabel(
      "Pane \(state.title)" + (state.isActive ? ", active" : "")
        + (state.hasExited ? ", exited" : "")
    )
    paneView.setAccessibilityLabel("Terminal: \(state.title)")
  }
}

@MainActor
final class MuxPaneHeader: NSGlassEffectView {
  enum Action { case splitRight, splitDown, zoom, close }
  var onAction: ((Action) -> Void)?
  private let marker = NSView()
  private let label = NSTextField(labelWithString: "")
  private let dot = MuxActivityDot()
  private(set) var actionButtons: [Action: NSButton] = [:]

  var state = MuxPaneHeaderState(
    title: "",
    isActive: false,
    hasActivity: false,
    isZoomed: false,
    hasExited: false
  ) {
    didSet {
      guard state != oldValue else { return }
      label.stringValue =
        state.hasExited ? "\(state.title) (exited)" : state.title
      label.textColor = state.isActive ? .labelColor : .secondaryLabelColor
      dot.isHidden = !state.hasActivity
      marker.isHidden = !state.isActive
      actionButtons[.zoom]?.image = MuxIcons.image(
        state.isZoomed
          ? "arrow.down.right.and.arrow.up.left"
          : "arrow.up.left.and.arrow.down.right",
        "Zoom"
      )
      actionButtons[.zoom]?
        .setAccessibilityLabel(state.isZoomed ? "Unzoom pane" : "Zoom pane")
    }
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    style = .regular
    cornerRadius = 6
    effectIsInteractive = true
    let content = NSView(frame: bounds)
    content.autoresizingMask = [.width, .height]
    contentView = content
    marker.wantsLayer = true
    marker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    marker.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 11)
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let buttons = NSStackView()
    buttons.orientation = .horizontal
    buttons.spacing = 2
    buttons.translatesAutoresizingMaskIntoConstraints = false
    for (action, symbol, title) in [
      (Action.splitRight, "rectangle.split.2x1", "Split right"),
      (.splitDown, "rectangle.split.1x2", "Split down"),
      (.zoom, "arrow.up.left.and.arrow.down.right", "Zoom pane"),
      (.close, "xmark", "End pane"),
    ] {
      let b = NSButton()
      b.image = MuxIcons.image(symbol, title)
      b.isBordered = false
      b.bezelStyle = .accessoryBarAction
      b.toolTip = title
      b.setAccessibilityLabel(title)
      b.target = self
      b.action = #selector(clicked(_:))
      b.tag = [.splitRight, .splitDown, .zoom, .close].firstIndex(of: action)!
      actionButtons[action] = b
      buttons.addArrangedSubview(b)
    }
    for v in [marker, label, dot, buttons] as [NSView] { content.addSubview(v) }
    NSLayoutConstraint.activate([
      marker.leadingAnchor.constraint(equalTo: leadingAnchor),
      marker.topAnchor.constraint(equalTo: topAnchor),
      marker.bottomAnchor.constraint(equalTo: bottomAnchor),
      marker.widthAnchor.constraint(equalToConstant: 3),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      buttons.leadingAnchor.constraint(
        greaterThanOrEqualTo: dot.trailingAnchor,
        constant: 6
      ),
      buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    marker.isHidden = true
    dot.isHidden = true
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  @objc
  private func clicked(_ sender: NSButton) {
    let actions: [Action] = [.splitRight, .splitDown, .zoom, .close]
    onAction?(actions[sender.tag])
  }
}
