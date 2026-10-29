import Foundation
@testable import RoamingApp
import Testing

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct PasswordInvalidationTests {
    @Test
    func retryReplacesAnOlderPasswordRequestAndIgnoresItsSheet() async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let app = fixture.app
      let host = fixture.host
      let first = Task { await app.password(for: host, retry: false) }
      #expect(try await eventually { app.pendingPassword != nil })
      let oldID = try #require(app.pendingPassword?.id)
      let retry = Task { await app.password(for: host, retry: true) }
      #expect(try await eventually { app.pendingPassword?.isRetry == true })
      // Release the original request too if a regression left it visible.
      if app.pendingPassword?.id == oldID {
        app.resolvePassword(nil, for: oldID)
      }
      #expect(await first.value == nil)
      let retryID = try #require(app.pendingPassword?.id)
      app.resolvePassword("obsolete", for: oldID)
      #expect(app.pendingPassword?.id == retryID)
      app.resolvePassword("fresh", for: retryID)
      #expect(await retry.value == "fresh")
    }

    @Test(arguments: [false, true])
    func failedPersistencePreservesRememberedPassword(
      deletion: Bool,
    ) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let app = fixture.app
      let host = fixture.host
      let request = Task { await app.password(for: host, retry: false) }
      #expect(try await eventually { app.pendingPassword != nil })
      app.resolvePassword("valid")
      #expect(await request.value == "valid")
      // Only the private fixture directory is replaced to force a write failure.
      try FileManager.default.removeItem(at: fixture.directory)
      try Data("blocked".utf8).write(to: fixture.directory)
      if deletion {
        app.delete(host)
      } else {
        var edited = host
        edited.host = "edited.example"
        #expect(try !app.save(edited))
      }
      #expect(app.hosts == [host])
      #expect(app.lastError != nil)
      var finished = false
      let next = Task {
        defer { finished = true }
        return await app.password(for: host, retry: false)
      }
      #expect(try await eventually { app.pendingPassword != nil || finished })
      #expect(finished)
      // Release the old implementation if it incorrectly asks again.
      app.resolvePassword("valid")
      #expect(await next.value == "valid")
    }

    @Test(arguments: [false, true])
    func deletingOneHostPreservesAnotherHostsPrompt(trust: Bool) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let helper = ConnectionPromptTests()
      let app = fixture.app
      let other = helper.host("other")
      #expect(try app.save(other))
      let first = Task {
        await helper.answer(app, host: fixture.host, trust: trust)
      }
      #expect(
        try await eventually {
          helper.pendingHost(app, trust: trust) == fixture.host.id
        }
      )
      var started = false
      let second = Task {
        started = true
        return await helper.answer(app, host: other, trust: trust)
      }
      #expect(try await eventually { started })
      app.delete(fixture.host)
      #expect(
        try await eventually {
          helper.pendingHost(app, trust: trust) == other.id
        }
      )
      // Release the original implementation without leaving tasks behind.
      if helper.pendingHost(app, trust: trust) == fixture.host.id {
        helper.resolve(app, trust: trust, allow: false)
      }
      #expect(await !(first.value))
      helper.resolve(app, trust: trust, allow: true)
      #expect(await second.value)
    }

    @Test(arguments: [false, true], [false, true])
    func changingAHostRejectsQueuedAndJustAnsweredTrust(
      deletion: Bool,
      answered: Bool,
    ) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let app = fixture.app
      let host = fixture.host
      let prompt = TrustPrompt(
        host: host,
        kind: .unknownKey,
        keyAlgorithm: "ssh-ed25519",
        fingerprint: "SHA256:old",
      )
      var finished = false
      let request = Task {
        defer { finished = true }
        return await app.requestTrust(prompt)
      }
      #expect(try await eventually { app.pendingTrust?.id == prompt.id })
      if answered { app.resolveTrust(.trust, for: prompt.id) }
      if deletion {
        app.delete(host)
      } else {
        var edited = host
        edited.host = "edited.example"
        #expect(try app.save(edited))
      }
      #expect(try await eventually { finished })
      app.resolveTrust(.trust, for: prompt.id)
      #expect(await request.value == .reject)
      #expect(app.pendingTrust == nil)
    }

    enum Invalidation: CaseIterable, Sendable {
      case deletion, edit, rejectedPassword, reload
    }

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(1)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test(arguments: Invalidation.allCases)
    func invalidatingAHostCancelsPendingPasswordsAndStaleAnswers(
      invalidation: Invalidation,
    ) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let app = fixture.app
      let host = fixture.host
      var finished = false
      let request = Task {
        defer { finished = true }
        return await app.password(for: host, retry: false)
      }
      #expect(try await eventually { app.pendingPassword != nil })
      let staleID = try #require(app.pendingPassword?.id)
      switch invalidation {
      case .deletion:
        app.delete(host)
        #expect(try !app.save(host))
        #expect(app.hosts.isEmpty)  // A tombstone is never revived.
      case .edit:
        var edited = host
        edited.host = "edited.example"
        #expect(try app.save(edited))
        #expect(try app.save(host))
      case .rejectedPassword: app.forgetPassword(for: host)
      case .reload:
        let store = ConnectionStore(
          fileURL: fixture.directory.appendingPathComponent("hosts.json")
        )
        var edited = host
        edited.host = "edited.example"
        try store.save([edited])
        app.load()
        try store.save([host])
        app.load()
      }
      #expect(try await eventually { finished })
      app.resolvePassword("obsolete", for: staleID)
      #expect(await request.value == nil)
      var nextFinished = false
      let next = Task {
        defer { nextFinished = true }
        return await app.password(for: host, retry: false)
      }
      #expect(
        try await eventually { app.pendingPassword != nil || nextFinished }
      )
      #expect(app.pendingPassword?.host.id == host.id)
      app.resolvePassword("fresh")
      #expect(await next.value == "fresh")
    }

    @Test(arguments: Invalidation.allCases)
    func invalidationAfterAnswerBeforeTheCallerResumesDoesNotRecache(
      invalidation: Invalidation,
    ) async throws {
      let fixture = try Fixture()
      defer { fixture.cleanup() }
      let app = fixture.app
      let host = fixture.host
      let request = Task { await app.password(for: host, retry: false) }
      #expect(try await eventually { app.pendingPassword != nil })
      app.resolvePassword("obsolete")
      // No suspension between resolving the continuation and invalidating it.
      switch invalidation {
      case .deletion:
        app.delete(host)
        #expect(try !app.save(host))
        #expect(app.hosts.isEmpty)  // A tombstone is never revived.
      case .edit:
        var edited = host
        edited.host = "edited.example"
        #expect(try app.save(edited))
        #expect(try app.save(host))
      case .rejectedPassword: app.forgetPassword(for: host)
      case .reload:
        let store = ConnectionStore(
          fileURL: fixture.directory.appendingPathComponent("hosts.json")
        )
        var edited = host
        edited.host = "edited.example"
        try store.save([edited])
        app.load()
        try store.save([host])
        app.load()
      }
      #expect(await request.value == nil)
      var finished = false
      let next = Task {
        defer { finished = true }
        return await app.password(for: host, retry: false)
      }
      #expect(try await eventually { app.pendingPassword != nil || finished })
      #expect(app.pendingPassword != nil)
      app.resolvePassword("fresh")
      #expect(await next.value == "fresh")
    }
  }
}

@MainActor
private struct Fixture {
  let directory: URL
  let defaults: UserDefaults
  let suite: String
  let app: RoamingAppModel
  let host: HostProfile

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "password-invalidation-" + UUID().uuidString
    )
    suite = "password-invalidation-" + UUID().uuidString
    defaults = try #require(UserDefaults(suiteName: suite))
    app = RoamingAppModel(
      store: ConnectionStore(
        fileURL: directory.appendingPathComponent("hosts.json")
      ),
      resumeStore: SessionResumeStore(defaults: defaults),
    )
    host = HostProfile(nickname: "Host", host: "host.example", username: "test")
    #expect(try app.save(host))
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
    defaults.removePersistentDomain(forName: suite)
  }
}
