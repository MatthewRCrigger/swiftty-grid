import Foundation
@testable import RoamingApp
import Synchronization
import TerminalSurface
import Testing

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct TerminationDetachTests {
    private final class Controller: TerminalSurfaceController {
      let client: RoamingClient
      let finished = Mutex(false)
      var preparations = 0
      /// Holds the close open, so a quit that does not wait for it ends
      /// before it does.
      var delay = Duration.zero
      private var closing: Task<Void, Never>?

      init(client: RoamingClient) { self.client = client }

      func beginClose(_ mode: RoamingCloseMode) -> Task<Void, Never> {
        if let closing { return closing }
        preparations += 1
        let closing = Task.detached { [client, delay, self] in
          try? await Task.sleep(for: delay)
          await client.close(mode)
          finished.withLock { $0 = true }
        }
        self.closing = closing
        return closing
      }
    }

    @Test
    func quittingOnTheMainDispatchQueueCompletesDetachBeforeReturning()
      async throws
    {
      try await withApp { fixture, app, session, controller in
        controller.delay = .milliseconds(300)
        // Match UIKit's termination callback: a synchronous main dispatch
        // block prevents main-actor tasks from running until it returns.
        await withCheckedContinuation { continuation in
          DispatchQueue.main.async {
            let start = ContinuousClock.now
            app.detachBeforeExit()
            #expect(start.duration(to: .now) < .seconds(1))
            #expect(controller.finished.withLock { $0 })
            #expect(controller.preparations == 1)
            #expect(session.controller == nil)
            #expect(app.activeSession == nil)
            app.detachBeforeExit()
            #expect(controller.preparations == 1)
            continuation.resume()
          }
        }
        #expect(await fixture.client.state == .userClosed)
        #expect(await fixture.host.detachCount == 1)
        #expect(await fixture.host.terminateCount == 0)
      }
    }

    @Test
    func quittingWaitsForACloseAlreadyInFlight() async throws {
      try await withApp { fixture, app, _, controller in
        controller.delay = .milliseconds(300)
        await withCheckedContinuation { continuation in
          DispatchQueue.main.async {
            app.close(.terminate)
            #expect(app.activeSession == nil)
            app.detachBeforeExit()
            #expect(controller.finished.withLock { $0 })
            #expect(controller.preparations == 1)
            continuation.resume()
          }
        }
        #expect(await fixture.host.terminateCount == 1)
        #expect(await fixture.host.detachCount == 0)
      }
    }

    @Test
    func aClosedScreenGetsNoNewController() async throws {
      try await withApp { _, app, session, controller in
        app.close()
        #expect(LiveTerminalSurface.controller(for: session, app: app) == nil)
        #expect(session.controller == nil)
        await controller.close(.detach)
      }
    }

    private func withApp(
      _ body: (RoamingFixture, RoamingAppModel, TerminalScreenModel, Controller)
        async throws -> Void
    ) async throws {
      let fixture = try RoamingFixture()
      try #require(try await fixture.startActive())
      let suite = "termination-detach-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let app = RoamingAppModel(
        profile: .profile(for: .catalyst),
        resumeStore: SessionResumeStore(defaults: defaults)
      )
      app.open(
        HostProfile(nickname: "Host", host: "host.invalid", username: "test")
      )
      let session = try #require(app.activeSession)
      let controller = Controller(client: fixture.client)
      session.controller = controller
      do { try await body(fixture, app, session, controller) } catch {
        await fixture.client.close()
        throw error
      }
      await fixture.client.close()
    }
  }
}
