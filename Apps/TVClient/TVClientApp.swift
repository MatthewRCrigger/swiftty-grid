import RoamingApp
import SwiftUI

/// tvOS terminal-only client: saved hosts, explicit trust prompts, SSH
/// and roaming terminal. No SFTP, clipboard, or local-process actions;
/// navigation is focus-first and terminal input comes from a keyboard.
@main
struct TVClientApp: App {
  @State private var model = RoamingAppModel(profile: .profile(for: .tv))

  var body: some Scene {
    WindowGroup {
      RoamingRootView(model: model)
        .environment(\.terminalSurfaceFactory, .live(model))
    }
  }
}
