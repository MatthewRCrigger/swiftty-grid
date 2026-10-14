import Foundation

/// Decides when a foreground preview may be captured.
///
/// Captures stay at least `interval` apart unless forced. A capture
/// skipped for spacing schedules one later read of the latest screen
/// instead of dropping that screen.
public struct PreviewCaptureGate: Sendable, Equatable {
  public enum Decision: Sendable, Equatable {
    /// Capture now. Call `didCapture(at:)` only when a preview is stored.
    case capture(Date)
    /// One later capture is already scheduled.
    case skip
    /// Schedule one capture of whatever the screen is after `delay`.
    case schedule(TimeInterval)
  }

  public private(set) var lastCapture: Date
  public private(set) var scheduled = false
  public let interval: TimeInterval

  public init(lastCapture: Date, interval: TimeInterval) {
    precondition(interval > 0)
    self.lastCapture = lastCapture
    self.interval = interval
  }

  public mutating func decide(now: Date, force: Bool) -> Decision {
    if force || now.timeIntervalSince(lastCapture) >= interval {
      scheduled = false
      return .capture(now)
    }
    if scheduled { return .skip }
    scheduled = true
    return .schedule(interval - now.timeIntervalSince(lastCapture))
  }

  /// A stored preview starts the spacing interval. A miss does not.
  public mutating func didCapture(at now: Date) {
    lastCapture = now
    scheduled = false
  }

  public mutating func cancelSchedule() { scheduled = false }
}
