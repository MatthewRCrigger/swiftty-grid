import AppKit
import RoamingApp
import SwiftUI

/// Native macOS full client. The only product with an app-local PTY
/// backend; persistent remote sessions are owned by `swifttyd` instead.
/// A window losing focus is not a suspension and never detaches; sleep
/// and quitting do (spec §9).
@main
struct MacClientApp: App {
  @NSApplicationDelegateAdaptor(MacClientDelegate.self) private var delegate
  @State private var model = RoamingAppModel(profile: .profile(for: .mac))

  var body: some Scene {
    WindowGroup("Roaming SSH") {
      RoamingRootView(model: model)
        .environment(\.terminalSurfaceFactory, .live(model))
        .frame(minWidth: 640, minHeight: 420)
        .task { delegate.model = model }
    }
    // Links reuse an open window rather than spawning one per link.
    .handlesExternalEvents(matching: ["*"])
  }
}

/// Detaches the roaming session before the app quits, bounded by the
/// client's detach deadline.
@MainActor
final class MacClientDelegate: NSObject, NSApplicationDelegate {
  weak var model: RoamingAppModel?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model, model.activeSession != nil else { return .terminateNow }
    Task {
      await model.detachForTermination()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
