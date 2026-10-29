import Foundation
import MuxNavigation
import ScreenProtocol
import SwiftMuxProtocol
import Testing

@testable import RoamingApp

private actor AttentionReplyGate {
  var continuation: CheckedContinuation<Void, Never>?
  var isHolding: Bool { continuation != nil }
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func release() {
    continuation?.resume();
    continuation = nil
  }
}

extension MainActorIntegrationTests {
  @MainActor
  struct RoamingAttentionServiceTests {
    @Test(arguments: [false, true])
    func delayedLeaseMetadataCannotOpenAfterCancellationOrHostEdit(
      edited: Bool
    ) async throws {
      let server = try await TestSSHServer.start()
      defer { Task { await server.shutdown() } }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let domain = UUID().uuidString
      let defaults = try #require(UserDefaults(suiteName: domain))
      defer { defaults.removePersistentDomain(forName: domain) }
      let model = RoamingAppModel(
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        ),
        resumeStore: SessionResumeStore(defaults: defaults)
      )
      let host = HostProfile(
        nickname: "Test",
        host: "127.0.0.1",
        port: server.port,
        username: TestSSHServer.username
      )
      #expect(try model.save(host))
      let target = PaneTarget(
        workspace: WorkspaceID(),
        tab: nil,
        pane: PaneID()
      )
      let metadata = HostMetadata(
        serviceEpoch: SwiftMuxProtocol.ServerInstanceID(),
        workspaces: [
          WorkspaceSummary(
            id: target.workspace,
            name: "Test",
            tabCount: 1,
            paneCount: 1,
            createdAt: .now,
            isAttached: false
          )
        ]
      )
      let reply = try BootstrapEnvelope.encode(
        BootstrapResponse.metadata(metadata)
      )
      let gate = AttentionReplyGate()
      server.state.bootstrapForwarder.withLock {
        $0 = { _ in
          await gate.wait();
          return reply
        }
      }
      let connection = try await server.connect()
      let service = RoamingAttentionService(
        model: model,
        host: host,
        connection: connection,
        helperPath: TestSSHServer.forwardHelperPath
      )
      defer { Task { await service.close() } }
      let opening = Task { try await service.open(target, takeover: nil) }
      let deadline = ContinuousClock.now + .seconds(2)
      while !(await gate.isHolding), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(await gate.isHolding)
      if edited {
        var changed = host
        changed.host = "another.local"
        #expect(try model.save(changed))
      } else {
        opening.cancel()
      }
      await gate.release()
      await #expect(throws: AttentionServiceError.self) {
        try await opening.value
      }
      #expect(model.activeSession == nil)
      #expect(model.resumableSessionID(for: host) == nil)
    }
  }
}
