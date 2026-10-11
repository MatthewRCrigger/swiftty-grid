import TestSupport
#if canImport(UIKit)
import Metal
import SwifttyCore
@testable import SwifttyMobile
import Synchronization
import Testing
import UIKit

extension ViewLifecycleTests {
  @Test(.enabled(if: hasMetal))
  func `retaining an accessibility element does not retain its terminal`()
    throws
  {
    weak var retainedView: TerminalUIView?
    let element = try autoreleasepool {
      let view = try TerminalUIView(
        session: TerminalSession(columns: 20, rows: 3)
      )
      retainedView = view
      return view.accessibilityTerminal
    }
    #expect(retainedView == nil)
    #expect(element.accessibilityContainer == nil)
    #expect(element.accessibilityFrame == .zero)
    #expect(element.accessibilityPageContent() == nil)
    #expect(!element.accessibilityActivate())
    #expect(!element.accessibilityScroll(.previous))
  }

  @Test(.enabled(if: hasMetal))
  func `activating the terminal accessibility element focuses keyboard input`()
    throws
  {
    let session = TerminalSession(columns: 20, rows: 3)
    let view = try TerminalUIView(session: session)
    let window = makeWindow()
    let controller = UIViewController()
    window.rootViewController = controller
    controller.view.addSubview(view)
    let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
    controller.view.addSubview(field)
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    #expect(field.becomeFirstResponder())
    #expect(!view.isFirstResponder)
    #expect(view.accessibilityTerminal.accessibilityActivate())
    #expect(view.isFirstResponder && !field.isFirstResponder)
  }

  @Test(.enabled(if: hasMetal))
  func
    `accessibility reading page commands navigate scrollback and stop at its bounds`()
    throws
  {
    let session = TerminalSession(columns: 20, rows: 3)
    session.feed(Array("0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6".utf8))
    let view = try TerminalUIView(session: session)
    view.accessibilityScreen = AccessibilityText(session.snapshot())
    let terminal = view.accessibilityTerminal
    #expect(!terminal.accessibilityScroll(.next))
    #expect(terminal.accessibilityScroll(.previous))
    #expect(
      TestFixture(terminal.accessibilityPageContent()) == TestFixture("2\n3\n4")
    )
    #expect(terminal.accessibilityScroll(.previous))
    #expect(
      TestFixture(terminal.accessibilityPageContent()) == TestFixture("0\n1\n2")
    )
    #expect(!terminal.accessibilityScroll(.previous))
    #expect(terminal.accessibilityScroll(.next))
    #expect(
      TestFixture(terminal.accessibilityPageContent()) == TestFixture("2\n3\n4")
    )
    #expect(terminal.accessibilityScroll(.next))
    #expect(
      TestFixture(terminal.accessibilityPageContent()) == TestFixture("4\n5\n6")
    )
    #expect(!terminal.accessibilityScroll(.next))
  }

  @Test(.enabled(if: hasMetal))
  func
    `accessibility exposes search controls alongside terminal reading content`()
    throws
  {
    let session = TerminalSession(columns: 20, rows: 3)
    session.feed(Array("one\r\ntwo\r\nthree\r\nfour".utf8))
    let view = try TerminalUIView(session: session)
    view.accessibilityScreen = AccessibilityText(session.snapshot())
    view.bounds = CGRect(x: 0, y: 0, width: 320, height: 240)
    #expect(!view.isAccessibilityElement)
    let elements = try #require(view.accessibilityElements)
    #expect(elements.count == 1)
    let terminal = try #require(elements.first as? UIAccessibilityElement)
    let reading = try #require(terminal as? UIAccessibilityReadingContent)
    #expect(
      terminal.isAccessibilityElement
        && terminal.accessibilityLabel == "Terminal"
    )
    #expect(terminal.accessibilityValue == "four")
    #expect(
      terminal.accessibilityFrame
        == UIAccessibility.convertToScreenCoordinates(view.bounds, in: view)
    )
    #expect(terminal.accessibilityTraits == view.accessibilityTraits)
    #expect(
      reading.accessibilityPageContent() == view.accessibilityPageContent()
    )
    #expect(reading.accessibilityContent(forLineNumber: 1) == "three")
    #expect(
      reading.accessibilityFrame(forLineNumber: 1)
        == view.accessibilityFrame(forLineNumber: 1)
    )
    view.showSearch(text: "three")
    let searching = try #require(view.accessibilityElements)
    #expect(searching.count == 2)
    #expect(searching.first as? UIView === view.searchBar)
    #expect(searching.last as? UIAccessibilityElement === terminal)
    #expect(view.searchBar.field.accessibilityLabel == "Find")
    #expect(reading.accessibilityPageContent() != nil)
    view.hideSearch()
    #expect(view.accessibilityElements?.count == 1)
    #expect(
      view.accessibilityElements?.first as? UIAccessibilityElement === terminal
    )
    #expect(terminal.accessibilityScroll(.down))
    #expect(
      TestFixture(reading.accessibilityPageContent())
        == TestFixture("one\ntwo\nthree")
    )
    #expect(terminal.accessibilityValue == "three")
  }

  @Test(.enabled(if: hasMetal))
  func
    `accessibility scrolling reports actual movement and updates readable content`()
    throws
  {
    let session = TerminalSession(columns: 10, rows: 3)
    let view = try TerminalUIView(session: session)
    #expect(!view.accessibilityScroll(.up))
    #expect(!view.accessibilityScroll(.down))
    session.feed(Array("0\r\n1\r\n2\r\n3\r\n4\r\n5\r\n6".utf8))
    #expect(!view.accessibilityScroll(.up))
    #expect(view.accessibilityScroll(.down))
    #expect(session.withState { $0.viewportOffset } == 2)
    #expect(
      TestFixture(view.accessibilityPageContent()) == TestFixture("2\n3\n4")
    )
    #expect(view.accessibilityScroll(.down))
    #expect(session.withState { $0.viewportOffset } == 4)
    #expect(
      TestFixture(view.accessibilityPageContent()) == TestFixture("0\n1\n2")
    )
    #expect(!view.accessibilityScroll(.down))
    #expect(!view.accessibilityScroll(.left))
    #expect(view.accessibilityScroll(.up))
    #expect(
      TestFixture(view.accessibilityPageContent()) == TestFixture("2\n3\n4")
    )
    #expect(view.accessibilityScroll(.up))
    #expect(
      TestFixture(view.accessibilityPageContent()) == TestFixture("4\n5\n6")
    )
    #expect(!view.accessibilityScroll(.up))
    session.feed(Array("\u{1B}[?1049h".utf8))
    #expect(!view.accessibilityScroll(.down))
    #expect(!view.accessibilityScroll(.up))
  }
}

#endif
