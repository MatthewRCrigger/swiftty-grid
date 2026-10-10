import AppKit
import Metal
@testable import Swiftty
@testable import SwifttyMac
import SwifttyCore
import Synchronization
import Testing
import TestSupport

/// Surface capabilities in the macOS view: remote presentations hide or
/// disable local-emulator features and program side effects.
@MainActor
@Suite(.serialized)
struct ViewCapabilityTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  func makeView(session: TerminalSession? = nil) throws -> TerminalView {
    _ = NSApplication.shared
    guard let session else { return try TerminalView(configuration: .init()) }
    return try TerminalView(configuration: .init(), session: session)
  }

  /// Runs the main run loop until `condition` holds or a second passes.
  /// Suspends rather than nesting the run loop: events reach the view
  /// through the main queue, which cannot run while a block on it does.
  private func spin(until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(1)
    while !condition(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  static let osc52 = TestFixture(Array("\u{1B}]52;c;aGk=\u{7}".utf8))

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `program clipboard writes pass the capability gate`(
    _ allowed: Bool
  ) async throws {
    let view = try makeView()
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    view.pasteboard = clipboard
    clipboard.clearContents()
    clipboard.setString("before", forType: .string)
    view.capabilities.remoteClipboardWrites = allowed
    view.session.feed(Self.osc52.value)
    try await spin { clipboard.string(forType: .string) != "before" }
    #expect(clipboard.string(forType: .string) == (allowed ? "hi" : "before"))
  }

  @Test(.enabled(if: hasMetal))
  func `roaming surfaces disable search, paste and scrollback`() throws {
    let view = try makeView()
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    view.pasteboard = clipboard
    clipboard.clearContents()
    clipboard.setString("pasted", forType: .string)
    let writes = Mutex<[UInt8]>([])
    view.session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.capabilities = .roaming
    view.capabilities.paste = false
    #expect(!view.perform(.startSearch))
    #expect(view.searchBar == nil)
    #expect(!view.perform(.scrollPageUp))
    #expect(!view.perform(.pasteFromClipboard))
    view.paste(nil)
    _ = view.session.snapshot()
    #expect(writes.withLock { $0.isEmpty })

    func item(_ action: Selector, tag: Int = 0) -> NSMenuItem {
      let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
      item.tag = tag
      return item
    }
    #expect(!view.validateMenuItem(item(#selector(TerminalView.paste(_:)))))
    #expect(
      !view.validateMenuItem(
        item(#selector(TerminalView.performFindPanelAction(_:)))
      )
    )
    #expect(
      view.validateMenuItem(item(#selector(TerminalView.resetTerminal(_:))))
    )

    view.capabilities = .full
    #expect(view.validateMenuItem(item(#selector(TerminalView.paste(_:)))))
    #expect(view.perform(.startSearch))
    #expect(view.searchBar != nil)
    view.capabilities.search = false
    #expect(view.searchBar == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `presentation views hide local actions and send semantic input`() throws
  {
    let session = TerminalSession(presentationColumns: 20, rows: 4)
    let view = try makeView(session: session)
    view.capabilities = .roaming
    view.capabilities.paste = false
    let writes = Mutex<[UInt8]>([])
    let semantic = Mutex<[String]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    session.semanticInputHandler = { input in
      if case let .paste(text) = input { semantic.withLock { $0.append(text) } }
    }
    #expect(!view.perform(.reset))
    #expect(!view.perform(.clearScreen))
    #expect(
      !view.validateMenuItem(
        NSMenuItem(
          title: "",
          action: #selector(TerminalView.resetTerminal(_:)),
          keyEquivalent: ""
        )
      )
    )
    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
      )
    )
    let menu = try #require(view.menu(for: event))
    let titles = menu.items.map(\.title)
    #expect(titles.contains("Copy"))
    #expect(!titles.contains("Paste"))

    view.capabilities.paste = true
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    view.pasteboard = clipboard
    clipboard.clearContents()
    clipboard.setString("text", forType: .string)
    #expect(view.perform(.pasteFromClipboard))
    session.queue.sync {}
    #expect(semantic.withLock { $0 } == ["text"])
    #expect(writes.withLock { $0.isEmpty })
  }
}
