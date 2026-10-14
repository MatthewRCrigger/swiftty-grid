import NIOCore
import NIOPosix
import NIOSSH
@testable import SSHClient
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ConnectionAttemptTests {
  private func withServer(
    _ body: @Sendable (TestSSHServer) async throws -> Void,
  ) async throws {
    let server = try await TestSSHServer.start()
    do { try await body(server) } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  @Test(arguments: [false, true])
  func abortedWaitReturnsBeforeTheBackendAndClosesItsLateSocket(
    timeout: Bool,
  ) async throws {
    try await withServer { server in
      let connection = try await server.connect()
      let loop = connection.channel.eventLoop
      let backend = loop.makePromise(of: (any Channel).self)
      let attempt = ConnectionAttempt(deadline: .now() + .seconds(5))
      let discarded = Mutex(false)
      let waiter = Task {
        try await attempt.wait(for: backend.futureResult) { channel in
          discarded.withLock { $0 = true }
          channel.close(promise: nil)
        }
      }
      if timeout {
        attempt.abort(SSHClientError.connectTimeout)
      } else {
        attempt.abort(CancellationError())
      }
      if case let .failure(error) = await waiter.result {
        if timeout {
          #expect(error as? SSHClientError == .connectTimeout)
        } else {
          #expect(error is CancellationError)
        }
      } else {
        Issue.record("Cancelled wait succeeded")
      }
      // Backend did not honor cancellation. Its late result still has an owner.
      backend.succeed(connection.channel)
      try await connection.closeFuture.get()
      #expect(discarded.withLock { $0 })
    }
  }

  @Test
  func abortClosesEveryCandidateAndRejectsNewCandidates() async throws {
    try await withServer { server in
      let first = try await server.connect()
      let second = try await server.connect()
      let attempt = ConnectionAttempt(deadline: .now() + .seconds(5))
      try attempt.register(first.channel)
      try attempt.register(second.channel)
      attempt.abort(CancellationError())
      try await first.closeFuture.get()
      try await second.closeFuture.get()
      let late = try await server.connect()
      #expect(throws: CancellationError.self) {
        try attempt.register(late.channel)
      }
      try await late.closeFuture.get()
    }
  }

  @Test
  func handoffKeepsOnlyTheWinnerAndEndsAttemptOwnership() async throws {
    try await withServer { server in
      let first = try await server.connect()
      let second = try await server.connect()
      let attempt = ConnectionAttempt(deadline: .now() + .seconds(5))
      try attempt.register(first.channel)
      try attempt.register(second.channel)
      try attempt.finish(keeping: first.channel)
      try await second.closeFuture.get()
      attempt.abort(SSHClientError.connectTimeout)
      #expect(first.isActive)
      await first.close()
    }
  }

  @Test
  func expiredAttemptCannotHandOffAnAuthenticatedSocket() async throws {
    try await withServer { server in
      let connection = try await server.connect()
      let attempt = ConnectionAttempt(deadline: .now() + .seconds(1))
      try attempt.register(connection.channel)
      try await Task.sleep(for: .milliseconds(1100))
      #expect(throws: SSHClientError.connectTimeout) {
        try attempt.finish(keeping: connection.channel)
      }
      try await connection.closeFuture.get()
    }
  }

  @Test
  func abortedAttemptCannotOfferCredentials() async throws {
    let loop = MultiThreadedEventLoopGroup.singleton.next()
    let attempt = ConnectionAttempt(deadline: .now() + .seconds(5))
    attempt.abort(CancellationError())
    let delegate = CredentialOfferDelegate(
      username: "test",
      credential: .password("test"),
      attempt: attempt,
    )
    let challenge = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
    delegate.nextAuthenticationType(
      availableMethods: .password,
      nextChallengePromise: challenge,
    )
    do {
      _ = try await challenge.futureResult.get()
      Issue.record("Aborted attempt offered a credential")
    } catch { #expect(error is CancellationError) }
    #expect(!delegate.offered.withLock { $0 })
  }

  @Test(arguments: [false, true])
  func productionConnectionWorksWithBothBootstrapDrivers(
    posix: Bool,
  ) async throws {
    try await withServer { server in
      var configuration = server.configuration()
      configuration.host = "localhost"
      let identity = try #require(configuration.hostIdentity)
      let store = InMemoryHostTrustStore(keys: [identity: server.hostKeyLine])
      let connection = try await SSHConnection.connect(
        configuration: configuration,
        credential: .password(TestSSHServer.password),
        trustStore: store,
        trustDecider: RejectUnknownHostKeys(),
        eventLoopGroup: posix ? MultiThreadedEventLoopGroup.singleton : nil,
      )
      #expect(connection.isActive)
      await connection.close()
    }
  }
}
