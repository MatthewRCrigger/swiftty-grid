#if os(macOS)
import Dispatch
import ScreenProtocol
import SessionCore
import SwiftMuxService
@testable import TerminalHost
import TestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct WorkspaceListFailureTests {
  private func withControl(
    _ body: (SessionRegistry, MuxLocalSession) async throws -> Void
  ) async throws {
    let service = try makeService()
    let control = MuxLocalSession(
      queue: DispatchQueue(label: "test.workspace-list.control")
    )
    let registry = SessionRegistry(
      service: service,
      identity: testIdentity(),
      launch: { shellLaunch() },
      control: control
    )
    try await RuntimeFixture.withCleanup(
      { try await body(registry, control) },
      cleanup: {
        await close(control)
        await withCheckedContinuation { continuation in
          service.prepareToExit { continuation.resume() }
        }
      }
    )
  }

  private func close(_ control: MuxLocalSession) async {
    await withCheckedContinuation { continuation in
      control.queue.async { control.close { continuation.resume() } }
    }
  }

  @Test(arguments: [false, true])
  func unavailableControlFailsWorkspaceLists(_ populated: Bool) async throws {
    try await withControl { registry, control in
      let grant =
        populated
        ? try await registry.create(grid: GridSize(columns: 80, rows: 24)) : nil
      await close(control)
      await #expect(throws: BootstrapErrorCode.internalError) {
        _ = try await registry.workspaces()
      }
      await #expect(throws: BootstrapErrorCode.internalError) {
        _ = try await registry.list()
      }
      await #expect(throws: BootstrapErrorCode.internalError) {
        _ = try await registry.metadata(.workspaces)
      }
      #expect(registry.pendingControlRequestCount == 0)
      // An unavailable list supplies no evidence of workspace deletion.
      #expect(await registry.sweep().isEmpty)
      if let grant { #expect(registry.session(grant.sessionID) != nil) }
      let healthy = SessionRegistry(
        service: registry.service,
        identity: testIdentity()
      )
      #expect(try await healthy.workspaces().count == (populated ? 1 : 0))
    }
  }

  @Test(arguments: [false, true])
  func bootstrapEnvelopePreservesWorkspaceListFailure(
    _ metadata: Bool
  ) async throws {
    try await withControl { registry, control in
      await close(control)
      let request =
        metadata
        ? BootstrapRequest(operation: .attention, attention: .workspaces)
        : BootstrapRequest(operation: .list)
      let reply = await BootstrapService(registry: registry)
        .respond(toEnvelope: try BootstrapEnvelope.encode(request))
      #expect(reply.count <= RSTLimits.maxBootstrapEnvelopeBytes + 4)
      #expect(
        try BootstrapEnvelope.decode(BootstrapResponse.self, from: reply)
          == .failure(.internalError)
      )
    }
  }

  @Test(arguments: [false, true])
  func workspaceListsPreserveEmptyAndPopulatedSuccess(
    _ populated: Bool
  ) async throws {
    try await withControl { registry, _ in
      let grant =
        populated
        ? try await registry.create(grid: GridSize(columns: 80, rows: 24)) : nil
      let workspaces = try await registry.workspaces()
      let sessions = try await registry.list()
      let metadata = try await registry.metadata(.workspaces)
      #expect(workspaces.count == (populated ? 1 : 0))
      let expectedIDs = grant.map { [$0.sessionID] } ?? []
      #expect(sessions.map(\.sessionID) == expectedIDs)
      #expect(metadata.serviceEpoch == registry.service.instance)
      #expect(metadata.workspaces == workspaces)
      #expect(
        await registry.handle(BootstrapRequest(operation: .list))
          == .sessions(sessions)
      )
      #expect(
        await registry.handle(
          BootstrapRequest(operation: .attention, attention: .workspaces)
        ) == .metadata(metadata)
      )
    }
  }
}
#endif
