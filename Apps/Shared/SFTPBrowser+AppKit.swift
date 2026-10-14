#if os(macOS)
import AppKit
import SwiftUI

/// Native sheet closure can precede SwiftUI releasing its cached content.
/// Observe the browser's own window without retaining it or another sheet.
struct SFTPBrowserSheetLifetime: NSViewRepresentable {
  let ended: @MainActor () -> Void

  func makeNSView(context: Context) -> SFTPBrowserSheetObserver {
    let view = SFTPBrowserSheetObserver(frame: .zero)
    view.ended = ended
    return view
  }

  func updateNSView(_ view: SFTPBrowserSheetObserver, context: Context) {
    view.ended = ended
  }
}

private final class SFTPBrowserWindowObservations {
  var tokens: [any NSObjectProtocol] = []

  func clear() {
    for token in tokens { NotificationCenter.default.removeObserver(token) }
    tokens.removeAll()
  }

  deinit { clear() }
}

final class SFTPBrowserSheetObserver: NSView {
  var ended: (@MainActor () -> Void)?
  private weak var observedWindow: NSWindow?
  private let observations = SFTPBrowserWindowObservations()

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard observedWindow !== window else { return }
    if observedWindow != nil { ended?() }
    observations.clear()
    observedWindow = window
    guard window != nil else { return }
    let center = NotificationCenter.default
    observations.tokens.append(
      center.addObserver(
        forName: NSWindow.didEndSheetNotification,
        object: nil,
        queue: nil
      ) { [weak self] notification in
        let parent = notification.object as? NSWindow
        MainActor.assumeIsolated {
          guard let self, let window = self.observedWindow, let parent,
            parent === window.sheetParent
          else { return }
          // AppKit retains sheetParent until the sheet is ordered out, so
          // this synchronous notification identifies only our own sheet.
          self.ended?()
        }
      }
    )
    observations.tokens.append(
      center.addObserver(
        forName: NSWindow.willCloseNotification,
        object: nil,
        queue: nil
      ) { [weak self] notification in
        let closing = notification.object as? NSWindow
        MainActor.assumeIsolated {
          guard let self, let window = self.observedWindow, let closing,
            closing === window || closing === window.sheetParent
          else { return }
          self.ended?()
        }
      }
    )
  }
}
#endif
