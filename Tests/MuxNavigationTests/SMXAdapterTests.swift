import Foundation
import MuxNavigation
import MuxNavigationSMX
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Testing
import TestSupport

/// `SMXAttentionService` against an in-process SwiftMux service: lease
/// reads, attach without silent takeover, and generation-fenced takeover.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMXAdapterTests {
  private static func launcherPath() throws -> String {
    try NativeTestProducts.launcherPath()
  }

  @Test
  func fixtureHonorsTheSelectedLauncher() throws {
    let environment = ProcessInfo.processInfo.environment
    let selected =
      try environment["SWIFTTY_EXPECTED_LAUNCHER"] ?? environment[
        "SWMUX_LAUNCHER"
      ] ?? NativeTestProducts.launcherPath(environment: [:])
    #expect(try Self.launcherPath() == selected)
  }

  @Test
  func errorMapping() {
    #expect(SMXAttentionService.map(MuxError(.leaseHeld)) == .leaseHeld)
    #expect(SMXAttentionService.map(MuxError(.staleRevision)) == .leaseChanged)
    #expect(
      SMXAttentionService.map(MuxError(.serverInstanceChanged))
        == .serviceRestarted
    )
    #expect(SMXAttentionService.map(MuxError(.notFound)) == .notFound)
    #expect(SMXAttentionService.map(MuxError(.paneExited)) == .paneExited)
    #expect(SMXAttentionService.map(MuxError(.unauthorized)) == .unauthorized)
    #expect(
      SMXAttentionService.map(MuxError(.connectionLost, "x"))
        == .offline("connectionLost: x")
    )
  }

  @Test
  func openNeverTakesOverSilently() async throws {
    let service = try MuxService(
      configuration: MuxServiceConfiguration(
        launcherPath: try Self.launcherPath()
      )
    )
    let endpoint = service.listenAnonymously()
    let owner = try await MuxConnection.connect(
      endpoint: endpoint,
      frontend: .native
    )
    var ownedAdapter: SMXAttentionService?
    try await RuntimeFixture.withCleanup {
      let launch = LaunchSpec(
        command: ["/bin/sh"],
        workingDirectory: "/tmp",
        environment: ["PATH": "/usr/bin:/bin", "PS1": "$ "]
      )
      guard
        case let .created(ws) = try await owner.execute(
          .newWorkspace(NewWorkspaceRequest(name: "w", launch: launch))
        )
      else { throw MuxError(.invalidRequest, "create") }
      _ = try await owner.execute(.attach(.id(ws.id)))

      let connection = try await MuxConnection.connect(
        endpoint: endpoint,
        frontend: .native
      )
      let adapter = SMXAttentionService(connection: connection)
      ownedAdapter = adapter
      #expect(try await adapter.serviceEpoch() == (await owner.welcome?.server))
      let lease = try await adapter.leaseState(of: ws.id)
      #expect(lease.generation == 1)
      #expect(lease.holder?.frontend == .native)

      let pane = try #require(ws.activeTabSnapshot?.activePane)
      let target = PaneTarget(workspace: ws.id, tab: ws.activeTab, pane: pane)
      await #expect(throws: AttentionServiceError.leaseHeld) {
        try await adapter.open(target, takeover: nil)
      }
      await #expect(throws: AttentionServiceError.leaseChanged) {
        try await adapter.open(target, takeover: lease.generation + 1)
      }
      try await adapter.open(target, takeover: lease.generation)
      #expect(
        try await adapter.leaseState(of: ws.id).generation == lease.generation
          + 1
      )
      await #expect(throws: AttentionServiceError.notFound) {
        try await adapter.leaseState(of: WorkspaceID())
      }
    } cleanup: {
      await ownedAdapter?.close()
      await owner.close()
      await withCheckedContinuation { continuation in
        service.prepareToExit { continuation.resume() }
      }
    }
  }
}
