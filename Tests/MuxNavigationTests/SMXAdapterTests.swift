import Foundation
import MuxNavigation
import MuxNavigationSMX
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Testing

/// `SMXAttentionService` against an in-process SwiftMux service: lease
/// reads, attach without silent takeover, and generation-fenced takeover.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SMXAdapterTests {
  private static func launcherPath() throws -> String {
    if let path = ProcessInfo.processInfo.environment["SWMUX_LAUNCHER"] {
      return path
    }
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
      for config in ["debug", "release"] {
        let candidate = dir.appending(path: ".build/\(config)/swmux-launcher").path
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
      }
      dir = dir.deletingLastPathComponent()
    }
    throw MuxError(.notFound, "swmux-launcher not built; run swift build first")
  }

  @Test func errorMapping() {
    #expect(SMXAttentionService.map(MuxError(.leaseHeld)) == .leaseHeld)
    #expect(SMXAttentionService.map(MuxError(.staleRevision)) == .leaseChanged)
    #expect(SMXAttentionService.map(MuxError(.serverInstanceChanged)) == .serviceRestarted)
    #expect(SMXAttentionService.map(MuxError(.notFound)) == .notFound)
    #expect(SMXAttentionService.map(MuxError(.paneExited)) == .paneExited)
    #expect(SMXAttentionService.map(MuxError(.unauthorized)) == .unauthorized)
    #expect(SMXAttentionService.map(MuxError(.connectionLost, "x")) == .offline("connectionLost: x"))
  }

  @Test func openNeverTakesOverSilently() async throws {
    let service = MuxService(
      configuration: MuxServiceConfiguration(launcherPath: try Self.launcherPath())
    )
    let endpoint = service.listenAnonymously()
    let owner = try await MuxConnection.connect(endpoint: endpoint, frontend: .native)
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

    let connection = try await MuxConnection.connect(endpoint: endpoint, frontend: .native)
    let adapter = SMXAttentionService(connection: connection)
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
    #expect(try await adapter.leaseState(of: ws.id).generation == lease.generation + 1)
    await #expect(throws: AttentionServiceError.notFound) {
      try await adapter.leaseState(of: WorkspaceID())
    }
    _ = try? await connection.execute(.endWorkspace(.id(ws.id)))
    await adapter.close()
    await owner.close()
  }
}
