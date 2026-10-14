import Foundation
import NIOSSH
@testable import RoamingApp
import SessionCore
import SSHClient
import Testing

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct SSHShellControllerTests {
    enum Rejection: CaseIterable, Sendable { case channel, pty, shell }

    @Test
    func repeatedCloseWaitsForTheSameCleanup() async throws {
      try await withController { server, app, controller in
        try await signIn(controller, app: app)
        #expect(try await eventually { controller.phase == .running })
        server.state.faults.withLock { $0.dropAllServerWrites = true }
        var firstFinished = false
        let first = Task {
          await controller.close(.detach)
          firstFinished = true
        }
        do {
          #expect(
            try await eventually {
              server.state.droppedServerWrites.withLock { $0 > 0 }
            }
          )
          var secondStarted = false
          var secondFinished = false
          let second = Task {
            secondStarted = true
            await controller.close(.detach)
            secondFinished = true
          }
          do {
            #expect(try await eventually { secondStarted })
            #expect(!firstFinished)
            #expect(!secondFinished)
          } catch {
            await second.value
            throw error
          }
          await second.value
          #expect(secondFinished)
        } catch {
          await first.value
          throw error
        }
        await first.value
        #expect(firstFinished)
      }
    }

    @Test
    func directViewRefusalShowsNoticeWithoutEndingShell() async throws {
      try await withController { server, app, controller in
        controller.session.send(.text("early"))
        #expect(
          try await eventually {
            controller.inputNotice?.contains("not ready") == true
          }
        )
        controller.dismissInputNotice()
        #expect(controller.inputNotice == nil)
        try await signIn(controller, app: app)
        #expect(try await eventually { controller.phase == .running })
        controller.session.send(
          .bytes(Array(repeating: 0, count: RSTLimits.maxPasteBytes + 1))
        )
        #expect(
          try await eventually {
            controller.inputNotice?.contains("limits") == true
          }
        )
        #expect(controller.phase == .running)
        #expect(controller.model.connectionState == .active)
        #expect(server.state.connections.withLock { $0.channels.count == 1 })
        controller.dismissInputNotice()
        controller.session.send(.text("ok"))
        #expect(
          try await eventually {
            controller.session.withState {
              $0.screenLines.contains { $0.contains("ok") }
            }
          }
        )
        #expect(controller.inputNotice == nil)
        await controller.close(.detach)
        controller.session.send(.text("late"))
        await withCheckedContinuation { continuation in
          DispatchQueue.main.async { continuation.resume() }
        }
        #expect(controller.inputNotice == nil)
      }
    }

    @Test(arguments: Rejection.allCases)
    func failedSetupClosesItsAuthenticatedConnection(
      rejection: Rejection,
    ) async throws {
      try await withController { server, app, controller in
        server.state.faults.withLock {
          switch rejection {
          case .channel: $0.rejectSessionChannel = true
          case .pty: $0.rejectPTY = true
          case .shell: $0.rejectShell = true
          }
        }
        try await signIn(controller, app: app)
        #expect(
          try await eventually {
            if case .failed = controller.phase { return true }
            return false
          }
        )
        #expect(server.state.authRequests.withLock { $0 > 0 })
        // Check physical server-side parents before closing the screen.
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
        #expect(controller.model.connectionState == .sessionLost)
      }
    }

    @Test(arguments: [false, true])
    func closingDuringSetupReleasesTheParent(shell: Bool) async throws {
      try await withController { server, app, controller in
        server.state.faults.withLock {
          $0.withholdPTYReply = !shell
          $0.withholdShellReply = shell
        }
        try await signIn(controller, app: app)
        #expect(
          try await eventually {
            shell
              ? server.state.shellRequests.withLock { $0 > 0 }
              : server.state.ptyRequest.withLock { $0 != nil }
          }
        )
        await controller.close(.detach)
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
        if case .failed = controller.phase {
          Issue.record(
            "Closing a pending shell must not publish a setup failure"
          )
        }
      }
    }

    @Test
    func successfulSetupKeepsTheConnectionUntilScreenClosure() async throws {
      try await withController { server, app, controller in
        try await signIn(controller, app: app)
        #expect(
          try await eventually {
            controller.phase == .running
              && controller.model.connectionState == .active
          }
        )
        #expect(server.state.connections.withLock { $0.channels.count == 1 })
        #expect(server.state.shellRequests.withLock { $0 == 1 })
        await controller.close(.detach)
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
      }
    }

    @Test(arguments: [false, true])
    func finishedShellReleasesItsParentWithoutClosingTheScreen(
      status: Bool,
    ) async throws {
      try await withController { server, app, controller in
        try await signIn(controller, app: app)
        #expect(
          try await eventually { controller.model.connectionState == .active }
        )
        let child = try #require(
          server.state.sessionChannels.withLock { $0.values.first }
        )
        if status {
          try await child.pipeline
            .triggerUserOutboundEvent(
              SSHChannelRequestEvent.ExitStatus(exitStatus: 42),
            )
            .get()
        }
        do { try await child.close().get() } catch let error as NIOSSHError
          where error.type == .tcpShutdown
        {
          // Parent cleanup can race the server's child-close acknowledgement.
        }
        #expect(
          try await eventually {
            controller.model.connectionState
              == (status ? .sessionExited : .sessionLost)
          }
        )
        #expect(controller.model.exitStatus == (status ? 42 : nil))
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
        if case let .failed(problem) = controller.phase {
          #expect(
            problem.title == (status ? "Shell exited" : "SSH connection lost")
          )
        } else {
          Issue.record("A finished shell must retain its failure explanation")
        }
      }
    }

    @Test
    func exitDuringOpeningReleasesItsParent() async throws {
      try await withController { server, app, controller in
        server.state.shellExitStatus.withLock { $0 = 42 }
        try await signIn(controller, app: app)
        #expect(
          try await eventually {
            controller.model.connectionState == .sessionExited
          }
        )
        #expect(controller.model.exitStatus == 42)
        #expect(
          try await eventually {
            server.state.connections.withLock { $0.channels.isEmpty }
          }
        )
      }
    }

    private func signIn(
      _ controller: SSHShellController,
      app: RoamingAppModel,
    ) async throws {
      controller.start()
      #expect(try await eventually { app.pendingPassword != nil })
      app.resolvePassword(TestSSHServer.password)
    }

    private func withController(
      _ operation: (TestSSHServer, RoamingAppModel, SSHShellController, )
        async throws -> Void,
    ) async throws {
      let server = try await TestSSHServer.start()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("shell-controller-" + UUID().uuidString)
      let suite = "shell-controller-" + UUID().uuidString
      defer {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      }
      var controller: SSHShellController?
      do {
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = RoamingAppModel(
          store: HostProfileStore(
            fileURL: directory.appendingPathComponent("hosts.json")
          ),
          resumeStore: SessionResumeStore(defaults: defaults),
        )
        let host = HostProfile(
          nickname: "Host",
          host: "127.0.0.1",
          port: server.port,
          username: TestSSHServer.username,
        )
        let model = TerminalScreenModel(
          host: host,
          profile: .profile(for: .mobile),
          kind: .ordinarySSH,
        )
        let trust = FileHostTrustStore(
          fileURL: directory.appendingPathComponent("keys.json")
        )
        try await trust.setTrustedKey(server.hostKeyLine, for: server.identity)
        let access = SSHAccess(app: app, trustStore: trust)
        let surface = SSHShellController(model: model, app: app, access: access)
        controller = surface
        try await operation(server, app, surface)
      } catch {
        await controller?.close(.detach)
        await server.shutdown()
        throw error
      }
      await controller?.close(.detach)
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
  }
}
