#if canImport(UIKit)
@testable import SwifttyMobile
import Testing
import UIKit

extension ViewLifecycleTests {
  @Test
  func `esc ctrl alt and tab are SF Symbols with spoken names`() throws {
    let bar = TerminalAccessoryBar()
    func button(_ label: String, in view: UIView) -> UIButton? {
      if let button = view as? UIButton, button.accessibilityLabel == label {
        return button
      }
      return view.subviews.lazy.compactMap { button(label, in: $0) }.first
    }
    for key in [AccessoryKey.escape, .control, .alt, .tab] {
      let symbol = try #require(key.symbolName)
      #expect(UIImage(systemName: symbol) != nil, "missing \(symbol)")
      let found = try #require(button(key.accessibilityName, in: bar))
      #expect(found.configuration?.image != nil)
      #expect(found.configuration?.title == nil)
    }
    // Arrows and symbols keep their text.
    #expect(AccessoryKey.up.symbolName == nil)
    #expect(button(AccessoryKey.up.title, in: bar) != nil)
  }

  @Test
  func
    `releasing an earlier accessory key preserves the newest held key repeat`()
    async throws
  {
    let bar = TerminalAccessoryBar()
    let window = makeWindow()
    window.addSubview(bar)
    defer {
      bar.stopRepeating();
      bar.removeFromSuperview()
    }
    func findButton(_ title: String, in view: UIView) -> UIButton? {
      if let button = view as? UIButton, button.accessibilityLabel == title {
        return button
      }
      return view.subviews.lazy.compactMap { findButton(title, in: $0) }.first
    }
    let up = try #require(findButton(AccessoryKey.up.title, in: bar))
    let left = try #require(findButton(AccessoryKey.left.title, in: bar))
    var delivered: [AccessoryKey] = []
    bar.onKey = { delivered.append($0) }
    _ = bar.perform(NSSelectorFromString("keyDown:"), with: up)
    _ = bar.perform(NSSelectorFromString("keyDown:"), with: left)
    _ = bar.perform(NSSelectorFromString("keyUp:"), with: up)
    #expect(delivered == [.up, .left])
    let deadline = ContinuousClock.now + .seconds(2)
    while delivered.count < 3, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(delivered.count >= 3)
    #expect(delivered.dropFirst().allSatisfy { $0 == .left })
    _ = bar.perform(NSSelectorFromString("keyUp:"), with: left)
    let stoppedCount = delivered.count
    try await Task.sleep(for: .milliseconds(150))
    #expect(delivered.count == stoppedCount)
  }

  @Test(arguments: ["cancel", "detach"])
  func `accessory cancellation during the initial key callback stays cancelled`(
    _ operation: String
  ) async throws {
    let bar = TerminalAccessoryBar()
    let window = makeWindow()
    window.addSubview(bar)
    defer {
      bar.stopRepeating();
      bar.removeFromSuperview()
    }
    func findButton(in view: UIView) -> UIButton? {
      if let button = view as? UIButton,
        button.accessibilityLabel == AccessoryKey.up.title
      {
        return button
      }
      return view.subviews.lazy.compactMap { findButton(in: $0) }.first
    }
    let button = try #require(findButton(in: bar))
    var delivered = 0
    bar.onKey = { [weak bar] _ in
      delivered += 1
      guard delivered == 1 else { return }
      if operation == "detach" {
        bar?.removeFromSuperview()
      } else {
        bar?.stopRepeating()
      }
    }
    _ = bar.perform(NSSelectorFromString("keyDown:"), with: button)
    #expect(delivered == 1)
    try await Task.sleep(for: .milliseconds(650))
    #expect(delivered == 1)
  }
}
#endif
