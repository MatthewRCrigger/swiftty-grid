import AppKit
import SwiftMuxProtocol

/// The window's mirror of the service attention inbox (unified spec §8):
/// current requests, unreviewed failures and results. The service owns
/// the reduction; this only applies its pages and coalesced updates.
struct MuxInboxModel: Equatable {
  private(set) var items: [OccurrenceID: AttentionItem] = [:]
  private(set) var counts = InboxCounts()
  private(set) var revision: UInt64 = 0

  /// Whether the inbox shows `item`: a waiting request or an unreviewed
  /// failure or result.
  static func shows(_ item: AttentionItem) -> Bool {
    switch item.category {
    case .needsYou: item.resolution == .open
    case .failure, .result:
      item.resolution == .open || item.resolution == .paneExited
    }
  }

  /// Adopts freshly read pages, keeping items a newer update already
  /// delivered.
  mutating func reset(_ pages: [InboxPage]) {
    guard let read = pages.map(\.revision).min() else { return }
    let listed = Set(pages.flatMap(\.items).map(\.occurrence))
    items = items.filter { listed.contains($0.key) || $0.value.revision > read }
    for item in pages.flatMap(\.items) { merge(item) }
    if let newest = pages.max(by: { $0.revision < $1.revision }),
      newest.revision >= revision
    {
      counts = newest.counts
      revision = newest.revision
    }
  }

  /// Applies one update; true when the caller must refetch (`resync`).
  mutating func apply(_ update: InboxUpdate) -> Bool {
    for id in update.removed { items[id] = nil }
    for item in update.changed { merge(item) }
    if update.revision >= revision {
      counts = update.counts
      revision = update.revision
    }
    return update.resync
  }

  private mutating func merge(_ item: AttentionItem) {
    if let known = items[item.occurrence], known.revision > item.revision {
      return  // a stale delta
    }
    items[item.occurrence] = Self.shows(item) ? item : nil
  }

  /// Requests, then failures, then results; newest first within each.
  var sorted: [AttentionItem] {
    items.values.sorted {
      let a = Self.rank($0.category)
      let b = Self.rank($1.category)
      return a != b ? a < b : $0.createdAt > $1.createdAt
    }
  }

  private static func rank(_ c: AttentionCategory) -> Int {
    switch c {
    case .needsYou: 0
    case .failure: 1
    case .result: 2
    }
  }

  /// Plain-text heading and detail. Program text is untrusted: it is
  /// sanitized and never rendered as markup or links.
  static func text(_ item: AttentionItem) -> (heading: String, detail: String) {
    let s = item.status
    let what: String =
      switch item.category {
      case .needsYou:
        switch s.kind {
        case .permission?: "Needs permission"
        case .auth?: "Needs authentication"
        case .question?, nil: "Needs an answer"
        }
      case .failure: "Failed"
      case .result: "Done"
      }
    let program = [s.app, s.title].compactMap { $0 }
      .map { DisplayText.sanitize($0) }.filter { !$0.isEmpty }
      .joined(separator: " — ")
    let heading = program.isEmpty ? what : "\(what): \(program)"
    var detail = s.message.map { DisplayText.sanitize($0, limit: 300) } ?? ""
    if item.resolution == .paneExited {
      detail += detail.isEmpty ? "Pane exited" : " (pane exited)"
    }
    return (heading, detail)
  }
}

/// The inbox popover: one row per item with "Open in Pane" and, for
/// failures and results, "Mark Reviewed".
@MainActor
final class MuxInboxViewController: NSViewController {
  var onOpen: ((AttentionItem) -> Void)?
  var onReview: ((AttentionItem) -> Void)?
  /// Items shown since the popover opened (marked seen once).
  var onShown: (([AttentionItem]) -> Void)?
  private let stack = NSStackView()
  private(set) var shown: [AttentionItem] = []

  override func loadView() {
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let document = FlippedView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    let scroll = NSScrollView(
      frame: NSRect(x: 0, y: 0, width: 380, height: 320)
    )
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    scroll.documentView = document
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: document.topAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ])
    view = scroll
    preferredContentSize = scroll.frame.size
  }

  func update(_ model: MuxInboxModel) {
    _ = view
    let items = model.sorted
    shown = items
    for row in stack.arrangedSubviews { row.removeFromSuperview() }
    if items.isEmpty {
      stack.addArrangedSubview(
        NSTextField(labelWithString: "Nothing needs you.")
      )
    }
    for item in items { stack.addArrangedSubview(row(item)) }
    onShown?(items)
  }

  private func row(_ item: AttentionItem) -> NSView {
    let text = MuxInboxModel.text(item)
    let heading = NSTextField(labelWithString: text.heading)
    heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    heading.lineBreakMode = .byTruncatingTail
    // Plain labels: no link detection, rich text or editing.
    let detail = NSTextField(wrappingLabelWithString: text.detail)
    detail.allowsEditingTextAttributes = false
    detail.isSelectable = false
    detail.textColor = .secondaryLabelColor
    detail.preferredMaxLayoutWidth = 340
    detail.isHidden = text.detail.isEmpty
    let open = ActionButton(title: "Open in Pane") { [weak self] in
      self?.onOpen?(item)
    }
    var buttons: [NSView] = [open]
    if item.category != .needsYou {
      buttons.append(
        ActionButton(title: "Mark Reviewed") { [weak self] in
          self?.onReview?(item)
        }
      )
    }
    let actions = NSStackView(views: buttons)
    actions.orientation = .horizontal
    let row = NSStackView(views: [heading, detail, actions])
    row.orientation = .vertical
    row.alignment = .leading
    row.spacing = 4
    row.setAccessibilityElement(true)
    row.setAccessibilityLabel(
      [text.heading, text.detail].filter { !$0.isEmpty }.joined(separator: ". ")
    )
    return row
  }

  private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
  }

  /// A push button running a closure.
  final class ActionButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, _ handler: @escaping () -> Void) {
      self.init(frame: .zero)
      self.title = title
      bezelStyle = .push
      controlSize = .small
      self.handler = handler
      target = self
      action = #selector(run)
    }

    @objc
    private func run() { handler() }
  }
}

/// The window toolbar holding the inbox button and its needs-you badge.
@MainActor
final class MuxInboxToolbar: NSObject, NSToolbarDelegate {
  static let inboxItem = NSToolbarItem.Identifier("swiftmux.inbox")
  let toolbar = NSToolbar(identifier: "swiftmux.workspace")
  let item = NSToolbarItem(itemIdentifier: inboxItem)
  var onClick: (() -> Void)?

  override init() {
    super.init()
    item.label = "Inbox"
    item.paletteLabel = "Attention Inbox"
    item.toolTip = "Programs waiting for you, failures and results"
    item.image = MuxIcons.image("tray", "Attention inbox")
    item.target = self
    item.action = #selector(clicked)
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
  }

  func update(_ counts: InboxCounts) {
    item.badge = counts.needsYou > 0 ? .count(counts.needsYou) : nil
    item.image = MuxIcons.image(
      counts.needsYou + counts.results > 0 ? "tray.full" : "tray",
      "Attention inbox"
    )
    item.label = counts.needsYou > 0 ? "Inbox (\(counts.needsYou))" : "Inbox"
  }

  @objc
  private func clicked() { onClick?() }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? { id == Self.inboxItem ? item : nil }

  func toolbarDefaultItemIdentifiers(
    _ toolbar: NSToolbar
  ) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.inboxItem] }

  func toolbarAllowedItemIdentifiers(
    _ toolbar: NSToolbar
  ) -> [NSToolbarItem.Identifier] { [.flexibleSpace, Self.inboxItem] }
}
