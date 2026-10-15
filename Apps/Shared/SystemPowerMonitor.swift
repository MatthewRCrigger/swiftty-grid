#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import IOKit
import IOKit.pwr_mgt

/// System sleep and wake on a Mac (spec §9: sleep detaches, wake
/// reattaches; focus changes do neither). Uses IOKit power notifications,
/// which Mac Catalyst can use, unlike NSWorkspace's sleep notifications.
@MainActor
final class SystemPowerMonitor {
  /// IOKit's callback context, retained for IOKit until `invalidate()`.
  /// Its weak reference turns a callback after the monitor is gone into
  /// a no-op.
  @MainActor
  private final class Context { weak var monitor: SystemPowerMonitor? }

  // IOMessage.h's iokit_common_msg() values; Swift cannot import the macros.
  private static let canSystemSleep: natural_t = 0xE000_0270
  private static let systemWillSleep: natural_t = 0xE000_0280
  private static let systemHasPoweredOn: natural_t = 0xE000_0300
  /// How long sleep waits for the detach; the system waits at most 30
  /// seconds for an acknowledgement.
  static let sleepDelayBound: Duration = .seconds(5)

  private let onSleep: @MainActor () -> Task<Void, Never>?
  private let onWake: @MainActor () -> Void
  private var root: io_connect_t = 0
  private var notifier: io_object_t = 0
  private var port: IONotificationPortRef?
  private var context: Unmanaged<Context>?
  /// The sleep notification not yet acknowledged.
  private var pendingSleep: Int?

  /// `onSleep` returns the detach it started, if any; sleep waits for it.
  init(
    onSleep: @escaping @MainActor () -> Task<Void, Never>?,
    onWake: @escaping @MainActor () -> Void
  ) {
    self.onSleep = onSleep
    self.onWake = onWake
    let box = Context()
    box.monitor = self
    let context = Unmanaged.passRetained(box)
    root = IORegisterForSystemPower(
      context.toOpaque(),
      &port,
      { context, _, message, argument in
        guard let context else { return }
        let box = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { box.monitor?.handle(message, argument) }
      },
      &notifier
    )
    guard root != 0, let port else {
      context.release()
      return
    }
    self.context = context
    IONotificationPortSetDispatchQueue(port, .main)
  }

  isolated deinit { invalidate() }

  /// Stops delivery and lets a pending sleep proceed.
  func invalidate() {
    guard root != 0 else { return }
    if let pendingSleep { IOAllowPowerChange(root, pendingSleep) }
    pendingSleep = nil
    IODeregisterForSystemPower(&notifier)
    IOServiceClose(root)
    if let port { IONotificationPortDestroy(port) }
    context?.release()
    context = nil
    root = 0
    port = nil
  }

  private func handle(
    _ message: natural_t,
    _ argument: UnsafeMutableRawPointer?
  ) {
    let notification = Int(bitPattern: argument)
    switch message {
    case Self.canSystemSleep:
      // Never veto idle sleep.
      IOAllowPowerChange(root, notification)
    case Self.systemWillSleep:
      guard let detach = onSleep() else {
        IOAllowPowerChange(root, notification)
        return
      }
      // Acknowledge once the detach finishes, or after the bound.
      pendingSleep = notification
      Task { [weak self] in
        await detach.value
        self?.allowSleep(notification)
      }
      Task { [weak self] in
        try? await Task.sleep(for: Self.sleepDelayBound)
        self?.allowSleep(notification)
      }
    case Self.systemHasPoweredOn: onWake()
    default: break
    }
  }

  private func allowSleep(_ notification: Int) {
    guard root != 0, pendingSleep == notification else { return }
    pendingSleep = nil
    IOAllowPowerChange(root, notification)
  }
}
#endif
