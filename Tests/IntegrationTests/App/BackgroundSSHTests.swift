import Foundation
import NIOSSH
import SSHClient
import Testing

@testable import RoamingApp

extension MainActorIntegrationTests {
  @MainActor
  struct BackgroundSSHTests {
    @Test(arguments: [false, true])
    func automaticConnectDoesNotAskForPasswordOrUnknownTrust(
      password: Bool
    ) async throws {
      let server = try await TestSSHServer.start()
      defer { Task { await server.shutdown() } }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let app = RoamingAppModel()
      let access = SSHAccess(
        app: app,
        trustStore: FileHostTrustStore(
          fileURL: directory.appendingPathComponent("trust.json")
        )
      )
      let host = HostProfile(
        nickname: "Test",
        host: "127.0.0.1",
        port: server.port,
        username: TestSSHServer.username,
        auth: password ? .password : .key(identityID: UUID())
      )
      await #expect(
        throws: password ? SSHAccessError.cancelled : .hostKeyRejected
      ) { _ = try await access.connect(host, interactive: false) }
      #expect(app.pendingTrust == nil)
      #expect(app.pendingPassword == nil)
      #expect(server.state.authRequests.withLock { $0 } == 0)
    }

    @Test
    func automaticConnectReportsChangedTrustWithoutPresentingAQuestion()
      async throws
    {
      let server = try await TestSSHServer.start()
      defer { Task { await server.shutdown() } }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let trust = FileHostTrustStore(
        fileURL: directory.appendingPathComponent("trust.json")
      )
      let other = NIOSSHPrivateKey(ed25519Key: .init())
      try await trust.setTrustedKey(
        String(openSSHPublicKey: other.publicKey),
        for: server.identity
      )
      let app = RoamingAppModel()
      let access = SSHAccess(app: app, trustStore: trust)
      let host = HostProfile(
        nickname: "Test",
        host: "127.0.0.1",
        port: server.port,
        username: TestSSHServer.username
      )
      await #expect(throws: SSHAccessError.hostKeyChanged) {
        _ = try await access.connect(
          host,
          credential: .password(TestSSHServer.password),
          interactive: false
        )
      }
      #expect(app.pendingTrust == nil)
      #expect(app.pendingPassword == nil)
      #expect(server.state.authRequests.withLock { $0 } == 0)
    }
  }
}
