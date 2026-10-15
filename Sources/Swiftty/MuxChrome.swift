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
  /// The tab's stored name, which a rename edits; nil for an unnamed tab
  /// (the service's number), which shows its program instead.
  var name: String?
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
    layer?.backgroundColor = Grid.live.cgColor
  }

  override var wantsUpdateLayer: Bool { true }
}

// MARK: Tab strip

/// The window-level tab strip: icon, title, activity marker and close
/// button per tab. Double-click renames; narrow windows scroll horizontally.
@MainActor
final class MuxTabStrip: GridFlatView {
  var onSelect: ((TabID) -> Void)?
  var onClose: ((TabID) -> Void)?
  var onRename: ((TabID, String) -> Void)?
  /// A rename edit ended, however it did (renamed, unchanged, cancelled,
  /// or its field went away).
  var onRenameEnded: (() -> Void)?
  private let stack = NSStackView()
  private let scrollView = NSScrollView()
  private(set) var buttons: [MuxTabButton] = []

  override init(frame: NSRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    let content = NSView(frame: bounds)
    content.autoresizingMask = [.width, .height]
    contentView = content
    stack.orientation = .horizontal
    stack.spacing = 2
    stack.alignment = .centerY
    scrollView.drawsBackground = false
    scrollView.horizontalScrollElasticity = .none
    scrollView.verticalScrollElasticity = .none
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = stack
    content.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      scrollView.trailingAnchor.constraint(
        equalTo: trailingAnchor,
        constant: -6
      ), scrollView.centerYAnchor.constraint(equalTo: centerYAnchor),
      scrollView.heightAnchor.constraint(equalToConstant: 24),
      widthAnchor.constraint(greaterThanOrEqualToConstant: 102),
      heightAnchor.constraint(equalToConstant: 30),
    ])
    setContentHuggingPriority(.defaultHigh, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    setAccessibilityRole(.tabGroup)
    setAccessibilityLabel("Workspace tabs")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize {
    NSSize(width: max(102, stack.fittingSize.width + 12), height: 30)
  }

  override func layout() {
    super.layout()
    stack.setFrameSize(
      NSSize(
        width: max(stack.fittingSize.width, scrollView.bounds.width),
        height: 24
      )
    )
    stack.layoutSubtreeIfNeeded()
  }

  func update(_ items: [MuxTabItem]) {
    // Each tab keeps its button, and so any rename open on it, when other
    // tabs come or go; buttons of tabs gone are reused or removed.
    let shown = Set(items.map(\.id))
    var kept: [TabID: MuxTabButton] = [:]
    var spare: [MuxTabButton] = []
    for b in buttons {
      if let id = b.item?.id, shown.contains(id), kept[id] == nil {
        kept[id] = b
      } else {
        spare.append(b)
      }
    }
    let next = items.map { item in
      // Each button serves one tab, even if a snapshot repeats an id.
      let b =
        kept.removeValue(forKey: item.id) ?? spare.popLast() ?? MuxTabButton()
      b.strip = self
      b.item = item
      return b
    }
    for b in spare {
      // Showing no tab ends an open rename, so removal cannot commit it.
      b.item = nil
      stack.removeArrangedSubview(b)
      b.removeFromSuperview()
    }
    // Only buttons out of place move.
    for (i, b) in next.enumerated() {
      let arranged = stack.arrangedSubviews
      if i < arranged.count, arranged[i] === b { continue }
      stack.insertArrangedSubview(b, at: i)
    }
    buttons = next
    invalidateIntrinsicContentSize()
    needsLayout = true
    layoutSubtreeIfNeeded()
    if let active = buttons.first(where: { $0.item?.isActive == true }) {
      active.scrollToVisible(active.bounds)
    }
  }
}

/// Calls `action` with each window that becomes key while it lives (its
/// own registration, removed with it).
@MainActor
private final class KeyWindowWatcher: NSObject {
  private let action: (NSWindow) -> Void

  init(_ action: @escaping (NSWindow) -> Void) {
    self.action = action
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(changed(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )
  }

  @objc
  private func changed(_ notification: Notification) {
    if let key = notification.object as? NSWindow { action(key) }
  }
}

/// A tab title that reports an abandoned edit, which (unlike one that
/// ends) does not reach the delegate.
@MainActor
final class MuxTabLabel: NSTextField {
  var onAbort: (() -> Void)?

  @discardableResult
  override func abortEditing() -> Bool {
    let aborted = super.abortEditing()
    if aborted { onAbort?() }
    return aborted
  }
}

@MainActor
final class MuxTabButton: GridFlatView, NSTextFieldDelegate {
  weak var strip: MuxTabStrip?
  private let icon = NSImageView()
  let label = MuxTabLabel(labelWithString: "")
  private let dot = MuxActivityDot()
  let closeButton = NSButton()
  /// A rename is open. It renames `item`: setting `item` to another tab
  /// cancels it.
  private var renaming = false
  /// The person changed the rename's text since it opened; only then does
  /// ending it rename.
  private var edited = false
  /// While a rename is open: ends it when another window takes the keys.
  private var keyWatcher: KeyWindowWatcher?

