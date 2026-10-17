import Foundation
@testable import RoamingApp
import SSHClient
import Testing

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct StaleAuthenticationTests {
    @Test
    func retryForAnOldSnapshotDoesNotReplaceTheEditedProfilesPassword()
      async throws
    {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("snapshot-retry-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let app = RoamingAppModel(
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        )
      )
      let original = HostProfile(
        nickname: "Old",
        host: "old.example",
        username: "test",
      )
      #expect(try app.save(original))
      var edited = original
      edited.host = "new.example"
      #expect(try app.save(edited))
      let newer = edited
      let first = Task { await app.password(for: newer, retry: false) }
      #expect(try await eventually { app.pendingPassword != nil })
      app.resolvePassword("new")
      #expect(await first.value == "new")
      let old = Task { await app.password(for: original, retry: true) }
      #expect(try await eventually { app.pendingPassword?.host == original })
      app.resolvePassword("old")
      #expect(await old.value == "old")
      var finished = false
      let next = Task {
        defer { finished = true }
        return await app.password(for: newer, retry: false)
      }
      #expect(try await eventually { finished || app.pendingPassword != nil })
      #expect(finished)
      app.resolvePassword("new")
      #expect(await next.value == "new")
    }

    @Test(arguments: [false, true])
    func automaticRetryUsesANewerPasswordOrPromptsForTheRejectedOne(
      fresh: Bool,
    ) async throws {
      let server = try await TestSSHServer.start()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auth-retry-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      do {
        let app = RoamingAppModel(
          store: ConnectionStore(
            fileURL: directory.appendingPathComponent("hosts.json")
          )
        )
        let host = HostProfile(
          nickname: "Host",
          host: "127.0.0.1",
          port: server.port,
          username: TestSSHServer.username,
        )
        #expect(try app.save(host))
        let trust = FileHostTrustStore(
          fileURL: directory.appendingPathComponent("keys.json")
        )
        try await trust.setTrustedKey(server.hostKeyLine, for: server.identity)
        let access = SSHAccess(app: app, trustStore: trust)
        let initial = Task { await app.password(for: host, retry: false) }
        #expect(try await eventually { app.pendingPassword != nil })
        app.resolvePassword("incorrect")
        #expect(await initial.value == "incorrect")
        server.state.faults.withLock { $0.holdNextPasswordAuth = true }
        var finished = false
        let login = Task {
          defer { finished = true }
          return try await access.connect(host)
        }
        #expect(
          try await eventually {
            server.state.heldPasswordAuth.withLock { $0 != nil }
          }
        )
        if fresh {
          app.forgetPassword(for: host)
          let replacement = Task { await app.password(for: host, retry: false) }
          #expect(try await eventually { app.pendingPassword != nil })
          app.resolvePassword(TestSSHServer.password)
          #expect(await replacement.value == TestSSHServer.password)
        }
        let held = server.state.heldPasswordAuth.withLock { value in
          let held = value
          value = nil
          return held
        }
        held?.succeed(.failure)
        #expect(try await eventually { finished || app.pendingPassword != nil })
        if fresh {
          #expect(finished)
        } else {
          #expect(!finished)
          #expect(app.pendingPassword?.isRetry == true)
        }
        // Also release a repeated prompt on the original implementation.
        app.resolvePassword(TestSSHServer.password)
        let connection = try await login.value
        let active = connection.isActive
        #expect(active)
        #expect(server.state.authRequests.withLock { $0 } >= 2)
        await connection.close()
      } catch {
        await server.shutdown()
        throw error
      }
      await server.shutdown()
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(2)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test(arguments: [false, true], [false, true])
    func oldAuthenticationFailurePreservesNewProfileCredentials(
      pending: Bool,
      editedProfile: Bool,
    ) async throws {
      let server = try await TestSSHServer.start()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("stale-auth-" + UUID().uuidString)
      let suite = "stale-auth-" + UUID().uuidString
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
      }
      do {
        let app = RoamingAppModel(
          store: ConnectionStore(
            fileURL: directory.appendingPathComponent("hosts.json")
          ),
          resumeStore: SessionResumeStore(defaults: defaults),
        )
        let original = HostProfile(
          nickname: "Original",
          host: "127.0.0.1",
          port: server.port,
          username: TestSSHServer.username,
        )
        #expect(try app.save(original))
        let trust = FileHostTrustStore(
          fileURL: directory.appendingPathComponent("keys.json")
        )
        try await trust.setTrustedKey(server.hostKeyLine, for: server.identity)
        let access = SSHAccess(app: app, trustStore: trust)
        server.state.faults.withLock { $0.holdNextPasswordAuth = true }
        let old = Task {
          try await access.connect(
            original,
            credential: .password("incorrect"),
          )
        }
        #expect(
          try await eventually {
            server.state.heldPasswordAuth.withLock { $0 != nil }
          }
        )
        var edited = original
        if editedProfile { edited.host = "new.example" }
        #expect(try app.save(edited))
        let newer = edited
        var finished = false
        let password = Task {
          defer { finished = true }
          return await app.password(for: newer, retry: false)
        }
        #expect(try await eventually { app.pendingPassword?.host == newer })
        let promptID = try #require(app.pendingPassword?.id)
        if !pending {
          app.resolvePassword("fresh", for: promptID)
          #expect(await password.value == "fresh")
        }
        let held = server.state.heldPasswordAuth.withLock { value in
          let held = value
          value = nil
          return held
        }
        held?.succeed(.failure)
        await #expect(
          throws: SSHAccessError.authenticationFailed(publicKeyLine: nil)
        ) { _ = try await old.value }
        if pending {
          #expect(app.pendingPassword?.id == promptID)
          #expect(!finished)
          app.resolvePassword("fresh", for: promptID)
          #expect(await password.value == "fresh")
        } else {
          var recalled = false
          let next = Task {
            defer { recalled = true }
            return await app.password(for: newer, retry: false)
          }
          #expect(
            try await eventually { recalled || app.pendingPassword != nil }
          )
          #expect(recalled)
          app.resolvePassword("fresh")
          #expect(await next.value == "fresh")
        }
      } catch {
        await server.shutdown()
        throw error
      }
      await server.shutdown()
    }
  }
}
