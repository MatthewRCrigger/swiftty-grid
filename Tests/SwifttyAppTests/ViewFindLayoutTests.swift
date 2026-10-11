import AppKit
@testable import Swiftty
@testable import SwifttyMac
import Testing

extension ViewBehaviorTests {
  @Test(arguments: [
    NSSize(width: 120, height: 80), NSSize(width: 200, height: 160),
    NSSize(width: 280, height: 40), NSSize(width: 320, height: 160),
    NSSize(width: 800, height: 240),
  ])
  func `find controls stay inside the terminal after resizing`(
    _ size: NSSize
  ) throws {
    _ = NSApplication.shared
    let bar = SearchBar()
    bar.text = "retained query"
    for bounds in [
      NSRect(origin: .zero, size: size),
      NSRect(x: 25, y: 40, width: 800, height: 240),
    ] {
      bar.position(in: bounds)
      #expect(bounds.contains(bar.frame))
      #expect(bar.field.frame.width >= 40)
      let content = try #require(bar.contentView)
      for control in content.subviews where !control.isHidden {
        #expect(content.bounds.contains(control.frame))
      }
      #expect(bar.text == "retained query")
    }
  }
}
