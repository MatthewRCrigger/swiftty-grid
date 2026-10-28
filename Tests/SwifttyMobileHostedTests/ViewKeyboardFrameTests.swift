#if canImport(UIKit) && !os(visionOS)
import SwifttyCore
@testable import SwifttyMobile
import Testing
import UIKit

/// The application host supplies the window scene and its coordinate space.
extension ViewLifecycleTests {
  @Test(.enabled(if: hasMetal), arguments: [false, true])
  func `keyboard hides while detached restore the viewport on reattachment`(
    _ includesScreen: Bool
  ) throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first
    )
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    let session = TerminalSession(columns: 20, rows: 10)
    let view = try TerminalUIView(session: session)
    view.frame = window.bounds
    window.addSubview(view)
    defer { view.removeFromSuperview() }
    view.layoutIfNeeded()
    let fullRows = session.withState { $0.rows }
    let covered = CGRect(
      x: view.bounds.minX,
      y: view.bounds.maxY - 120,
      width: view.bounds.width,
      height: 120
    )
    let frame = view.convert(covered, to: scene.screen.coordinateSpace)
    let object: UIScreen? = includesScreen ? scene.screen : nil
    NotificationCenter.default.post(
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: object,
      userInfo: [
        UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)
      ],
    )
    // The keyboard lifts the terminal; the grid keeps its rows.
    #expect(view.keyboardLift > 0)
    #expect(session.withState { $0.rows } == fullRows)
    view.removeFromSuperview()
    #expect(view.window == nil)
    NotificationCenter.default.post(
      name: UIResponder.keyboardWillHideNotification,
      object: object
    )
    window.addSubview(view)
    view.layoutIfNeeded()
    #expect(view.keyboardLift == 0)
    #expect(view.transform == .identity)
    #expect(session.withState { $0.rows } == fullRows)
  }

  @Test(.enabled(if: hasMetal))
  func `keyboard notifications respect the terminal screen`() throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first
    )
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    let screen = scene.screen
    let otherScreens = UIScreen.screens.filter { $0 !== screen }
    print("Keyboard screen fixture: \(otherScreens.count) other system screens")
    let session = TerminalSession(columns: 20, rows: 10)
    let view = try TerminalUIView(session: session)
    view.frame = window.bounds
    window.addSubview(view)
    defer { view.removeFromSuperview() }
    view.layoutIfNeeded()
    let fullRows = session.withState { $0.rows }
    let covered = CGRect(
      x: view.bounds.minX,
      y: view.bounds.maxY - 120,
      width: view.bounds.width,
      height: 120
    )
    let frame = view.convert(covered, to: screen.coordinateSpace)
    func notify(_ name: Notification.Name, on screen: UIScreen?) {
      let notification = Notification(
        name: name,
        object: screen,
        userInfo: [
          UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)
        ],
      )
      _ = view.perform(
        NSSelectorFromString("keyboardFrameChanged:"),
        with: notification as NSNotification
      )
    }

    // A docked keyboard lifts the view; it never resizes the grid.
    for otherScreen in otherScreens {
      notify(UIResponder.keyboardWillChangeFrameNotification, on: otherScreen)
      #expect(view.keyboardLift == 0)
    }
    notify(UIResponder.keyboardWillChangeFrameNotification, on: screen)
    let lift = view.keyboardLift
    #expect(lift > 0 && lift <= 120)
    #expect(view.transform.ty == -lift)
    #expect(session.withState { $0.rows } == fullRows)
    for otherScreen in otherScreens {
      notify(UIResponder.keyboardWillHideNotification, on: otherScreen)
      #expect(view.keyboardLift == lift)
    }
    notify(UIResponder.keyboardWillHideNotification, on: screen)
    #expect(view.keyboardLift == 0)
    #expect(view.transform == .identity)

    // Keep accepting older keyboard notifications without a screen object.
    notify(UIResponder.keyboardWillChangeFrameNotification, on: nil)
    #expect(view.keyboardLift == lift)
    notify(UIResponder.keyboardWillHideNotification, on: nil)
    #expect(view.keyboardLift == 0)
    #expect(session.withState { $0.rows } == fullRows)
  }

  @Test(.enabled(if: hasMetal))
  func `the lift follows the cursor and keeps it above the keyboard`() throws {
    let scene = try #require(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first
    )
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
    let session = TerminalSession(columns: 20, rows: 10)
    let view = try TerminalUIView(session: session)
    view.frame = window.bounds
    window.addSubview(view)
    defer { view.removeFromSuperview() }
    view.layoutIfNeeded()
    view.draw(in: view)
    let covered = CGRect(
      x: view.bounds.minX,
      y: view.bounds.maxY - 200,
      width: view.bounds.width,
      height: 200
    )
    let frame = view.convert(covered, to: scene.screen.coordinateSpace)
    _ = view.perform(
      NSSelectorFromString("keyboardFrameChanged:"),
      with: Notification(
        name: UIResponder.keyboardWillChangeFrameNotification,
        object: scene.screen,
        userInfo: [
          UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame)
        ],
      ) as NSNotification
    )
    // A cursor on the first row is already visible.
    #expect(view.keyboardLift == 0)
    let rows = session.withState { $0.rows }
    session.feed(Array(String(repeating: "\r\n", count: rows).utf8))
    view.draw(in: view)
    let cursor = try #require(view.lastCursor)
    let bottom = view.geometry.rect(column: 0, row: cursor.y).maxY
    #expect(view.keyboardLift > 0)
    #expect(bottom - view.keyboardLift <= view.bounds.height - 200)
    #expect(session.withState { $0.rows } == rows)
  }
}
#endif
