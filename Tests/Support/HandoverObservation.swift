#if canImport(Network) && canImport(SessionCore)
import Dispatch
import Network
import SessionCore
import Synchronization

/// Only the occurrence of a reattach matters between handover checkpoints.
public final class HandoverStateLog: Sendable {
  private let seenReattach = Mutex(false)

  public init() {}

  public func record(_ state: ClientConnectionState) {
    switch state {
    case .reconnecting, .attaching, .sshBootstrap:
      seenReattach.withLock { $0 = true }
    default: break
    }
  }

  public func reset() { seenReattach.withLock { $0 = false } }
  public var reattached: Bool { seenReattach.withLock { $0 } }
}

public protocol HandoverPathMonitoring: Sendable {
  func start(_ update: @escaping @Sendable (String) -> Void)
  func cancel()
}

private final class NetworkHandoverMonitor: HandoverPathMonitoring {
  private let monitor = NWPathMonitor()

  func start(_ update: @escaping @Sendable (String) -> Void) {
    monitor.pathUpdateHandler = { path in
      let kind =
        path.status != .satisfied
        ? "none"
        : path.usesInterfaceType(.wifi)
          ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular" : "other"
      update(kind)
    }
    monitor.start(queue: DispatchQueue(label: "handover.path"))
  }

  func cancel() { monitor.cancel() }
}

/// The current primary interface, with explicit and idempotent cleanup.
public final class HandoverPathWatcher: Sendable {
  private struct State {
    var kind = "none"
    var stopped = false
  }

  private let monitor: any HandoverPathMonitoring
  private let state = Mutex(State())

  public convenience init() { self.init(monitor: NetworkHandoverMonitor()) }

  public init(monitor: any HandoverPathMonitoring) {
    self.monitor = monitor
    monitor.start { [weak self] kind in
      guard let self else { return }
      self.state.withLock { state in
        guard !state.stopped else { return }
        state.kind = kind
      }
    }
  }

  deinit { stop() }

  public var current: String { state.withLock { $0.kind } }

  public func stop() {
    let cancel = state.withLock { state in
      guard !state.stopped else { return false }
      state.stopped = true
      return true
    }
    if cancel { monitor.cancel() }
  }
}
#endif
