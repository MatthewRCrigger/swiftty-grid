import CompanionModel
import SwiftUI

/// watchOS companion: read-only, timestamped status of the session the
/// iPhone selected, plus an optional in-memory text preview.
///
/// Links only CompanionModel. No SSH, QUIC, RST, SFTP, Swiftty renderer,
/// credentials, complications, or notifications.
@main
struct WatchCompanionApp: App {
  @State private var model = WatchCompanionModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      WatchStatusView(model: model)
        .task { model.activate() }
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      // Inactive (wrist down, always-on) or background clears the preview.
      model.setActive(phase == .active)
    }
  }
}
