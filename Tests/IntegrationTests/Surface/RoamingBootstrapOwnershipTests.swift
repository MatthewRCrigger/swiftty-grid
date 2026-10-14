import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RoamingBootstrapOwnershipTests {
  private actor Bootstrapper: RemoteBootstrapper {
    let host: FakeHost
    let holdCreates: Bool
    private(set) var requests: [BootstrapRequest] = []
    private(set) var returned: Set<Int> = []
    private var pending:
      [Int: CheckedContinuation<
        Result<BootstrapResponse, RemoteBootstrapError>, Never,
      >] = [:]

    init(host: FakeHost, holdCreates: Bool = true) {
      self.host = host
      self.holdCreates = holdCreates
    }

    func bootstrap(
      _ request: BootstrapRequest
    ) async throws -> BootstrapResponse {
      let index = requests.count
      requests.append(request)
      if !holdCreates, request.operation == .create {
        return await host.bootstrap(request)
      }
      let response = await withCheckedContinuation { pending[index] = $0 }
      returned.insert(index)
      return try response.get()
    }

    func respond(
      _ index: Int,
      _ result: Result<BootstrapResponse, RemoteBootstrapError>,
    ) { pending.removeValue(forKey: index)?.resume(returning: result) }

    func releaseAll(_ result: Result<BootstrapResponse, RemoteBootstrapError>) {
      let waiting = pending
      pending = [:]
      for waiter in waiting.values { waiter.resume(returning: result) }
    }
  }

  private static func start(
    _ client: RoamingClient
  ) async -> RoamingClientError? {
    do {
      try await client.start(.create(GridSize(columns: 20, rows: 4)))
      return nil
    } catch { return error }
  }

  @Test
  func overlappingStartsIssueOnlyOneBootstrap() async throws {
    let host = try FakeHost()
    let bootstrapper = Bootstrapper(host: host)
    let client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: FakeConnector(host: host),
    )
    let first = Task { await Self.start(client) }
    try #require(await eventually { await bootstrapper.requests.count == 1 })
    let finished = Mutex(false)
    let second = Task {
      let result = await Self.start(client)
      finished.withLock { $0 = true }
      return result
    }
    #expect(await eventually(.milliseconds(100)) { finished.withLock { $0 } })
    #expect(await bootstrapper.requests.count == 1)
    let response = await BootstrapResponse.granted(host.makeGrant())
    await bootstrapper.respond(0, .success(response))
    #expect(await first.value == nil)
    await bootstrapper.releaseAll(.success(response))
    #expect(await second.value == .invalidState(.sshBootstrap))
    await client.close()
  }

  @Test
  func failedBootstrapCanBeRetried() async throws {
    let host = try FakeHost()
    let bootstrapper = Bootstrapper(host: host)
    let client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: FakeConnector(host: host),
    )
    let first = Task { await Self.start(client) }
    try #require(await eventually { await bootstrapper.requests.count == 1 })
    await bootstrapper.respond(0, .failure(.authenticationFailed))
    #expect(await first.value == .authenticationFailed)
    let next = Task { await Self.start(client) }
    try #require(await eventually { await bootstrapper.requests.count == 2 })
    await bootstrapper.respond(1, .success(.granted(host.makeGrant())))
    #expect(await next.value == nil)
    #expect(await eventually { await client.state == .active })
    await client.close()
  }

  enum Abort: CaseIterable { case close, cancel, background }

  @Test(arguments: [false, true], Abort.allCases)
  func obsoleteInitialResponseCannotChangeStatus(
    error: Bool,
    abort: Abort,
  ) async throws {
    let host = try FakeHost()
    let bootstrapper = Bootstrapper(host: host)
    let client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: FakeConnector(host: host),
    )
    let finished = Mutex(false)
    let first = Task {
      let result = await Self.start(client)
      finished.withLock { $0 = true }
      return result
    }
    try #require(await eventually { await bootstrapper.requests.count == 1 })
    switch abort {
    case .cancel: first.cancel()
    case .close: await client.close()
    case .background: await client.enterBackground()
    }
    let before = await client.status
    #expect(await eventually(.milliseconds(100)) { finished.withLock { $0 } })
    let result: Result<BootstrapResponse, RemoteBootstrapError> =
      await error
      ? .failure(.authenticationFailed) : .success(.granted(host.makeGrant()))
    await bootstrapper.respond(0, result)
    let failure = await first.value
    #expect(failure != nil)
    #expect(failure == .cancelled)
    #expect(await client.status == before)
    #expect(await host.attachCount == 0)
    await client.close()
  }

  enum StaleResponse: CaseIterable { case error, missing, writer }

  @Test(arguments: StaleResponse.allCases)
  func obsoleteRefreshCannotChangeTheNewAttachment(
    response: StaleResponse,
  ) async throws {
    let host = try FakeHost()
    let bootstrapper = Bootstrapper(host: host, holdCreates: false)
    let clock = TestClock(factor: 1)
    let client = RoamingClient(
      bootstrapper: bootstrapper,
      connector: FakeConnector(host: host),
      configuration: RoamingClientConfiguration(
        detachDeadline: .milliseconds(50),
      ),
      timing: clock.timing,
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    try #require(await eventually { await client.state == .active })
    await host.blackHoleCurrent()
    #expect(await client.submit(.text("pending")) == .accepted(sequence: 1))
    await host.set(dropInputsAfter: 0, sendSnapshotOnAttach: false)
    clock.advanceWallClock(by: 3601)
    await client.enterBackground()
    await client.enterForeground()
    try #require(await eventually { await bootstrapper.requests.count == 2 })
    await client.enterBackground()
    await client.enterForeground()
    #expect(
      await eventually(.milliseconds(100)) {
        await client.status.reconnectAttempt > 0
      }
    )
    #expect(await bootstrapper.requests.count == 2)
    let before = await client.status
    let stale: Result<BootstrapResponse, RemoteBootstrapError>
    switch response {
    case .error: stale = .failure(.authenticationFailed)
    case .missing: stale = .success(.failure(.unknownSession))
    case .writer:
      var old = await host.makeGrant()
      old.writerID = WriterID.random()
      stale = .success(.granted(old))
    }
    await bootstrapper.respond(1, stale)
    try #require(await eventually { await bootstrapper.returned.contains(1) })
    #expect(await client.state == .sshBootstrap)
    #expect(await client.status.lastFailure == before.lastFailure)
    #expect(await client.status.sessionID == before.sessionID)
    #expect(await client.status.pendingInputCount == 1)
    try #require(await eventually { await bootstrapper.requests.count == 3 })
    clock.advanceWallClock(by: -3601)
    let request = await bootstrapper.requests[2]
    await bootstrapper.respond(2, .success(host.bootstrap(request)))
    try #require(await eventually { await host.attachCount == 2 })
    #expect(await client.state == .attaching)
    #expect(await client.status.pendingInputCount == 1)
    await host.sendScreen()
    #expect(
      await eventually(.milliseconds(200)) { await client.state == .active }
    )
    #expect(await client.status.pendingInputCount == 1)
    await client.close()
  }
}
