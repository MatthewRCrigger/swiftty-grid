import ScreenProtocol
import SessionCore
import SwifttyCore
import Synchronization

/// Holds the newest installed frame for synchronous view access, forwards
/// it to an optional presentation sink, and coalesces invalidations: one
/// notification until the frame is read, never a queue of frames.
final class FrameMailbox: PresentationSink {
  struct State: Sendable {
    var frame: SurfaceFrame?
    var generation: UInt64 = 0
    var notified = false
    var onInvalidate: (@Sendable () -> Void)?
  }

  let state = Mutex(State())
  let forward: (any PresentationSink)?

  init(forward: (any PresentationSink)?) { self.forward = forward }

  @discardableResult
  func install(_ frame: PresentationFrame) -> Bool {
    let notify = state.withLock { s -> (@Sendable () -> Void)? in
      s.generation &+= 1
      s.frame = SurfaceFrame(generation: s.generation, frame: frame)
      guard !s.notified, let handler = s.onInvalidate else { return nil }
      s.notified = true
      return handler
    }
    _ = forward?.install(frame)
    notify?()
    return true
  }

  func take() -> SurfaceFrame? {
    state.withLock { s in
      s.notified = false
      return s.frame
    }
  }
}

/// RST/1 presentation backend for direct clients (spec §A.3.C, §4.1):
/// a view-facing wrapper around `RoamingClient`. Frames come only from
/// validated host snapshots; input is semantic and never encoded or
/// echoed locally.
public final class RoamingScreenBackend: TerminalSurfaceBackend {
  struct State: Sendable {
    var lifecycle: SurfaceLifecycle = .connecting
    var hasBeenActive = false
    var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)?
    var onStatus: (@Sendable (RoamingStatus) -> Void)?
  }

  public let client: RoamingClient
  private let mailbox: FrameMailbox
  private let state = Mutex(State())

  /// - Parameter sink: Also receives every installed frame, for example a
  ///   presentation-mode `TerminalSession` the view renders.
  public init(
    bootstrapper: any RemoteBootstrapper,
    connector: any RSTConnector,
    sink: (any PresentationSink)? = nil,
    configuration: RoamingClientConfiguration = .init(),
    timing: SurfaceTiming = .system
  ) {
    mailbox = FrameMailbox(forward: sink)
    client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: connector,
      sink: mailbox,
      configuration: configuration,
      timing: timing
    )
  }

  /// Observes nonsecret status (UI chrome, companion bridge).
  public var onStatus: (@Sendable (RoamingStatus) -> Void)? {
    get { state.withLock { $0.onStatus } }
    set { state.withLock { $0.onStatus = newValue } }
  }

  /// Starts observing the client, then bootstraps and attaches.
  public func start(_ target: RoamingTarget) async throws(RoamingClientError) {
    await client.setStatusHandler { [weak self] status in
      self?.observe(status)
    }
    try await client.start(target)
  }

  private func observe(_ status: RoamingStatus) {
    let (changed, lifecycleHandler, statusHandler) = state.withLock {
      s -> (SurfaceLifecycle?, (@Sendable (SurfaceLifecycle) -> Void)?, (@Sendable (RoamingStatus) -> Void)?) in
      if status.state == .active { s.hasBeenActive = true }
      let next = Self.lifecycle(
        for: status,
        hasBeenActive: s.hasBeenActive
      )
      guard next != s.lifecycle else { return (nil, nil, s.onStatus) }
      s.lifecycle = next
      return (next, s.onLifecycleChange, s.onStatus)
    }
    statusHandler?(status)
    if let changed { lifecycleHandler?(changed) }
  }

  static func lifecycle(
    for status: RoamingStatus,
    hasBeenActive: Bool
  ) -> SurfaceLifecycle {
    switch status.state {
    case .idle, .sshBootstrap, .attaching:
      hasBeenActive ? .interrupted : .connecting
    case .active: .active
    case .suspect, .reconnecting, .backgroundDetached: .interrupted
    case .sessionExited: .exited(status.exitStatus)
    case .sessionLost: .lost
    case .userClosed: .closed
    }
  }

  // MARK: TerminalSurfaceBackend

  public var capabilities: SurfaceCapabilities { .roaming }
  public var display: SurfaceDisplay { .frames }

  public func currentFrame() -> SurfaceFrame? { mailbox.take() }

  public var onInvalidate: (@Sendable () -> Void)? {
    get { mailbox.state.withLock { $0.onInvalidate } }
    set { mailbox.state.withLock { $0.onInvalidate = newValue } }
  }

  public var lifecycle: SurfaceLifecycle { state.withLock { $0.lifecycle } }

  public var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)? {
    get { state.withLock { $0.onLifecycleChange } }
    set { state.withLock { $0.onLifecycleChange = newValue } }
  }

  public func submit(_ input: SurfaceInput) async -> SurfaceInputResult {
    await client.submit(input)
  }

  public func proposeGrid(columns: Int, rows: Int) async {
    await client.proposeGrid(columns: columns, rows: rows)
  }

  public func close() async { await client.close(.detach) }

  // MARK: Platform lifecycle

  public func enterBackground() async { await client.enterBackground() }
  public func enterForeground() async { await client.enterForeground() }
  public func wake() async { await client.wake() }
  public func pathChanged() async { await client.pathChanged() }
  public func terminate() async { await client.close(.terminate) }
}
