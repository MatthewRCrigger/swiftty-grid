import RoamingApp
import SwiftUI
import UIKit

/// Mac Catalyst full remote client: a UIKit-derived app built as its own
/// destination. It has no app-local PTY and is never the `swifttyd`
/// launchd agent.
@main
final class CatalystAppDelegate: UIResponder, UIApplicationDelegate {
  let model = RoamingAppModel(profile: .profile(for: .catalyst))

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: "Default",
      sessionRole: connectingSceneSession.role
    )
    configuration.delegateClass = CatalystSceneDelegate.self
    return configuration
  }

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

/// Hosts the shared SwiftUI root in a UIKit window scene.
final class CatalystSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene,
      let delegate = UIApplication.shared.delegate as? CatalystAppDelegate
    else { return }
    windowScene.sizeRestrictions?.minimumSize = CGSize(width: 640, height: 420)
    windowScene.title = "Roaming SSH"
    let window = UIWindow(windowScene: windowScene)
    window.rootViewController = UIHostingController(
      rootView: RoamingRootView(model: delegate.model)
        .environment(\.terminalSurfaceFactory, .live(delegate.model))
    )
    window.makeKeyAndVisible()
    self.window = window
  }
}
