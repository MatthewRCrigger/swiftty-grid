import RoamingApp
import SwiftUI
import UIKit

/// Mac Catalyst full remote client: built as its own destination with the
/// UIKit-derived terminal frontend. It has no app-local PTY and is never
/// the `swifttyd` launchd agent.
///
/// Uses the SwiftUI app lifecycle: under a hand-built UIKit scene,
/// SwiftUI's programmatic sheet dismissal (Save/Cancel) did not close
/// sheets on Catalyst. The UIKit delegate keeps the desktop menu and quit
/// handling.
@main
struct CatalystClientApp: App {
  @UIApplicationDelegateAdaptor(CatalystAppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup {
      RoamingRootView(model: delegate.model)
        .environment(\.terminalSurfaceFactory, .live(delegate.model))
        .frame(minWidth: 640, minHeight: 420)
    }
    // Links reuse an open window rather than spawning one per link.
    .handlesExternalEvents(matching: ["*"])
  }
}

final class CatalystAppDelegate: UIResponder, UIApplicationDelegate {
  let model = RoamingAppModel(profile: .profile(for: .catalyst))

  /// Best-effort detach on quit; the helper retains the session even if
  /// it never arrives (spec §9). Focus changes never detach.
  func applicationWillTerminate(_ application: UIApplication) {
    let model = model
    Task { await model.detachForTermination() }
  }

  /// Desktop menus: drop the text-formatting menu a terminal client does
  /// not use; ⌘N (Add Host) comes from the shared host list.
  override func buildMenu(with builder: any UIMenuBuilder) {
    super.buildMenu(with: builder)
    guard builder.system == .main else { return }
    builder.remove(menu: .format)
  }
}
