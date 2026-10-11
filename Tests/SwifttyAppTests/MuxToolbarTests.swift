import AppKit
import SwiftMuxProtocol
@testable import Swiftty
import SwifttyCore
import Testing

extension MuxNativeTests {
  @Test(.enabled(if: hasMetal))
  func `workspace toolbar hosts tabs and dispatches native actions`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let window = try #require(c.window)
    c.confirmDestructive = { _ in true }
    let toolbar = c.workspaceToolbar
    let firstTab = try #require(c.activeTab?.id)
    #expect(window.toolbar === toolbar.toolbar)
    #expect(window.toolbarStyle == .unifiedCompact)
    #expect(toolbar.tabs.view === c.tabStrip)
    #expect(
      toolbar.toolbar.items.map(\.itemIdentifier) == [
        MuxWorkspaceToolbar.tabsItem, .flexibleSpace,
        MuxWorkspaceToolbar.newTabItem, MuxWorkspaceToolbar.inboxItem,
      ]
    )
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    let tabsRect = c.tabStrip.convert(c.tabStrip.bounds, to: nil)
    let panesRect = c.layoutView.convert(c.layoutView.bounds, to: nil)
    #expect(tabsRect.minY >= panesRect.maxY)
    #expect(abs(panesRect.maxY - window.contentLayoutRect.maxY) < 1)
    #expect(c.tabStrip.bounds.width >= 102)
    #expect(toolbar.tabs.isVisible)
    #expect(toolbar.newTab.isVisible && toolbar.item.isVisible)
    let firstButton = try #require(c.tabStrip.buttons.first)
    #expect(!firstButton.mouseDownCanMoveWindow)
    let frameView = try #require(window.contentView?.superview)
    let point = firstButton.convert(NSPoint(x: 20, y: 12), to: frameView)
    #expect(frameView.hitTest(point)?.isDescendant(of: firstButton) == true)

    let action = try #require(toolbar.newTab.action)
    #expect(
      NSApp.sendAction(action, to: toolbar.newTab.target, from: toolbar.newTab)
    )
    #expect(await until { c.workspace?.tabs.count == 2 })
    let secondTab = try #require(c.activeTab?.id)
    #expect(secondTab != firstTab)
    c.tabStrip.onSelect?(firstTab)
    #expect(await until { c.activeTab?.id == firstTab })
    c.tabStrip.onRename?(firstTab, "Renamed")
    #expect(await until { c.activeTab?.name == "Renamed" })
    let secondButton = try #require(
      c.tabStrip.buttons.first { $0.item?.id == secondTab }
    )
    secondButton.closeButton.performClick(nil)
    #expect(await until { c.workspace?.tabs.count == 1 })

    let originalFrame = window.frame
    for opacity in [1.0, 0.8] {
      var configuration = Configuration()
      configuration.backgroundOpacity = opacity
      c.apply(configuration)
      window.contentView?.superview?.layoutSubtreeIfNeeded()
      #expect(window.frame == originalFrame)
      #expect(window.toolbar === toolbar.toolbar)
      #expect(c.tabStrip.window === window)
      #expect(
        c.tabStrip.convert(c.tabStrip.bounds, to: nil).minY
          >= c.layoutView.convert(c.layoutView.bounds, to: nil).maxY
      )
    }
    let inboxAction = try #require(toolbar.item.action)
    #expect(
      NSApp.sendAction(inboxAction, to: toolbar.item.target, from: toolbar.item)
    )
    #expect(c.inboxView?.view.window != nil)
    c.toggleInbox()
  }

  @Test(.enabled(if: hasMetal))
  func `narrow workspace toolbars retain actions and scroll to the active tab`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let strip = f.controller.tabStrip
    let toolbar = f.controller.workspaceToolbar
    let window = try #require(f.controller.window)
    window.setContentSize(NSSize(width: 420, height: 200))
    let items = (0 ..< 12)
      .map { index in
        MuxTabItem(
          id: TabID(),
          title: "Workspace tab \(index)",
          symbol: "terminal",
          isActive: index == 11,
          hasActivity: false
        )
      }
    strip.update(items)
    window.contentView?.superview?.layoutSubtreeIfNeeded()
    strip.update(items)
    #expect(toolbar.tabs.isVisible)
    #expect(toolbar.newTab.isVisible && toolbar.item.isVisible)
    #expect(strip.bounds.width < strip.intrinsicContentSize.width)
    let active = try #require(strip.buttons.last)
    let visible = active.visibleRect
    #expect(visible.width > 0)
    #expect(visible.height == active.bounds.height)
    #expect(visible.contains(active.bounds))
    #expect(active.closeButton.visibleRect.contains(active.closeButton.bounds))
  }
}
