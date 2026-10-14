import Dispatch

extension MuxService {
  /// Ends all panes, including admitted launches and detached teardowns,
  /// before the agent exits. Only the first request owns the completion.
  /// Live control connections and roaming do not hold this exit barrier.
  package nonisolated func prepareToExit(
    _ ready: @escaping @Sendable () -> Void,
  ) {
    onQueue { service in
      guard !service.exitRequested else { return }
      service.exitRequested = true
      service.onExitReady = ready
      service.quiescing = true
      service.endAllEpoch &+= 1
      for id in service.workspaces.map(\.id) { service.endWorkspace(id) }
      // Panes already removed from the layout still belong to the process
      // barrier until their runtime reports actual termination/reaping.
      for id in Array(service.panes.keys) { service.endPane(id) }
      service.checkIdle()
    }
  }
}
