import AppKit
import SwifttyCore
import SwifttyMac

/// A test host window around one app-owned `TerminalView` session,
/// whose process ends with the window. The app opens only service-backed
/// workspace windows; this keeps the reusable view's window behaviour
/// (field editor, glass background, close-stops) under test.
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