  var item: MuxTabItem? {
    didSet {
      // An open rename belongs to the tab it began on: serving another
      // tab, or none, ends it without renaming.
      if oldValue?.id != item?.id { cancelRename() }
      guard let item, item != oldValue else { return }
      icon.image = MuxIcons.image(item.symbol, "")
      label.font = Grid.labelFont()
      // Selected is a solid accent fill with accent-on ink; the others
      // are a line-300 hairline with secondary ink.
      applyColors()
      dot.isHidden = !item.hasActivity
      showTitle()
      needsDisplay = true
    }
  }

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    cornerRadius = Grid.chipRadius
    let content = NSView(frame: bounds)
    content.autoresizingMask = [.width, .height]
    contentView = content
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.symbolConfiguration = .init(pointSize: 11, weight: .light)
    icon.setAccessibilityElement(false)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.delegate = self
    label.onAbort = { [weak self] in self?.cancelRename() }
    label.setAccessibilityElement(false)
    closeButton.image = MuxIcons.image("xmark", "End tab")
    closeButton.toolTip = "End Tab (terminates its processes)"
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

  override var mouseDownCanMoveWindow: Bool { false }

  private var hovering = false { didSet { applyColors() } }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self
      )
    )
  }

  override func mouseEntered(with event: NSEvent) { hovering = true }

  override func mouseExited(with event: NSEvent) { hovering = false }

  /// Selected: solid accent. Others: line-300 hairline and ink-200 text,
  /// brightening to line-100 and ink-100 under the pointer.
  private func applyColors() {
    guard let item else { return }
    let ink: NSColor =
      item.isActive ? Grid.accentOn : (hovering ? Grid.ink100 : Grid.ink200)
    fillColor = item.isActive ? Grid.accent : nil
    strokeColor =
      item.isActive ? Grid.accent : (hovering ? Grid.line100 : Grid.line300)
    label.textColor = ink
    icon.contentTintColor = ink
    closeButton.contentTintColor = ink
  }

  override func mouseDown(with event: NSEvent) {
    guard let item else { return }
    if event.clickCount == 2 {
      beginRename()
    } else {
      strip?.onSelect?(item.id)
    }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    // A fallback for an edit still open as its field changes window (a
    // toolbar moving for full screen): it cannot follow, so it ends as
    // losing focus does (typed text renames). Removing or hiding the field
    // ends an edit through the delegate before this runs.
    guard renaming, newWindow !== window else { return }
    endAsFocusLoss()
  }

  /// Ends the edit as losing focus does (typed text renames) when its
  /// field editor still holds the window's keys; otherwise, or if it would
  /// not end, drops it.
  private func endAsFocusLoss() {
    if let window, let editor = label.currentEditor(),
      window.firstResponder === editor
    {
      window.makeFirstResponder(nil)
    }
    cancelRename()
  }

  /// Ends an open edit without renaming: Escape, the label could not take
  /// focus, the button now serves another tab (or none), or (as a last
  /// resort) the field moved window, or another window took the keys,
  /// without its edit ending.
  /// AppKit abandoning the edit reports here too.
  private func cancelRename() {
    guard renaming else { return }
    // Closed first: however ending the field editor reports back, it finds
    // no rename open (and an editor AppKit already abandoned stays ended).
    renaming = false
    label.abortEditing()
    endEditing()
    strip?.onRenameEnded?()
  }

  func beginRename() {
    // A strip out of sight (a full-screen toolbar auto-hidden) has no field
    // to type in; a minimized window comes back below.
    guard !renaming, let item, let window,
      window.isVisible || window.isMiniaturized
    else { return }
    renaming = true
    edited = false
    label.isEditable = true
    label.isBezeled = false
    label.drawsBackground = false
    // Edit the whole stored name, not the shortened label. An unnamed tab
    // starts empty, its program's title (perhaps cut) a placeholder.
    label.stringValue = item.name ?? ""
    label.placeholderString = item.title
    guard window.makeFirstResponder(label) else { return cancelRename() }
    // The field's window must hold the keys for typing to reach it: a
    // rename from the menu may come while another window is in front, and
    // in full screen the strip lives in AppKit's toolbar window.
    window.makeKeyAndOrderFront(nil)
    label.currentEditor()?.selectAll(nil)
    // Any window: the keys may come back to the app in another one.
    keyWatcher = KeyWindowWatcher { [weak self] key in
      self?.keyWindowChanged(key)
    }
  }

  /// The keys moved to another of the app's windows (in full screen,
  /// from the toolbar window to the workspace; or back from another app
  /// into a different window): the edit ends as losing focus does. The app
  /// merely going inactive leaves it open.
  private func keyWindowChanged(_ key: NSWindow) {
    // Floating panels (a picker, an inspector) serve the edit rather than
    // end it; other panels, popovers among them, take the person elsewhere.
    guard renaming, key !== window, (key as? NSPanel)?.isFloatingPanel != true
    else { return }
    endAsFocusLoss()
  }

  /// Escape cancels the rename.
  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy selector: Selector
  ) -> Bool {
    guard selector == #selector(NSResponder.cancelOperation(_:)) else {
      return false
    }
    cancelRename()
    return true
  }

  func controlTextDidChange(_ obj: Notification) { edited = true }

  func controlTextDidEndEditing(_ obj: Notification) {
    guard renaming else { return }
    renaming = false
    let typed = label.stringValue
    endEditing()
    defer { strip?.onRenameEnded?() }
    // Only typing renames, and only to a name the tab does not hold now
    // (another client may have renamed it meanwhile). A cancel movement
    // (an input method, accessibility; Escape cancels before this) renames
    // nothing. The label shows the stored title until a rename lands.
    let movement = obj.userInfo?[NSText.movementUserInfoKey] as? Int
    guard edited, movement != NSTextMovement.cancel.rawValue, let item,
      let name = DisplayText.plainName(typed), name != item.name
    else { return }
    strip?.onRename?(item.id, name)
  }

  private func endEditing() {
    keyWatcher = nil
    label.isEditable = false
    label.isSelectable = false
    label.placeholderString = nil
    showTitle()
  }

  /// Shows the tab's title, or while a name is being typed, its
  /// placeholder.
  private func showTitle() {
    guard let item else { return }
    if renaming {
      label.placeholderString = item.title
    } else {
      label.stringValue = item.title
    }
    closeButton.setAccessibilityLabel("End tab \(item.title)")
    setAccessibilityLabel(item.title + (item.hasActivity ? ", new output" : ""))
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

/// A pane's header (icon, title, actions) above its Metal view.
/// In a split tab the pane is a rounded card: header on top, the terminal
/// inset below it. A single pane fills its area with no header.
@MainActor
final class MuxPaneContainer: NSView {
  static let headerHeight: CGFloat = 30
  static let cornerRadius: CGFloat = Grid.panelRadius
  /// Space between the card's edge and its terminal (sides and bottom).
  static let cardInset: CGFloat = 6
  let paneView: MuxPaneView
  let header = MuxPaneHeader()
  var showsHeader = true {
    didSet {
      header.isHidden = !showsHeader
      if oldValue != showsHeader {
        needsLayout = true
        needsDisplay = true
      }
    }
  }

  init(paneView: MuxPaneView) {
    self.paneView = paneView
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerCurve = .continuous
    addSubview(header)
    addSubview(paneView)
    setAccessibilityElement(true)
    setAccessibilityRole(.group)
  }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    guard let layer else { return }
    // Round panel profile: 2px border, 8px corners, surface-1 fill. The
    // active pane's frame is the accent; the rest sit at line-200.
    layer.cornerRadius = showsHeader ? Self.cornerRadius : 0
    layer.masksToBounds = showsHeader
    layer.borderWidth = showsHeader ? Grid.panelStroke : 0
    layer.borderColor =
      (header.state.isActive ? Grid.accent : Grid.line200).cgColor
    layer.backgroundColor = showsHeader ? Grid.surface1.cgColor : nil
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layout() {
    super.layout()
    let h = showsHeader ? min(Self.headerHeight, bounds.height) : 0
    let inset = showsHeader ? Self.cardInset : 0
    header.frame = NSRect(
      x: 0,
      y: bounds.height - h,
      width: bounds.width,
      height: h
    )
    // Re-adding a removed pane view (tests) must restore its frame.
    if paneView.superview === self {
      paneView.frame = NSRect(
        x: inset,
        y: inset,
        width: max(0, bounds.width - 2 * inset),
        height: max(0, bounds.height - h - inset)
      )
    }
  }

  override func didAddSubview(_ subview: NSView) {
    super.didAddSubview(subview)
    needsLayout = true
  }

  func update(_ state: MuxPaneHeaderState) {
    header.state = state
    needsDisplay = true
    setAccessibilityLabel(
      "Pane \(state.title)" + (state.isActive ? ", active" : "")
        + (state.hasExited ? ", exited" : "")
    )
    paneView.setAccessibilityLabel("Terminal: \(state.title)")
  }
}

@MainActor
final class MuxPaneHeader: NSView {
  enum Action { case splitRight, splitDown, zoom, close }
  var onAction: ((Action) -> Void)?
  /// The program's icon, chosen locally from its title (`MuxIcons`).
  private let icon = NSImageView()
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
      // The active pane reads at full strength, the others dimmed.
      label.textColor = state.isActive ? Grid.ink100 : Grid.ink300
      icon.contentTintColor = label.textColor
      icon.image = MuxIcons.image(MuxIcons.symbol(for: state.title), "")
      dot.isHidden = !state.hasActivity
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
    // Part of the card: no band or separator of its own.
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.symbolConfiguration = .init(pointSize: 12, weight: .light)
    icon.setAccessibilityElement(false)
    label.font = Grid.labelFont()
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
    for v in [icon, label, dot, buttons] as [NSView] { addSubview(v) }
    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 16),
      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      buttons.leadingAnchor.constraint(
        greaterThanOrEqualTo: dot.trailingAnchor,
        constant: 6
      ),
      buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
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
