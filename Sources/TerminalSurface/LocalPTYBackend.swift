#if os(macOS) && !targetEnvironment(macCatalyst)
import SessionCore
import SwifttyCore
import Synchronization

public enum LocalPTYBackendError: Error, Equatable {
  case invalidState(SurfaceLifecycle)
}

/// App-local shell on native macOS (spec §A.3.A): Swiftty's own PTY
/// path. Not available on Mac Catalyst or any other platform.
///
/// The session's lifetime is the app's: deinitializing it hangs up the
/// shell, unlike helper-owned roaming sessions.
public final class LocalPTYBackend: TerminalSurfaceBackend {
  struct State: Sendable {
    var lifecycle: SurfaceLifecycle = .connecting
    var starting = false
    var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)?
    var onEvent: (@Sendable (TerminalEvent) -> Void)?
    var onInputRefusal: (@Sendable (InputRefusal) -> Void)?
  }

  public let session: TerminalSession
  private let state = Mutex(State())
  private let admission: PTYInputAdmission

  public var writeLimit: Int { admission.limit }
  /// Reservations awaiting encoding plus bytes not yet written to the PTY.
  /// Terminal replies are counted too and may exceed the user input limit.
  public var pendingInputBytes: Int { admission.pendingBytes }

  /// Supplies a regular terminal whose process has not been started.
  /// A session belongs to only one local backend for its lifetime.
  public init(
    session: TerminalSession = TerminalSession(),
    writeLimit: Int = RSTLimits.maxPendingInputBytes
  ) {
    self.session = session
    admission = PTYInputAdmission(limit: writeLimit)
    session.installPTYInputAdmission(admission) { [weak self] input in
      guard let self else { return }
      if case let .refused(reason) = submitInput(input) {
        let handler = state.withLock { $0.onInputRefusal }
        handler?(reason)
      }
    }
  }

  /// Session events other than exit handling (titles, bells, clipboard),
  /// forwarded after the backend observes them.
  public var onEvent: (@Sendable (TerminalEvent) -> Void)? {
    get { state.withLock { $0.onEvent } }
    set {
      let previous = state.withLock { s in
        let previous = s.onEvent
        s.onEvent = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  /// Spawns a shell while connecting. Failed launches may be retried;
  /// an active or final backend rejects further starts.
  public func start(_ configuration: SessionConfiguration) throws {
    guard !session.isPresentation else {
      throw LocalPTYBackendError.invalidState(lifecycle)
    }
    guard session.ptyInputAdmission === admission else {
      throw LocalPTYBackendError.invalidState(lifecycle)
    }
    let invalid = state.withLock { s -> SurfaceLifecycle? in
      guard s.lifecycle == .connecting, !s.starting else { return s.lifecycle }
      s.starting = true
      return nil
    }
    if let invalid { throw LocalPTYBackendError.invalidState(invalid) }
    defer { state.withLock { $0.starting = false } }
    session.onEvent = { [weak self] event in
      guard let self else { return }
      if case let .exited(status) = event { self.setLifecycle(.exited(status)) }
      self.onEvent?(event)
    }
    do {
      try session.start(
        configuration,
        if: { [self] in
          state.withLock { $0.lifecycle == .connecting } && !session.isRunning
        }
      )
    } catch is CancellationError {
      throw LocalPTYBackendError.invalidState(lifecycle)
    }
    guard lifecycle != .closed else {
      session.stop()
      throw LocalPTYBackendError.invalidState(.closed)
    }
    setLifecycle(.active)
  }

  private func setLifecycle(_ next: SurfaceLifecycle) {
    let handler = state.withLock {
      s -> (@Sendable (SurfaceLifecycle) -> Void)? in
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
    set { _ = newValue }
  }

  public var lifecycle: SurfaceLifecycle { state.withLock { $0.lifecycle } }

  public var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)? {
    get { state.withLock { $0.onLifecycleChange } }
    set {
      let previous = state.withLock { s in
        let previous = s.onLifecycleChange
        s.onLifecycleChange = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  public func submit(_ input: SurfaceInput) async -> SurfaceInputResult {
    do { try input.operation.validate() } catch { return .refused(.invalid) }
    return submitInput(input.terminalInput)
  }

  /// Reports direct native view refusals outside the backend lock.
  public var onInputRefusal: (@Sendable (InputRefusal) -> Void)? {
    get { state.withLock { $0.onInputRefusal } }
    set {
      let previous = state.withLock { s in
        let previous = s.onInputRefusal
        s.onInputRefusal = newValue
        return previous
      }
      withExtendedLifetime(previous) {}
    }
  }

  private func submitInput(_ input: TerminalInput) -> SurfaceInputResult {
    switch lifecycle {
    case .active: break
    case let other where other.isFinal: return .refused(.closed)
    default: return .refused(.notActive(.idle))
    }
    guard let reservation = inputReservation(for: input) else {
      return .refused(.invalid)
    }
    guard admission.reserve(reservation) else { return .refused(.backpressure) }
    session.sendToPTY(input, reservation: reservation)
    return .accepted(sequence: nil)
  }

  public func proposeGrid(columns: Int, rows: Int) async {
    guard columns > 0, rows > 0 else { return }
    session.resize(
      columns: columns,
      rows: rows,
      if: { [weak self] in
        guard let self else { return false }
        return !lifecycle.isFinal
      }
    )
  }

  public func close() async {
    setLifecycle(.closed)
    admission.close()
    if session.ptyInputAdmission === admission { session.stop() }
  }
}
#endif
