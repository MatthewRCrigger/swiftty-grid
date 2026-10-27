import Foundation
import Testing

@testable import RoamingApp

@MainActor
private func promptEventually(_ condition: () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now + .seconds(1)
  while !condition() {
    guard ContinuousClock.now < deadline else { return false }
    try await Task.sleep(for: .milliseconds(5))
  }
  return true
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct ConnectionPromptTests {
    func host(_ name: String) -> HostProfile {
      HostProfile(nickname: name, host: name + ".local", username: "test")
    }

    func answer(
      _ app: RoamingAppModel,
      host: HostProfile,
      trust: Bool
    ) async -> Bool {
      if trust {
        return await app.requestTrust(
          TrustPrompt(
            host: host,
            kind: .unknownKey,
            keyAlgorithm: "ssh-ed25519",
            fingerprint: "SHA256:test"
          )
        ) == .trust
      }
      return await app.password(for: host, retry: false) != nil
    }

    func pendingHost(_ app: RoamingAppModel, trust: Bool) -> UUID? {
      trust ? app.pendingTrust?.host.id : app.pendingPassword?.host.id
    }

    func resolve(_ app: RoamingAppModel, trust: Bool, allow: Bool) {
      if trust {
        app.resolveTrust(allow ? .trust : .reject)
      } else {
        app.resolvePassword(allow ? "test-password" : nil)
      }
    }

    @Test(arguments: [false, true])
    func cancellingTheVisiblePromptAdvancesTheQueue(trust: Bool) async throws {
      let app = RoamingAppModel()
      let firstHost = host("first")
      let secondHost = host("second")
      let first = Task { await answer(app, host: firstHost, trust: trust) }
      #expect(
        try await promptEventually {
          pendingHost(app, trust: trust) == firstHost.id
        }
      )
      var secondStarted = false
      let second = Task {
        secondStarted = true
        return await answer(app, host: secondHost, trust: trust)
      }
      #expect(try await promptEventually { secondStarted })
      first.cancel()
      #expect(
        try await promptEventually {
          pendingHost(app, trust: trust) == secondHost.id
        }
      )
      // Unblock the old implementation too, so a regression fails without hanging.
      if pendingHost(app, trust: trust) == firstHost.id {
        resolve(app, trust: trust, allow: false)
      }
      #expect(!(await first.value))
      resolve(app, trust: trust, allow: true)
      #expect(await second.value)
      #expect(pendingHost(app, trust: trust) == nil)
    }

    @Test(arguments: [false, true])
    func cancellingAQueuedPromptLeavesTheVisiblePromptAlone(
      trust: Bool
    ) async throws {
      let app = RoamingAppModel()
      let firstHost = host("first")
      let secondHost = host("second")
      let first = Task { await answer(app, host: firstHost, trust: trust) }
      #expect(
        try await promptEventually {
          pendingHost(app, trust: trust) == firstHost.id
        }
      )
      var started = false
      var finished = false
      let second = Task {
        started = true
        defer { finished = true }
        return await answer(app, host: secondHost, trust: trust)
      }
      #expect(try await promptEventually { started })
      let cancelledAt = ContinuousClock.now
      second.cancel()
      let finishedInTime = try await promptEventually { finished }
      #expect(
        finishedInTime,
        Comment(
          rawValue: """
            elapsed=\(ContinuousClock.now - cancelledAt), cancelled=\(second.isCancelled)
            started=\(started), finished=\(finished), trust=\(trust)
            visible=\(String(describing: pendingHost(app, trust: trust)))
            first=\(firstHost.id), second=\(secondHost.id)
            """
        )
      )
      #expect(pendingHost(app, trust: trust) == firstHost.id)
      resolve(app, trust: trust, allow: true)
      #expect(await first.value)
      if pendingHost(app, trust: trust) == secondHost.id {
        resolve(app, trust: trust, allow: false)
      }
      #expect(!(await second.value))
      #expect(pendingHost(app, trust: trust) == nil)
    }

    @Test(arguments: [false, true])
    func queuedCancellationRemovesPromptBeforeAnotherMainActorTurn(
      trust: Bool
    ) async throws {
      let app = RoamingAppModel()
      let firstHost = host("first")
      let secondHost = host("second")
      // Immediate tasks reach their prompt continuations before returning.
      let first = Task.immediate {
        await answer(app, host: firstHost, trust: trust)
      }
      #expect(pendingHost(app, trust: trust) == firstHost.id)
      let second = Task.immediate {
        await answer(app, host: secondHost, trust: trust)
      }
      second.cancel()
      #expect(pendingHost(app, trust: trust) == firstHost.id)
      resolve(app, trust: trust, allow: true)
      // There is deliberately no suspension between cancellation, resolving
      // the visible prompt, and checking that the cancelled one cannot appear.
      #expect(pendingHost(app, trust: trust) == nil)
      if pendingHost(app, trust: trust) == secondHost.id {
        resolve(app, trust: trust, allow: false)
      }
      #expect(await first.value)
      #expect(!(await second.value))
      #expect(pendingHost(app, trust: trust) == nil)
    }

    @Test
    func delayedPasswordAnswerIsNotReusedForAnEditedHost() async throws {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let app = RoamingAppModel(
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        )
      )
      let original = host("first")
      try app.save(original)
      let request = Task { await app.password(for: original, retry: false) }
      #expect(try await promptEventually { app.pendingPassword != nil })
      var edited = original
      edited.host = "other.local"
      try app.save(edited)
      app.resolvePassword("original-password")
      _ = await request.value
      var finished = false
      let next = Task {
        defer { finished = true };
        return await app.password(for: edited, retry: false)
      }
      #expect(
        try await promptEventually { app.pendingPassword != nil || finished }
      )
      #expect(app.pendingPassword?.host == edited)
      app.resolvePassword(nil)
      #expect(await next.value == nil)
    }

    @Test(arguments: [false, true])
    func staleSheetAnswersCannotResolveTheNextPrompt(trust: Bool) async throws {
      let app = RoamingAppModel()
      let firstHost = host("first")
      let secondHost = host("second")
      let first = Task { await answer(app, host: firstHost, trust: trust) }
      #expect(
        try await promptEventually {
          pendingHost(app, trust: trust) == firstHost.id
        }
      )
      let staleID = try #require(
        trust ? app.pendingTrust?.id : app.pendingPassword?.id
      )
      let second = Task { await answer(app, host: secondHost, trust: trust) }
      first.cancel()
      #expect(
        try await promptEventually {
          pendingHost(app, trust: trust) == secondHost.id
        }
      )
      if trust {
        app.resolveTrust(.trust, for: staleID)
      } else {
        app.resolvePassword("first-host-password", for: staleID)
      }
      #expect(pendingHost(app, trust: trust) == secondHost.id)
      resolve(app, trust: trust, allow: true)
      #expect(!(await first.value))
      #expect(await second.value)
    }
  }
}
