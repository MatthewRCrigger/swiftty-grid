#if os(macOS) && !targetEnvironment(macCatalyst)
import SessionCore
import SwifttyCore
import Synchronization

/// App-local shell on native macOS (spec §A.3.A): Swiftty's own PTY
/// path. Not available on Mac Catalyst or any other platform.
///
/// The session's lifetime is the app's: deinitializing it hangs up the
/// shell, unlike helper-owned roaming sessions.
public final class LocalPTYBackend: TerminalSurfaceBackend {
  struct State: Sendable {
    var lifecycle: SurfaceLifecycle = .connecting
    var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)?
    var onEvent: (@Sendable (TerminalEvent) -> Void)?
  }

  public let session: TerminalSession
  private let state = Mutex(State())

  public init(session: TerminalSession = TerminalSession()) {
    self.session = session
  }

  /// Session events other than exit handling (titles, bells, clipboard),
  /// forwarded after the backend observes them.
  public var onEvent: (@Sendable (TerminalEvent) -> Void)? {
    get { state.withLock { $0.onEvent } }
    set { state.withLock { $0.onEvent = newValue } }
  }

  /// Spawns the shell on a local PTY.
  public func start(_ configuration: SessionConfiguration) throws {
    session.onEvent = { [weak self] event in
      guard let self else { return }
      if case let .exited(status) = event { self.setLifecycle(.exited(status)) }
      self.onEvent?(event)
    }
    try session.start(configuration)
    setLifecycle(.active)
  }

  private func setLifecycle(_ next: SurfaceLifecycle) {
    let handler = state.withLock { s -> (@Sendable (SurfaceLifecycle) -> Void)? in
      guard s.lifecycle != next, !s.lifecycle.isFinal else { return nil }
      s.lifecycle = next
      return s.onLifecycleChange
    }
    handler?(next)
  }

  public var capabilities: SurfaceCapabilities { .full }
  public var display: SurfaceDisplay { .session(session) }
  public func currentFrame() -> SurfaceFrame? { nil }

  /// The view observes `session.onUpdate` directly.
  public var onInvalidate: (@Sendable () -> Void)? {
    get { nil }
    set {}
  }

  public var lifecycle: SurfaceLifecycle { state.withLock { $0.lifecycle } }

  public var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)? {
    get { state.withLock { $0.onLifecycleChange } }
    set { state.withLock { $0.onLifecycleChange = newValue } }
  }

  public func submit(_ input: SurfaceInput) async -> SurfaceInputResult {
    switch lifecycle {
    case .active: break
    case let other where other.isFinal: return .refused(.closed)
    default: return .refused(.notActive(.idle))
    }
    do { try input.operation.validate() } catch { return .refused(.invalid) }
    session.send(input.terminalInput)
    return .accepted(sequence: nil)
  }

  public func proposeGrid(columns: Int, rows: Int) async {
    guard columns > 0, rows > 0 else { return }
    session.resize(columns: columns, rows: rows)
  }

  public func close() async {
    setLifecycle(.closed)
    session.stop()
  }
}
#endif
