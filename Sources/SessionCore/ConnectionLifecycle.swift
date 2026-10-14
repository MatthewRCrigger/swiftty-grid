/// Direct-client connection state machine (spec §9).
public enum ClientConnectionState: String, Hashable, Sendable, Codable {
  case idle
  case sshBootstrap
  case attaching
  case active
  case suspect
  case reconnecting
  case backgroundDetached
  case sessionExited
  case sessionLost
  case userClosed

  public var isTerminal: Bool {
    switch self {
    case .sessionExited, .sessionLost, .userClosed: true
    default: false
    }
  }

  /// New remote input is accepted only while active (§8).
  public var acceptsInput: Bool { self == .active }

  public func canTransition(to next: ClientConnectionState) -> Bool {
    if next == self { return false }
    // any -> session-exited / session-lost / user-closed
    if next.isTerminal { return !isTerminal }
    return switch (self, next) {
    case (.idle, .sshBootstrap), (.sshBootstrap, .attaching),
      (.attaching, .active), (.active, .suspect), (.suspect, .active),
      (.suspect, .reconnecting), (.active, .reconnecting),
      (.reconnecting, .attaching),
      // A cold reconnect after token expiry reauthenticates with SSH.
      (.reconnecting, .sshBootstrap),
      // A failed SSH resume falls back to network recovery.
      (.sshBootstrap, .reconnecting), (.sshBootstrap, .backgroundDetached),
      (.attaching, .reconnecting), (.active, .backgroundDetached),
      (.suspect, .backgroundDetached), (.reconnecting, .backgroundDetached),
      (.attaching, .backgroundDetached), (.backgroundDetached, .attaching),
      (.backgroundDetached, .sshBootstrap):
      true
    default: false
    }
  }
}

/// Validated holder for `ClientConnectionState`.
public struct ClientLifecycle: Sendable {
  public enum TransitionError: Error, Equatable {
    case invalid(from: ClientConnectionState, to: ClientConnectionState)
  }

  public private(set) var state: ClientConnectionState = .idle
  public private(set) var history: [ClientConnectionState] = [.idle]
  static let historyLimit = 32

  public init() {}

  public mutating func transition(
    to next: ClientConnectionState
  ) throws(TransitionError) {
    guard state.canTransition(to: next) else {
      throw .invalid(from: state, to: next)
    }
    state = next
    history.append(next)
    if history.count > Self.historyLimit { history.removeFirst() }
  }
}

/// Jittered reconnect delays: 0.5, 1, 2, 4, 8, then 15 seconds (§9).
public struct ReconnectBackoff: Sendable {
  public static let schedule: [Double] = [0.5, 1, 2, 4, 8, 15]
  public private(set) var attempt = 0
  public let jitter: Double

  /// Jitter is a fraction in 0...1. Clamp finite values to that range;
  /// nonfinite values disable jitter rather than creating an invalid range.
  public init(jitter: Double = 0.2) {
    self.jitter = jitter.isFinite ? min(max(jitter, 0), 1) : 0
  }

  /// Delay before the next attempt, in seconds; never above 15.
  public mutating func nextDelay(
    using generator: inout some RandomNumberGenerator
  ) -> Double {
    let base = Self.schedule[min(attempt, Self.schedule.count - 1)]
    attempt += 1
    let factor = 1 + Double.random(in: -jitter ... jitter, using: &generator)
    return min(base * factor, Self.schedule.last!)
  }

  public mutating func nextDelay() -> Double {
    var generator = SystemRandomNumberGenerator()
    return nextDelay(using: &generator)
  }

  public mutating func reset() { attempt = 0 }
}

/// Round-trip estimate and staleness rule (§9): heartbeat every 20 seconds
/// when idle; with pending input or a path probe, stale after
/// `max(2 s, 4 × RTT)` without a response. Idle silence is never a failure.
public struct LivenessPolicy: Sendable {
  public private(set) var smoothedRTT: Duration?

  public init() {}

  public mutating func sample(_ rtt: Duration) {
    guard rtt >= .zero else { return }
    if let current = smoothedRTT {
      smoothedRTT = current * 0.875 + rtt * 0.125
    } else {
      smoothedRTT = rtt
    }
  }

  public var staleTimeout: Duration {
    max(RSTLimits.minimumStaleTimeout, (smoothedRTT ?? .zero) * 4)
  }

  public func shouldSendHeartbeat(idleFor idle: Duration) -> Bool {
    idle >= RSTLimits.heartbeatInterval
  }

  /// Whether an outstanding expectation (pending input acknowledgment or
  /// probe) has gone unanswered too long.
  public func isStale(awaitingResponseFor elapsed: Duration?) -> Bool {
    guard let elapsed else { return false }
    return elapsed > staleTimeout
  }
}
