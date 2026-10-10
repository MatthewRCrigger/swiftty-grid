import TestSupport
#if canImport(UIKit)
import Foundation
import Metal
import SwifttyCore
@testable import SwifttyMobile
import Synchronization
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct ViewCapabilityTests {
  nonisolated static let hasMetal = MTLCreateSystemDefaultDevice() != nil

  /// Runs the main run loop until `condition` holds or a second passes.
  /// Suspends rather than nesting the run loop: events reach the view
  /// through the main queue, which cannot run while a block on it does.
  private func spin(until condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(1)
    while !condition(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func localPasteboard() throws -> UIPasteboard {
    try #require(
      UIPasteboard(name: .init(rawValue: UUID().uuidString), create: true)
    )
  }

  static let osc52 = TestFixture(Array("\u{1B}]52;c;aGk=\u{7}".utf8))

  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `program clipboard writes pass the capability gate`(
    _ allowed: Bool
  ) async throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    let clipboard = try localPasteboard()
    defer { UIPasteboard.remove(withName: clipboard.name) }
    view.pasteboard = clipboard
    clipboard.string = "before"
    view.capabilities.remoteClipboardWrites = allowed
    session.feed(Self.osc52.value)
    try await spin { clipboard.string != "before" }
    #expect(clipboard.string == (allowed ? "hi" : "before"))
  }

  @Test(.enabled(if: hasMetal))
  func `roaming surfaces disable search, scrollback and resets`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    session.feed(Array("one\r\ntwo\r\nthree\r\nfour".utf8))
    view.capabilities = .roaming
    #expect(!view.perform(.startSearch))
    #expect(!view.isSearchVisible)
    #expect(!view.perform(.searchSelection))
    #expect(!view.perform(.scrollPageUp))
    #expect(!view.perform(.jumpToPrompt(-1)))
    #expect(view.perform(.increaseFontSize(1)))
    view.scroll(lines: 3, at: .zero)
    #expect(session.withState { $0.viewportOffset } == 0)
    view.capabilities = .full
    #expect(view.perform(.scrollPageUp))
  }

  @Test(.enabled(if: hasMetal))
  func `search closes when the capability is withdrawn`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    #expect(view.perform(.startSearch))
    #expect(view.isSearchVisible)
    view.capabilities.search = false
    #expect(!view.isSearchVisible)
  }

  @Test(.enabled(if: hasMetal))
  func `paste and copy are unavailable without their capabilities`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    let clipboard = try localPasteboard()
    defer { UIPasteboard.remove(withName: clipboard.name) }
    view.pasteboard = clipboard
    clipboard.string = "pasted"
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    session.feed(Array("abc".utf8))
    view.selectAll(nil)
    let paste = #selector(UIResponderStandardEditActions.paste(_:))
    let copy = #selector(UIResponderStandardEditActions.copy(_:))
    #expect(view.canPerformAction(paste, withSender: nil))
    #expect(view.canPerformAction(copy, withSender: nil))

    view.capabilities.paste = false
    view.capabilities.localCopy = false
    #expect(!view.canPerformAction(paste, withSender: nil))
    #expect(!view.canPerformAction(copy, withSender: nil))
    #expect(!view.perform(.pasteFromClipboard))
    #expect(!view.perform(.copyToClipboard))
    view.paste(nil)
    view.copy(nil)
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
    #expect(clipboard.string == "pasted")
  }

  @Test(.enabled(if: hasMetal))
  func `mouse reporting is ignored without the capability`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
    session.feed(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
    view.capabilities.mouseReporting = false
    view.draw(in: view)
    #expect(!view.tracking)
    view.capabilities.mouseReporting = true
    view.draw(in: view)
    #expect(view.tracking)
  }

  @Test(.enabled(if: hasMetal))
  func `presentation surfaces send semantic input`() throws {
    let session = TerminalSession(presentationColumns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    view.capabilities = .roaming
    let writes = Mutex<[UInt8]>([])
    let semantic = Mutex<[String]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    session.semanticInputHandler = { input in
      if case let .text(text) = input { semantic.withLock { $0.append(text) } }
    }
    view.insertText("ls")
    // Local resets and raw-byte bindings would bypass the host's state.
    #expect(!view.perform(.reset))
    #expect(!view.perform(.csi("2J")))
    _ = session.snapshot()  // after queued input
    #expect(semantic.withLock { $0 } == ["ls"])
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal))
  func `read-only surfaces drop text input`() throws {
    let session = TerminalSession(columns: 10, rows: 2)
    let view = try TerminalUIView(session: session)
    view.capabilities.textInput = false
    let writes = Mutex<[UInt8]>([])
    session.onWrite = { bytes in
      writes.withLock { $0.append(contentsOf: bytes) }
    }
    view.insertText("x")
    #expect(
      view.keyDown(usage: 40, modifiers: [], base: "\r", characters: "\r")
    )
    _ = session.snapshot()
    #expect(writes.withLock { $0.isEmpty })
  }

  @Test(.enabled(if: hasMetal))
  func `shell text input disables system text editing`() throws {
    let view = try TerminalUIView(session: TerminalSession())
    #expect(view.autocorrectionType == .no)
    #expect(view.spellCheckingType == .no)
    #expect(view.smartQuotesType == .no)
    #expect(view.smartDashesType == .no)
    #expect(view.smartInsertDeleteType == .no)
    #expect(view.autocapitalizationType == UITextAutocapitalizationType.none)
    #expect(view.inlinePredictionType == .no)
  }

  @Test(.enabled(if: hasMetal))
  func `the privacy cover hides content while the scene is inactive`() throws {
    let view = try TerminalUIView(session: TerminalSession())
    view.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
    view.sceneWillDeactivate()
    #expect(view.privacyCover == nil)  // not enabled
    view.sceneDidActivate()

    view.hidesContentWhenInactive = true
    #expect(view.privacyCover == nil)
    view.sceneWillDeactivate()
    let cover = try #require(view.privacyCover)
    #expect(cover.superview === view)
    #expect(cover.frame == view.bounds)
    view.sceneDidEnterBackground()
    #expect(view.privacyCover === cover)
    view.sceneWillEnterForeground()
    #expect(view.privacyCover === cover)
    view.sceneDidActivate()
    #expect(view.privacyCover == nil)
    #expect(cover.superview == nil)

    view.sceneWillDeactivate()
    #expect(view.privacyCover != nil)
    view.hidesContentWhenInactive = false
    #expect(view.privacyCover == nil)
  }
}
#endif
