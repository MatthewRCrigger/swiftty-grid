import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RoamingTerminationDeadlineTests {
  private actor StartGate {
    private var waiter: CheckedContinuation<Void, Never>?
    var waiting: Bool { waiter != nil }

    func wait() async { await withCheckedContinuation { waiter = $0 } }

    func release() {
      let pending = waiter
      waiter = nil
      pending?.resume()
    }
  }

  private actor HeldBootstrapper: RemoteBootstrapper {
    let host: FakeHost
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var cancelled = false

    init(host: FakeHost) { self.host = host }

    func bootstrap(
      _ request: BootstrapRequest
    ) async throws -> BootstrapResponse {
      if request.operation == .terminate {
        entered = true
        await withCheckedContinuation { waiter = $0 }
        cancelled = Task.isCancelled
      }
      return await host.bootstrap(request)
    }

    func release() {
      let pending = waiter
      waiter = nil
      pending?.resume()
    }
  }

  @Test(arguments: [false, true])
  func closeDoesNotWaitForANoncooperativeTerminate(cancel: Bool) async throws {
    let host = try FakeHost()
    let bootstrapper = HeldBootstrapper(host: host)
    let client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: FakeConnector(host: host),
      configuration: RoamingClientConfiguration(
        initialGrid: GridSize(columns: 20, rows: 4),
        detachDeadline: cancel ? .seconds(10) : .milliseconds(50),
        livenessTick: .seconds(5),
      ),
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await client.state == .active })
    await client.enterBackground()
    #expect(await client.state == .backgroundDetached)
    let finished = Mutex(false)
    let close = Task {
      await client.close(.terminate)
      finished.withLock { $0 = true }
    }
    try #require(await eventually { await bootstrapper.entered })
    if cancel { close.cancel() }
    #expect(await eventually(.milliseconds(250)) { finished.withLock { $0 } })
    #expect(await client.state == .userClosed)
    // Release the uncooperative RPC even on the original implementation.
    await bootstrapper.release()
    await close.value
    #expect(await eventually { await bootstrapper.cancelled })
    #expect(await eventually { await host.terminateCount == 1 })
    #expect(await client.state == .userClosed)
    #expect(await client.submit(.text("late")) == .refused(.closed))
  }

  @Test
  func cancelledCloseDoesNotStartRemoteTermination() async throws {
    let host = try FakeHost()
    let bootstrapper = HeldBootstrapper(host: host)
    let client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: FakeConnector(host: host),
      configuration: RoamingClientConfiguration(
        detachDeadline: .milliseconds(50),
      ),
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await client.state == .active })
    await client.enterBackground()
    let gate = StartGate()
    let finished = Mutex(false)
    let close = Task {
      await gate.wait()
      await client.close(.terminate)
      finished.withLock { $0 = true }
    }
    try #require(await eventually { await gate.waiting })
    close.cancel()
    await gate.release()
    #expect(await eventually(.milliseconds(250)) { finished.withLock { $0 } })
    #expect(await !(bootstrapper.entered))
    await bootstrapper.release()
    await close.value
    #expect(await host.terminateCount == 0)
    #expect(await client.state == .userClosed)
  }
}
