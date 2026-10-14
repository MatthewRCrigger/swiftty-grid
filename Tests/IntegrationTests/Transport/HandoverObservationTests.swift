#if os(macOS)
import SessionCore
import Synchronization
import Testing
import TestSupport

struct HandoverObservationTests {
  private final class Monitor: HandoverPathMonitoring {
    private struct State {
      var update: (@Sendable (String) -> Void)?
      var starts = 0
      var cancels = 0
    }
    private let state = Mutex(State())
    func start(_ update: @escaping @Sendable (String) -> Void) {
      state.withLock {
        $0.update = update;
        $0.starts += 1
      }
    }
    func cancel() { state.withLock { $0.cancels += 1 } }
    func emit(_ kind: String) { state.withLock { $0.update }?(kind) }
    var starts: Int { state.withLock { $0.starts } }
    var cancels: Int { state.withLock { $0.cancels } }
  }

  @Test
  func stateLogLatchesReattachmentWithoutRetainingStatusHistory() {
    let log = HandoverStateLog()
    #expect(!log.reattached)
    for state in [
      ClientConnectionState.idle, .sshBootstrap, .attaching, .active, .suspect,
      .reconnecting, .backgroundDetached, .sessionExited, .sessionLost,
      .userClosed,
    ] {
      log.reset()
      log.record(state)
      #expect(
        log.reattached
          == [.sshBootstrap, .attaching, .reconnecting].contains(state)
      )
    }
    log.record(.reconnecting)
    for _ in 0 ..< 100_000 { log.record(.active) }
    #expect(log.reattached)
    log.reset()
    #expect(!log.reattached)
  }

  @Test
  func stopAndDeinitCancelExactlyOnceAndIgnoreLateCallbacks() {
    let explicit = Monitor()
    do {
      let watcher = HandoverPathWatcher(monitor: explicit)
      #expect(watcher.current == "none")
      explicit.emit("wifi")
      #expect(watcher.current == "wifi")
      watcher.stop()
      watcher.stop()
      explicit.emit("cellular")
      #expect(watcher.current == "wifi")
      #expect(explicit.cancels == 1)
    }
    #expect(explicit.starts == 1 && explicit.cancels == 1)
    // Saved callback must safely ignore a vanished owner.
    explicit.emit("none")
    let automatic = Monitor()
    do {
      let watcher = HandoverPathWatcher(monitor: automatic)
      automatic.emit("cellular")
      #expect(watcher.current == "cellular")
    }
    #expect(automatic.starts == 1 && automatic.cancels == 1)
  }

  @Test
  func concurrentUpdatesAndStopsLeaveAStableFinalPath() async {
    let monitor = Monitor()
    let watcher = HandoverPathWatcher(monitor: monitor)
    monitor.emit("wifi")
    await withTaskGroup(of: Void.self) { group in
      for id in 0 ..< 100 {
        group.addTask {
          if id.isMultiple(of: 2) {
            watcher.stop()
          } else {
            monitor.emit("cellular")
          }
        }
      }
    }
    #expect(monitor.cancels == 1)
    let last = watcher.current
    #expect(["wifi", "cellular"].contains(last))
    monitor.emit("none")
    #expect(watcher.current == last)
  }
}
#endif
