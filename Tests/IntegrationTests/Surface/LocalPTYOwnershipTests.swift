#if os(macOS) && !targetEnvironment(macCatalyst)
import Dispatch
import SessionCore
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalPTYOwnershipTests {
  private func configuration(
    _ command: [String] = ["/bin/cat"]
  ) -> SessionConfiguration {
    var value = SessionConfiguration()
    value.command = command
    return value
  }

  private func rejected(_ backend: LocalPTYBackend) -> Bool {
    do {
      try backend.start(configuration())
      return false
    } catch { return true }
  }

  @Test
  func rejectsStartAfterClose() async {
    let backend = LocalPTYBackend()
    await backend.close()
    #expect(rejected(backend))
    #expect(!backend.session.isRunning)
    #expect(backend.lifecycle == .closed)
    await backend.close()
  }

  @Test
  func rejectsRepeatedLiveStart() async throws {
    let backend = LocalPTYBackend()
    try backend.start(configuration())
    #expect(rejected(backend))
    #expect(backend.lifecycle == .active)
    #expect(backend.session.isRunning)
    #expect(await backend.submit(.text("ok\n")) == .accepted(sequence: nil))
    #expect(
      await eventually {
        backend.session.withState {
          $0.screenLines.contains { $0.contains("ok") }
        }
      }
    )
    await backend.close()
    #expect(!backend.session.isRunning)
  }

  @Test
  func rejectsStartAfterExit() async throws {
    let backend = LocalPTYBackend()
    try backend.start(configuration(["/bin/sh", "-c", "exit 7"]))
    #expect(await eventually { backend.lifecycle == .exited(7) })
    #expect(rejected(backend))
    #expect(!backend.session.isRunning)
    #expect(backend.lifecycle == .exited(7))
    await backend.close()
  }

  @Test(arguments: [false, true])
  func finalLifecycleRejectsQueuedAndNewGeometry(queued: Bool) async {
    let session = TerminalSession(columns: 20, rows: 4)
    let backend = LocalPTYBackend(session: session)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    if queued {
      session.mutateAsync { _ in gate.wait() }
      await backend.proposeGrid(columns: 80, rows: 24)
      let close = Task { await backend.close() }
      #expect(await eventually { backend.lifecycle == .closed })
      gate.signal()
      await close.value
    } else {
      await backend.close()
      await backend.proposeGrid(columns: 80, rows: 24)
    }
    #expect(session.withState { $0.columns == 20 && $0.rows == 4 })
  }

  @Test
  func closingQueuedStartupPreventsLaunch() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let backend = LocalPTYBackend(session: session)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    session.mutateAsync { _ in gate.wait() }
    let start = Task { rejected(backend) }
    #expect(await eventually { session.onEvent != nil })
    let close = Task { await backend.close() }
    #expect(await eventually { backend.lifecycle == .closed })
    gate.signal()
    await close.value
    #expect(await start.value)
    #expect(!session.isRunning)
    #expect(backend.lifecycle == .closed)
    await backend.close()
  }

  @Test
  func concurrentQueuedStartsKeepOneOwner() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let backend = LocalPTYBackend(session: session)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    session.mutateAsync { _ in gate.wait() }
    let first = Task { rejected(backend) }
    #expect(await eventually { session.onEvent != nil })
    let finished = Mutex(false)
    let second = Task {
      defer { finished.withLock { $0 = true } }
      return rejected(backend)
    }
    #expect(await eventually(.milliseconds(200)) { finished.withLock { $0 } })
    gate.signal()
    #expect(await !first.value)
    #expect(await second.value)
    #expect(backend.lifecycle == .active)
    #expect(session.isRunning)
    await backend.close()
  }

  @Test
  func failedLaunchCanBeRetried() async throws {
    let backend = LocalPTYBackend()
    #expect(throws: (any Error).self) {
      try backend.start(configuration(["/this-program-does-not-exist"]))
    }
    #expect(backend.lifecycle == .connecting)
    #expect(!backend.session.isRunning)
    try backend.start(configuration())
    #expect(backend.lifecycle == .active)
    #expect(backend.session.isRunning)
    await backend.close()
  }

  @Test(arguments: [false, true])
  func suppliedSessionCannotBypassAdmission(presentation: Bool) async throws {
    let session =
      presentation
      ? TerminalSession(presentationColumns: 20, rows: 4)
      : TerminalSession(columns: 20, rows: 4)
    if !presentation { try session.start(configuration()) }
    let backend = LocalPTYBackend(session: session)
    #expect(rejected(backend))
    #expect(backend.lifecycle == .connecting)
    #expect(session.isRunning == !presentation)
    await backend.close()
    #expect(!session.isRunning)
  }
}
#endif
