import AppKit
import SwifttyCore

@MainActor
package enum TerminalWindowBackground {
  /// Returns whether the content was reparented.
  @discardableResult
  package static func apply(
    to window: NSWindow,
    content: NSView,
    configuration: Configuration
  ) -> Bool {
    let windowFrame = window.frame
    let translucent = configuration.backgroundOpacity < 1
    window.isOpaque = !translucent
    window.backgroundColor = translucent ? .clear : .windowBackgroundColor
    if translucent, configuration.backgroundBlur > 0 {
      if let glass = window.contentView as? NSGlassEffectView,
        content.superview === glass.contentView
      {
        return false
      }
      content.removeFromSuperview()
      window.styleMask.insert(.fullSizeContentView)
      window.titlebarAppearsTransparent = true
      let glass = NSGlassEffectView(frame: window.contentView?.bounds ?? .zero)
      glass.style = .regular
      glass.cornerRadius = 0
      let host = NSView(frame: glass.bounds)
      host.autoresizingMask = [.width, .height]
      glass.contentView = host
      host.addSubview(content)
      content.translatesAutoresizingMaskIntoConstraints = false
      window.contentView = glass
      if let guide = window.contentLayoutGuide as? NSLayoutGuide {
        NSLayoutConstraint.activate([
          content.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
          content.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
          content.topAnchor.constraint(equalTo: guide.topAnchor),
          content.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
        ])
      }
    } else {
      guard window.contentView !== content else { return false }
      content.removeFromSuperview()
      content.translatesAutoresizingMaskIntoConstraints = true
      window.styleMask.remove(.fullSizeContentView)
      window.titlebarAppearsTransparent = false
      window.contentView = content
    }
    window.setFrame(windowFrame, display: false)
    window.contentView?.layoutSubtreeIfNeeded()
    return true
  }
}
