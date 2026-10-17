import Foundation
import NIOSSH
import SSHClient
import Testing

@testable import RoamingApp

/// Pairing-code key expectations are enforced before credentials, for
/// new and already-known hosts (spec.connection-setup.md T7), and a
/// failed pairing persists nothing (T6, T8).
extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct PairingTrustTests {
    static let otherPrint = "SHA256:" + String(repeating: "A", count: 43)

    struct Fixture {
      let server: TestSSHServer
      let directory: URL
      let trust: FileHostTrustStore
      let app: RoamingAppModel
      let access: SSHAccess
      let host: HostProfile

      var serverPrint: String {
        SSHPublicKeyFormat.fingerprint(openSSHPublicKey: server.hostKeyLine)!
      }
    }

    func fixture() async throws -> Fixture {
      let server = try await TestSSHServer.start()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      let trust = FileHostTrustStore(
        fileURL: directory.appendingPathComponent("trust.json")
      )
      let domain = UUID().uuidString
      let app = RoamingAppModel(
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        ),
        resumeStore: SessionResumeStore(
          defaults: UserDefaults(suiteName: domain)!
        )
      )
      return Fixture(
        server: server,
        directory: directory,
        trust: trust,
        app: app,
        access: SSHAccess(app: app, trustStore: trust),
        host: HostProfile(
          nickname: "Paired",
          host: "127.0.0.1",
          port: server.port,
          username: TestSSHServer.username
        )
      )
    }

    func finish(_ f: Fixture) async {
      await f.server.shutdown()
      try? FileManager.default.removeItem(at: f.directory)
    }

    func eventually(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(10)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test
    func unknownKeyOutsideTheCodeBlocksBeforeAnyPrompt() async throws {
      let f = try await fixture()
      await #expect(throws: SSHAccessError.hostKeyMismatch) {
        _ = try await f.access.connect(
          f.host,
          expectedHostKeys: [Self.otherPrint]
        )
      }
      #expect(f.app.pendingTrust == nil)
      #expect(f.app.pendingPassword == nil)
      #expect(f.server.state.authRequests.withLock { $0 } == 0)
      #expect(try await f.trust.trustedKey(for: f.server.identity) == nil)
      await finish(f)
    }

    @Test
    func knownKeyOutsideTheCodeBlocksWithoutReplacingIt() async throws {
      let f = try await fixture()
      try await f.trust.setTrustedKey(
        f.server.hostKeyLine,
        for: f.server.identity
      )
      await #expect(throws: SSHAccessError.hostKeyMismatch) {
        _ = try await f.access.connect(
          f.host,
          expectedHostKeys: [Self.otherPrint]
        )
      }
      #expect(f.app.pendingPassword == nil)
      #expect(f.server.state.authRequests.withLock { $0 } == 0)
      #expect(
        try await f.trust.trustedKey(for: f.server.identity)
          == f.server.hostKeyLine
      )
      await finish(f)
    }

    /// The code names the trusted key, but the server presents another:
    /// the substitution blocks and the trusted key is unchanged.
    @Test
    func substitutedServerKeyBlocksEvenWhenTheCodeMatchesTheStore() async throws
    {
      let f = try await fixture()
      let trusted = String(
        openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey
      )
      try await f.trust.setTrustedKey(trusted, for: f.server.identity)
      let trustedPrint = SSHPublicKeyFormat.fingerprint(
        openSSHPublicKey: trusted
      )!
      await #expect(throws: SSHAccessError.hostKeyMismatch) {
        _ = try await f.access.connect(f.host, expectedHostKeys: [trustedPrint])
      }
      #expect(f.app.pendingTrust == nil)
      #expect(f.app.pendingPassword == nil)
      #expect(f.server.state.authRequests.withLock { $0 } == 0)
      #expect(try await f.trust.trustedKey(for: f.server.identity) == trusted)
      await finish(f)
    }

    /// A matching code still asks for explicit trust, then stores the
    /// server's actual key and signs in.
    @Test
    func matchingCodeAsksForTrustThenStoresTheActualKey() async throws {
      let f = try await fixture()
      let connecting = Task {
        try await f.access.connect(f.host, expectedHostKeys: [f.serverPrint])
      }
      #expect(try await eventually { f.app.pendingTrust != nil })
      #expect(f.app.pendingTrust?.matchesPairingCode == true)
      #expect(f.app.pendingTrust?.fingerprint == f.serverPrint)
      #expect(f.server.state.authRequests.withLock { $0 } == 0)
      f.app.resolveTrust(.trust)
      #expect(try await eventually { f.app.pendingPassword != nil })
      f.app.resolvePassword(TestSSHServer.password)
      let connection = try await connecting.value
      await connection.close()
      #expect(
        try await f.trust.trustedKey(for: f.server.identity)
          == f.server.hostKeyLine
      )
      await finish(f)
    }

    @Test
    func failedPairingSavesNoProfileOrKey() async throws {
      let f = try await fixture()
      await #expect(throws: PairingFailure.ssh(.hostKeyMismatch)) {
        _ = try await f.app.pair(
          f.host,
          expectedHostKeys: [Self.otherPrint],
          access: f.access
        )
      }
      #expect(f.app.hosts.isEmpty)
      #expect(
        !FileManager.default.fileExists(
          atPath: f.directory.appendingPathComponent("hosts.json").path
        )
      )
      #expect(try await f.trust.trustedKey(for: f.server.identity) == nil)
      await finish(f)
    }

    @Test
    func successfulPairingSavesTheConfirmedProfileOnly() async throws {
      let f = try await fixture()
      let pairing = Task {
        try await f.app.pair(
          f.host,
          expectedHostKeys: [f.serverPrint],
          access: f.access
        )
      }
      #expect(try await eventually { f.app.pendingTrust != nil })
      f.app.resolveTrust(.trust)
      #expect(try await eventually { f.app.pendingPassword != nil })
      f.app.resolvePassword(TestSSHServer.password)
      #expect(try await pairing.value == f.host)
      #expect(f.app.hosts == [f.host])
      // No workspace was requested and nothing attached.
      #expect(f.server.state.bootstrapRequests.withLock { $0 }.isEmpty)
      #expect(f.app.activeSession == nil)
      let saved = try String(
        contentsOf: f.directory.appendingPathComponent("hosts.json"),
        encoding: .utf8
      )
      #expect(!saved.contains(TestSSHServer.password))
      #expect(!saved.contains("SHA256:"))
      await finish(f)
    }
  }
}
