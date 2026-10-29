import RoamingApp
import SwiftUI

/// visionOS full remote client in a native window. Immersive scenes are
/// deferred; gaze and gestures never become shell input.
@main
struct VisionClientApp: App {
  @State private var model = RoamingAppModel(profile: .profile(for: .vision))

  var body: some Scene {
    WindowGroup {
      RoamingRootView(model: model)
        .environment(
          \.terminalSurfaceFactory,
          LiveTerminalSurfaceFactory(app: model)
        )
    }
    // Links reuse an open window rather than spawning one per link.
    .handlesExternalEvents(matching: ["*"])
    .defaultSize(width: 960, height: 640)
  }
}
