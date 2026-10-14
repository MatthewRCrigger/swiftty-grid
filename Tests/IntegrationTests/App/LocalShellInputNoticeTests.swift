#if os(macOS) && !targetEnvironment(macCatalyst)
import Dispatch
@testable import RoamingApp
import SessionCore
import SwifttyCore
import TerminalSurface
import Testing

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.timeLimit(.minutes(1)))
  struct LocalShellInputNoticeTests {
    @Test
    func directInputRefusalIsDismissibleAndCloseDropsLateNotices() async throws
    {
      let host = HostProfile(
        nickname: "Local",
        host: "localhost",
        username: "me"
      )
      let model = TerminalScreenModel(
        host: host,
        profile: .profile(for: .mac),
        kind: .localShell,
      )
      let controller = LocalShellController(model: model)
      let session = controller.backend.session
      session.send(.text("early"))
      #expect(
        await eventually {
          controller.inputNotice?.contains("not ready") == true
        }
      )
      controller.dismissInputNotice()
      #expect(controller.inputNotice == nil)
      var configuration = SessionConfiguration()
      configuration.command = ["/bin/cat"]
      try controller.backend.start(configuration)
      session.send(
        .bytes(Array(repeating: 0, count: RSTLimits.maxPasteBytes + 1, ))
      )
      #expect(
        await eventually { controller.inputNotice?.contains("limits") == true }
      )
      #expect(controller.backend.lifecycle == .active)
      controller.dismissInputNotice()
      session.send(.text("ok"))
      #expect(
        await eventually {
          session.withState { $0.screenLines.contains { $0.contains("ok") } }
        }
      )
      #expect(controller.inputNotice == nil)
      await controller.close(.detach)
      session.send(.text("late"))
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
      #expect(controller.inputNotice == nil)
      #expect(!session.isRunning)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
      let deadline = ContinuousClock.now + .seconds(2)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        do { try await Task.sleep(for: .milliseconds(5)) } catch {
          return false
        }
      }
      return true
    }
  }
}
#endif
