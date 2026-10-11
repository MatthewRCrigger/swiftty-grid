import AppKit
import MuxNavigation
import SwiftMuxProtocol
import SwifttyMac
import SwifttyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var windows: [TerminalWindowController] = []
  private var config = Configuration.load()
  /// The one native SwiftMux workspace window (one lease at a time).
  private var mux: MuxWorkspaceController?
  private let muxUpdate = MuxUpdateController()
  private lazy var attentionLinks = AttentionLinkRouter(
    ownsWorkspace: { [weak self] id in
      guard let mux = self?.mux else { return false }
      return mux.holdsLease && mux.attachedWorkspace == id
    },
    reveal: { [weak self] target, lease in
      try await self?.revealAttention(target, takeover: lease)
    }
  )

  /// `swiftty://attention/open?ref=…` and configured Universal Links
  /// (spec.inbox.md §4). Other URLs are rejected without
  /// contacting anything.
  func application(_ application: NSApplication, open urls: [URL]) {
    // A burst of links: only the newest navigates.
    guard let url = urls.last else { return }
    attentionLinks.handle(url)
  }

  func application(
    _ application: NSApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
  ) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL
    else { return false }
    attentionLinks.handle(url)
    return true
  }

  /// Opens (or reuses) the SwiftMux window on `target`'s workspace and
  /// activates the pane. `lease` is set only after the user confirmed a
  /// takeover; without it a held workspace fails with `leaseHeld`. A
  /// window that lost its lease (detached by another frontend) is never
  /// reused: it reattaches, and failures reach the navigator.
  private func revealAttention(
    _ target: PaneTarget,
    takeover lease: UInt64?
  ) async throws {
    NSApp.activate()
    // One SwiftMux window and lease at a time: the current one is left
    // only once the target is attached, so a refused attach (held
    // elsewhere, before the takeover is confirmed) keeps it.
    let previous = mux
    _ = try await MuxWorkspaceController.reveal(
      target,
      in: previous,
      configuration: config,
      connect: { try await MuxWorkspaceController.connect() },
      takeover: lease,
      attached: { controller in self.install(controller, replacing: previous) }
    )
  }

  /// Makes `controller` the SwiftMux window after it replaced `previous`.
  private func install(
    _ controller: MuxWorkspaceController,
    replacing previous: MuxWorkspaceController?
  ) {
    if let mux, mux !== previous {
      // Another window opened meanwhile: keep one lease.
      self.mux = nil
      Task {
        await mux.detach()
        mux.close()
      }
    }
    controller.onClose = { [weak controller] in
      if self.mux === controller { self.mux = nil }
    }
    // The inbox reattaching a window that lost its lease.
    controller.onReplaced = { [weak self, weak controller] replacement in
      self?.install(replacement, replacing: controller)
    }
    mux = controller
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.mainMenu = makeMenu()
    newWindow(nil)
    NSApp.activate()
    reportProblems()
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool { true }

  /// Quit only detaches: service-owned panes keep running and the agent
  /// stays registered.
  func applicationShouldTerminate(
    _ sender: NSApplication
  ) -> NSApplication.TerminateReply {
    guard let mux else { return .terminateNow }
    self.mux = nil
    Task {
      await mux.detach()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  // MARK: SwiftMux

  @objc
  func muxStageUpdate(_ sender: Any?) { muxUpdate.stage() }

  @objc
  func muxInstallUpdate(_ sender: Any?) {
    muxUpdate.install { [weak self] in
      guard let mux = self?.mux else { return }
      self?.mux = nil
      await mux.detach()
      mux.close()
    }
  }

  @objc
  func muxCancelUpdate(_ sender: Any?) { muxUpdate.cancel() }

  private func openMux(_ selector: WorkspaceSelector?) {
    if let mux {
      mux.showWindow(nil)
      return
    }
    let config = config
    Task {
      do {
        let controller = try await MuxWorkspaceController.open(
          selector,
          configuration: config
        )
        install(controller, replacing: nil)
        controller.showWindow(nil)
      } catch { NSAlert(error: error).runModal() }
    }
  }

  @objc
  func muxNewWorkspace(_ sender: Any?) { openMux(nil) }

  @objc
  func muxAttach(_ sender: Any?) {
    Task {
      do {
        let list = try await MuxWorkspaceController.listWorkspaces()
        guard !list.isEmpty else {
          let alert = NSAlert()
          alert.messageText = "No SwiftMux workspaces"
          alert.informativeText = "Create one with New Workspace."
          alert.runModal()
          return
        }
        let alert = NSAlert()
        alert.messageText = "Attach to Workspace"
        let popup = NSPopUpButton(
          frame: NSRect(x: 0, y: 0, width: 280, height: 26)
        )
        for ws in list {
          popup.addItem(
            withTitle: "\(ws.name) — \(ws.tabCount) tabs, \(ws.paneCount) panes"
              + (ws.isAttached ? " (attached)" : "")
          )
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Attach")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openMux(.id(list[popup.indexOfSelectedItem].id))
      } catch { NSAlert(error: error).runModal() }
    }
  }

  @objc
  func muxDetach(_ sender: Any?) {
    guard let mux else { return }
    self.mux = nil
    Task {
      await mux.detach()
      mux.close()
    }
  }

  @objc
  func muxNewTab(_ sender: Any?) { mux?.newTab() }

  @objc
  func muxSplitLeftRight(_ sender: Any?) { mux?.split(.leftRight) }

  @objc
  func muxSplitTopBottom(_ sender: Any?) { mux?.split(.topBottom) }

  @objc
  func muxZoom(_ sender: Any?) { mux?.toggleZoom() }

  @objc
  func muxEndPane(_ sender: Any?) { mux?.endPane() }

  @objc
  func muxCloseTab(_ sender: Any?) { mux?.closeTab() }

  @objc
  func muxRenameTab(_ sender: Any?) { mux?.beginRenamingActiveTab() }

  /// Focus and resize items carry their direction in the tag.
  @objc
  func muxFocusPane(_ sender: NSMenuItem) {
    Self.direction(sender.tag).map { mux?.focus($0) }
  }

  @objc
  func muxResizePane(_ sender: NSMenuItem) {
    Self.direction(sender.tag).map { mux?.resizeActivePane($0) }
  }

  private static let directions: [Direction] = [.left, .right, .up, .down]

  private static func direction(_ tag: Int) -> Direction? {
    directions.indices.contains(tag) ? directions[tag] : nil
  }

  @objc
  func muxNextTab(_ sender: Any?) { mux?.cycleTab(1) }

  @objc
  func muxPreviousTab(_ sender: Any?) { mux?.cycleTab(-1) }

  @objc
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(muxDetach(_:)), #selector(muxNewTab(_:)),
      #selector(muxSplitLeftRight(_:)), #selector(muxSplitTopBottom(_:)),
      #selector(muxZoom(_:)), #selector(muxEndPane(_:)),
      #selector(muxNextTab(_:)), #selector(muxPreviousTab(_:)),
      #selector(muxCloseTab(_:)), #selector(muxRenameTab(_:)),
      #selector(muxFocusPane(_:)), #selector(muxResizePane(_:)):
      mux != nil
    default: true
    }
  }

  @objc
  func newWindow(_ sender: Any?) {
    do {
      let controller = try TerminalWindowController(configuration: config)
      controller.onClose = { [weak self, weak controller] in
        self?.windows.removeAll { $0 === controller }
      }
      windows.append(controller)
      controller.showWindow(nil)
    } catch { NSAlert(error: error).runModal() }
  }

  @objc
  func reloadConfiguration(_ sender: Any?) {
    config = Configuration.load()
    NSApp.mainMenu = makeMenu()
    for window in windows { window.apply(config) }
    mux?.apply(config)
    reportProblems()
  }

  @objc
  func openConfiguration(_ sender: Any?) {
    let url = Configuration.defaultURL
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? "# swiftty configuration (Ghostty syntax)\n"
        .write(to: url, atomically: true, encoding: .utf8)
    }
    NSWorkspace.shared.open(url)
  }

  /// Configuration errors, shown as a sheet on the front window.
  private func reportProblems() {
    let problems =
      config.diagnostics + config.missingThemes.map { "theme not found: \($0)" }
    guard !problems.isEmpty else { return }
    for problem in problems {
      FileHandle.standardError.write(Data("swiftty: \(problem)\n".utf8))
    }
    let alert = NSAlert()
    alert.messageText = "Configuration problems"
    alert.informativeText =
      problems.prefix(10).joined(separator: "\n")
      + (problems.count > 10 ? "\n…" : "")
    if let window = NSApp.keyWindow ?? windows.first?.window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

  // MARK: Menus

  private func makeMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
      let item = NSMenuItem()
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      item.submenu = menu
      main.addItem(item)
    }
    submenu(
      "swiftty",
      [
        item("Settings…", #selector(openConfiguration(_:)), key: ","),
        item(
          "Reload Configuration",
          #selector(reloadConfiguration(_:)),
          key: ",",
          modifiers: [.command, .shift]
        ), .separator(),
        item("Quit swiftty", #selector(NSApplication.terminate(_:)), key: "q"),
      ]
    )
    submenu(
      "Shell",
      [
        item("New Window", #selector(newWindow(_:)), key: "n"),
        item("Close", #selector(NSWindow.performClose(_:)), key: "w"),
      ]
    )
    submenu("SwiftMux", muxMenuItems())
    submenu(
      "Edit",
      [
        item(
          "Copy",
          #selector(TerminalView.copy(_:)),
          action: .copyToClipboard
        ),
        item(
          "Paste",
          #selector(TerminalView.paste(_:)),
          action: .pasteFromClipboard
        ),
        item(
          "Select All",
          #selector(NSResponder.selectAll(_:)),
          action: .selectAll
        ),
        item(
          "Select Command Output",
          #selector(TerminalView.selectCommandOutput(_:))
        ), .separator(),
        item(
          "Find…",
          #selector(TerminalView.performFindPanelAction(_:)),
          action: .startSearch,
          tag: .showFindPanel
        ),
        item(
          "Find Next",
          #selector(TerminalView.performFindPanelAction(_:)),
          action: .navigateSearch(next: true),
          tag: .next
        ),
        item(
          "Find Previous",
          #selector(TerminalView.performFindPanelAction(_:)),
          action: .navigateSearch(next: false),
          tag: .previous
        ),
        item(
          "Use Selection for Find",
          #selector(TerminalView.performFindPanelAction(_:)),
          action: .searchSelection,
          tag: .setFindString,
        ),
      ]
    )
    submenu(
      "View",
      [
        item(
          "Bigger",
          #selector(TerminalView.increaseFontSize(_:)),
          action: .increaseFontSize(1)
        ),
        item(
          "Smaller",
          #selector(TerminalView.decreaseFontSize(_:)),
          action: .decreaseFontSize(1)
        ),
        item(
          "Reset Size",
          #selector(TerminalView.resetFontSize(_:)),
          action: .resetFontSize
        ), .separator(),
        item(
          "Previous Prompt",
          #selector(TerminalView.jumpToPreviousPrompt(_:)),
          action: .jumpToPrompt(-1)
        ),
        item(
          "Next Prompt",
          #selector(TerminalView.jumpToNextPrompt(_:)),
          action: .jumpToPrompt(1)
        ), .separator(),
        item(
          "Clear Screen",
          #selector(TerminalView.clearScreen(_:)),
          action: .clearScreen
        ),
        item(
          "Reset Terminal",
          #selector(TerminalView.resetTerminal(_:)),
          action: .reset
        ),
      ]
    )
    return main
  }

  /// A menu item whose shortcut is whatever `action` is bound to (the
  /// view's key bindings handle the key itself; this only shows it).
  private func muxMenuItems() -> [NSMenuItem] {
    func arrow(_ key: Int) -> String {
      String(UnicodeScalar(UInt16(key)).map(Character.init) ?? " ")
    }
    let arrows = [
      ("Left", NSLeftArrowFunctionKey), ("Right", NSRightArrowFunctionKey),
      ("Up", NSUpArrowFunctionKey), ("Down", NSDownArrowFunctionKey),
    ]
    func directional(
      _ verb: String,
      _ selector: Selector,
      _ modifiers: NSEvent.ModifierFlags
    ) -> [NSMenuItem] {
      arrows.enumerated()
        .map { i, a in
          let menuItem = item(
            "\(verb) \(a.0)",
            selector,
            key: arrow(a.1),
            modifiers: modifiers
          )
          menuItem.tag = i
          return menuItem
        }
    }
    return [
      item(
        "New Workspace",
        #selector(muxNewWorkspace(_:)),
        key: "n",
        modifiers: [.command, .control]
      ), item("Attach to Workspace…", #selector(muxAttach(_:))),
      item(
        "Detach",
        #selector(muxDetach(_:)),
        key: "d",
        modifiers: [.command, .control]
      ), .separator(), item("New Tab", #selector(muxNewTab(_:)), key: "t"),
      item("Rename Tab…", #selector(muxRenameTab(_:))),
      item(
        "Close Tab",
        #selector(muxCloseTab(_:)),
        key: "w",
        modifiers: [.command, .control]
      ),
      item(
        "Next Tab",
        #selector(muxNextTab(_:)),
        key: "]",
        modifiers: [.command, .shift]
      ),
      item(
        "Previous Tab",
        #selector(muxPreviousTab(_:)),
        key: "[",
        modifiers: [.command, .shift]
      ), .separator(),
      item("Split Left/Right", #selector(muxSplitLeftRight(_:)), key: "d"),
      item(
        "Split Top/Bottom",
        #selector(muxSplitTopBottom(_:)),
        key: "d",
        modifiers: [.command, .shift]
      ),
      item(
        "Zoom Pane",
        #selector(muxZoom(_:)),
        key: "\r",
        modifiers: [.command, .shift]
      ),
      item(
        "End Pane",
        #selector(muxEndPane(_:)),
        key: "w",
        modifiers: [.command, .option]
      ), .separator(),
    ]
      + directional(
        "Focus Pane",
        #selector(muxFocusPane(_:)),
        [.command, .option]
      ) + [.separator()]
      + directional(
        "Resize Pane",
        #selector(muxResizePane(_:)),
        [.command, .control]
      ) + [
        .separator(), item("Stage Update…", #selector(muxStageUpdate(_:))),
        item("Install Staged Update…", #selector(muxInstallUpdate(_:))),
        item("Cancel Update", #selector(muxCancelUpdate(_:))),
      ]
  }

  private func item(
    _ title: String,
    _ selector: Selector,
    action: KeyAction? = nil,
    key: String = "",
    modifiers: NSEvent.ModifierFlags = .command,
    tag: NSFindPanelAction? = nil,
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    if let action {
      if let trigger = config.keybindings.trigger(for: action),
        let equivalent = Self.keyEquivalent(trigger)
      {
        item.keyEquivalent = equivalent.key
        item.keyEquivalentModifierMask = equivalent.modifiers
      }
    } else {
      item.keyEquivalent = key
      item.keyEquivalentModifierMask = modifiers
    }
    if let tag { item.tag = Int(tag.rawValue) }
    return item
  }

  static func keyEquivalent(
    _ trigger: KeyTrigger
  ) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
    var mods: NSEvent.ModifierFlags = []
    if trigger.modifiers.contains(.command) { mods.insert(.command) }
    if trigger.modifiers.contains(.shift) { mods.insert(.shift) }
    if trigger.modifiers.contains(.control) { mods.insert(.control) }
    if trigger.modifiers.contains(.alt) { mods.insert(.option) }
    func function(_ key: Int) -> String {
      String(UnicodeScalar(UInt16(key)).map(Character.init) ?? " ")
    }
    let key: String? =
      switch trigger.key {
      case let .character(c): String(c)
      case .up: function(NSUpArrowFunctionKey)
      case .down: function(NSDownArrowFunctionKey)
      case .left: function(NSLeftArrowFunctionKey)
      case .right: function(NSRightArrowFunctionKey)
      case .home: function(NSHomeFunctionKey)
      case .end: function(NSEndFunctionKey)
      case .pageUp: function(NSPageUpFunctionKey)
      case .pageDown: function(NSPageDownFunctionKey)
      case .enter: "\r"
      case .tab: "\t"
      case .escape: "\u{1B}"
      case .backspace: "\u{8}"
      case .delete: function(NSDeleteFunctionKey)
      case let .function(n): function(NSF1FunctionKey + n - 1)
      case .insert: nil
      }
    return key.map { ($0, mods) }
  }
}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
  var onClose: (() -> Void)?
  let terminal: TerminalView
  private lazy var searchFieldEditor: SearchFieldEditor = {
    let editor = SearchFieldEditor(frame: .zero)
    editor.isFieldEditor = true
    editor.terminal = terminal
    return editor
  }()

  init(configuration: Configuration, columns: Int = 100, rows: Int = 30) throws
  {
    terminal = try TerminalView(configuration: configuration)
    let window = NSWindow(
      contentRect: NSRect(
        origin: .zero,
        size: terminal.preferredSize(columns: columns, rows: rows)
      ),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false,
    )
    window.title = "swiftty"
    window.center()
    window.tabbingMode = .disallowed
    super.init(window: window)
    window.delegate = self
    applyBackground(configuration)
    window.makeFirstResponder(terminal)
    terminal.onTitle = { [weak window] title in window?.title = title }
    terminal.onExit = { [weak window] in window?.close() }
    try terminal.start()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func apply(_ configuration: Configuration) {
    terminal.apply(configuration)
    applyBackground(configuration)
  }

  func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any?
  {
    guard let field = terminal.searchBar?.field,
      (client as? NSSearchField) === field
    else { return nil }
    return searchFieldEditor
  }

  /// Restores editing focus when changing the window's glass background.
  private func applyBackground(_ configuration: Configuration) {
    guard let window else { return }
    let focusedView: NSView? =
      if let field = terminal.searchBar?.field,
        window.firstResponder === field.currentEditor()
      {
        field
      } else if let view = window.firstResponder as? NSView,
        view === terminal || view.isDescendant(of: terminal)
      { view } else { nil }
    let selection = (focusedView as? NSControl)?.currentEditor()?.selectedRange
    let reparented = TerminalWindowBackground.apply(
      to: window,
      content: terminal,
      configuration: configuration
    )
    if reparented, let focusedView {
      window.makeFirstResponder(focusedView)
      if let selection, let control = focusedView as? NSControl {
        control.currentEditor()?.selectedRange = selection
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    terminal.stop()
    onClose?()
  }
}
