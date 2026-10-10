import SwifttyCore

/// A presentation-mode session displays roaming frames directly.
extension TerminalSession: PresentationSink {
  @discardableResult
  public func install(_ frame: PresentationFrame) -> Bool {
    installPresentation(frame)
  }
}
