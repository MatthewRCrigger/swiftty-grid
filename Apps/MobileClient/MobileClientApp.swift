import CompanionModel
import RoamingApp
import SwiftUI

/// iOS/iPadOS full client: SSH shell/exec, roaming terminal, SFTP, and the
/// iPhone side of the Apple Watch companion bridge.
@main
struct MobileClientApp: App {
  @State private var model = RoamingAppModel(profile: .profile(for: .mobile))
  @State private var watchBridge = PhoneWatchBridge()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      RoamingRootView(model: model)
        .environment(\.terminalSurfaceFactory, .live(model))
        .task { watchBridge.attach(to: model) }
    }
    // Links reuse an open window rather than spawning a scene per link.
    .handlesExternalEvents(matching: ["*"])
    .onChange(of: scenePhase, initial: true) { _, phase in
      watchBridge.setForeground(phase == .active)
    }
  }
}
