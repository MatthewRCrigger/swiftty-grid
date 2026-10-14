import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RoamingProviderAdmissionTests {
  private actor Provider: RemoteBootstrapper, RSTConnector {
    let host: FakeHost
    let holdBootstrap: Bool
    let holdResume: Bool
    private(set) var bootstrapCalls = 0
    private(set) var bootstrapInFlight = 0
    private(set) var maxBootstrapInFlight = 0
    private(set) var connectCalls = 0
    private(set) var connectInFlight = 0
    private(set) var maxConnectInFlight = 0
    private var bootstraps: [CheckedContinuation<Void, Never>] = []
    private var connects: [CheckedContinuation<Void, Never>] = []
    private var connections: [InMemoryRSTConnection] = []

    init(host: FakeHost, holdBootstrap: Bool, holdResume: Bool = false) {
      self.host = host
      self.holdBootstrap = holdBootstrap
      self.holdResume = holdResume
    }

    func bootstrap(
      _ request: BootstrapRequest
    ) async throws -> BootstrapResponse {
      bootstrapCalls += 1
      bootstrapInFlight += 1
      maxBootstrapInFlight = max(maxBootstrapInFlight, bootstrapInFlight)
      defer { bootstrapInFlight -= 1 }
      if holdBootstrap || (holdResume && request.operation == .resume) {
        await withCheckedContinuation { bootstraps.append($0) }
        return await .granted(host.makeGrant())
      }
      return await host.bootstrap(request)
    }

    func connect(to _: BootstrapGrant) async throws -> any RSTConnection {
      connectCalls += 1
      connectInFlight += 1
      maxConnectInFlight = max(maxConnectInFlight, connectInFlight)
      defer { connectInFlight -= 1 }
      await withCheckedContinuation { connects.append($0) }
      let (client, server) = InMemoryRSTConnection.pair()
      await host.accept(server)
      connections.append(client)
      return client
    }

    func releaseBootstrap() {
      let waiting = bootstraps
      bootstraps = []
      for waiter in waiting { waiter.resume() }
    }

    func releaseConnections() {
      let waiting = connects
      connects = []
      for waiter in waiting { waiter.resume() }
    }

    var allConnectionsClosed: Bool {
      connectInFlight == 0 && connections.allSatisfy(\.isClosed)
    }
  }

  @Test
  func repeatedCancelledStartsKeepOneProviderExecutionAndRecover() async throws
  {
    let host = try FakeHost()
    let provider = Provider(host: host, holdBootstrap: true)
    let client = RoamingClient(bootstrapper: provider, connector: provider)
    for _ in 0 ..< 20 {
      let previous = await provider.bootstrapCalls
      let done = Mutex(false)
      let task = Task {
        defer { done.withLock { $0 = true } }
        do {
          try await client.start(.create(GridSize(columns: 20, rows: 4)))
        } catch {}
      }
      #expect(
        await eventually(.milliseconds(200)) {
          if done.withLock({ $0 }) { return true }
          return await provider.bootstrapCalls > previous
        }
      )
      task.cancel()
      await task.value
    }
    #expect(await provider.bootstrapCalls == 1)
    #expect(await provider.maxBootstrapInFlight == 1)
    let previous = await provider.bootstrapCalls
    await provider.releaseBootstrap()
    #expect(await eventually { await provider.bootstrapInFlight == 0 })
    let fresh = Task {
      try await client.start(.create(GridSize(columns: 20, rows: 4, )))
    }
    #expect(await eventually { await provider.bootstrapCalls > previous })
    #expect(await provider.bootstrapCalls == 2)
    await provider.releaseBootstrap()
    try await fresh.value
    #expect(await client.status.sessionID == host.sessionID)
    await client.close()
    await provider.releaseConnections()
    #expect(await eventually { await provider.allConnectionsClosed })
  }

  @Test
  func terminationReachesHostWhileRefreshAndConnectorAreHeld() async throws {
    let host = try FakeHost()
    let provider = Provider(host: host, holdBootstrap: false, holdResume: true)
    let clock = TestClock(factor: 20)
    let client = RoamingClient(
      bootstrapper: provider,
      connector: provider,
      configuration: RoamingClientConfiguration(
        attachTimeout: .seconds(1),
        backoffJitter: 0,
      ),
      timing: clock.timing,
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(
      await eventually(.seconds(2)) { await provider.bootstrapCalls == 2 }
    )
    #expect(await provider.bootstrapInFlight == 1)
    #expect(await provider.connectInFlight == 1)
    await client.close(.terminate)
    #expect(await host.terminateCount == 1)
    #expect(await provider.maxBootstrapInFlight == 2)
    await provider.releaseBootstrap()
    await provider.releaseConnections()
    #expect(
      await eventually {
        let bootstrapFinished = await provider.bootstrapInFlight == 0
        let connectionsClosed = await provider.allConnectionsClosed
        return bootstrapFinished && connectionsClosed
      }
    )
  }

  @Test
  func timedOutConnectRetriesKeepOneProviderExecution() async throws {
    let host = try FakeHost()
    let provider = Provider(host: host, holdBootstrap: false)
    let clock = TestClock(factor: 20)
    let client = RoamingClient(
      bootstrapper: provider,
      connector: provider,
      configuration: RoamingClientConfiguration(
        attachTimeout: .seconds(1),
        backoffJitter: 0,
      ),
      timing: clock.timing,
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(
      await eventually(.seconds(2)) {
        await client.status.reconnectAttempt >= 3
      }
    )
    #expect(await provider.connectCalls == 1)
    #expect(await provider.maxConnectInFlight == 1)
    #expect(await client.status.lastFailure == .attachTimedOut)
    await client.close()
    await provider.releaseConnections()
    #expect(await eventually { await provider.allConnectionsClosed })
  }
}
