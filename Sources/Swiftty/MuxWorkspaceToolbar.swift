import AppKit
import SwiftMuxProtocol

/// Workspace tabs and actions in the native window toolbar.
@MainActor
final class MuxWorkspaceToolbar: NSObject, NSToolbarDelegate {
  static let tabsItem = NSToolbarItem.Identifier("swiftmux.tabs")
  static let newTabItem = NSToolbarItem.Identifier("swiftmux.new-tab")
  static let inboxItem = NSToolbarItem.Identifier("swiftmux.inbox")
  let toolbar = NSToolbar(identifier: "swiftmux.workspace")
  let tabs = NSToolbarItem(itemIdentifier: tabsItem)
  let newTab = NSToolbarItem(itemIdentifier: newTabItem)
  let item = NSToolbarItem(itemIdentifier: inboxItem)
  var onClick: (() -> Void)?
  var onNewTab: (() -> Void)?

  init(tabs tabStrip: MuxTabStrip) {
    super.init()
    tabs.label = "Workspace Tabs"
    tabs.view = tabStrip
    tabs.isBordered = false
    tabs.isNavigational = true
    tabs.visibilityPriority = .high
    newTab.label = "New Tab"
    newTab.toolTip = "New Tab"
    newTab.image = MuxIcons.image("plus", "New Tab")
    newTab.target = self
    newTab.action = #selector(newTabClicked)
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

  @objc
  private func newTabClicked() { onNewTab?() }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier id: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    switch id {
    case Self.tabsItem: tabs
    case Self.newTabItem: newTab
    case Self.inboxItem: item
    default: nil
    }
  }

  func toolbarDefaultItemIdentifiers(
    _ toolbar: NSToolbar
  ) -> [NSToolbarItem.Identifier] {
    [Self.tabsItem, .flexibleSpace, Self.newTabItem, Self.inboxItem]
  }

  func toolbarAllowedItemIdentifiers(
    _ toolbar: NSToolbar
  ) -> [NSToolbarItem.Identifier] {
    [Self.tabsItem, .flexibleSpace, Self.newTabItem, Self.inboxItem]
  }
}
