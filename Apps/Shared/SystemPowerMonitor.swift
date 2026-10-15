#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep and wake on a Mac (spec §9: sleep detaches, wake
/// reattaches; focus changes do neither). Uses IOKit power notifications,
/// which Mac Catalyst can use, unlike NSWorkspace's sleep notifications.
@MainActor
final class SystemPowerMonitor {
  // IOMessage.h's iokit_common_msg() values; Swift cannot import the macros.
  private static let canSystemSleep: natural_t = 0xE000_0270
  private static let systemWillSleep: natural_t = 0xE000_0280
  private static let systemHasPoweredOn: natural_t = 0xE000_0300

  private let onSleep: @MainActor () -> Void
  private let onWake: @MainActor () -> Void
  private var root: io_connect_t = 0
  private var notifier: io_object_t = 0
  private var port: IONotificationPortRef?

  init(onSleep: @escaping @MainActor () -> Void, onWake: @escaping @MainActor () -> Void) {
    self.onSleep = onSleep
    self.onWake = onWake
    root = IORegisterForSystemPower(
      Unmanaged.passUnretained(self).toOpaque(), &port,
      { context, _, message, argument in
        guard let context else { return }
        let monitor = Unmanaged<SystemPowerMonitor>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.handle(message, argument) }
      },
      &notifier
    )
    if root != 0, let port { IONotificationPortSetDispatchQueue(port, .main) }
  }

  /// Stops delivery; must run before the monitor is released.
  func invalidate() {
    guard root != 0 else { return }
    IODeregisterForSystemPower(&notifier)
    IOServiceClose(root)
    if let port { IONotificationPortDestroy(port) }
    root = 0
    port = nil
  }

  private func handle(_ message: natural_t, _ argument: UnsafeMutableRawPointer?) {
    switch message {
    case Self.canSystemSleep:
      // Never veto idle sleep.
      IOAllowPowerChange(root, Int(bitPattern: argument))
    case Self.systemWillSleep:
      onSleep()
      // Acknowledge now: the system otherwise delays sleep by 30 seconds.
      IOAllowPowerChange(root, Int(bitPattern: argument))
    case Self.systemHasPoweredOn:
      onWake()
    default:
      break
    }
  }
}
#endif
