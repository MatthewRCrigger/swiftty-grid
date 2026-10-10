#if os(macOS)
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
@testable import TerminalHost
import TestSupport
import Testing

/// Lease-free attention metadata over the SSH bootstrap channel and the
/// reveal path (spec.inbox.md §3, §4; acceptance 16, 18).
@Suite(.timeLimit(.minutes(1)))
struct RemoteAttentionTests {
  private static let blocked =
    "sleep 0.3; printf '\\033]7501;state=blocked:kind=question\\007'; exec sleep 30"

  private func waitForItem(
    _ registry: SessionRegistry
  ) async throws -> AttentionItem {
    try await hostEventuallyAsync("inbox item") {
      let metadata = try? await registry.metadata(.inbox(InboxQuery()))
      return metadata?.inbox?.items.first
    }
  }

  @Test
  func `the inbox is read and acknowledged without a lease`() async throws {
    try await withRegistry(launch: { shellLaunch(Self.blocked) }) { registry in
      let grant = try await registry.create(grid: GridSize(columns: 80, rows: 24))
      let item = try await waitForItem(registry)
      #expect(item.category == .needsYou)
      #expect(item.workspace == grant.sessionID.workspace)
      let reference = AttentionReference(source: item.source, occurrence: item.occurrence)

      // Every answer names the service epoch first.
      let located = try await registry.metadata(.locate(reference))
      #expect(located.serviceEpoch == registry.service.instance)
      #expect(located.location?.availability == .available)
      #expect(located.location?.pane == item.source.pane)
      #expect(located.location?.leaseHeldElsewhere == false)

      _ = try await registry.metadata(.markSeen(reference))
      let seen = try await registry.metadata(.inbox(InboxQuery()))
      #expect(seen.inbox?.items.first?.seen == true)
      // Seen is not resolved.
      #expect(seen.inbox?.counts.needsYou == 1)

      _ = try await registry.metadata(
        .snooze(reference, until: .now.addingTimeInterval(600))
      )
      #expect(try await registry.metadata(.inbox(InboxQuery())).inbox?.counts.needsYou == 0)

      // A request cannot be "reviewed" away.
      await #expect(throws: BootstrapErrorCode.malformed) {
        _ = try await registry.metadata(.markReviewed(reference))
      }
      // Reading never took a lease.
      #expect(await registry.workspaces().first?.isAttached == false)
    }
  }

  @Test
  func `bootstrap envelopes carry attention requests end to end`() async throws {
    try await withRegistry(launch: { shellLaunch(Self.blocked) }) { registry in
      _ = try await registry.create(grid: GridSize(columns: 80, rows: 24))
      _ = try await waitForItem(registry)
      let service = BootstrapService(registry: registry)
      let request = try BootstrapEnvelope.encode(
        BootstrapRequest(operation: .attention, attention: .inbox(InboxQuery()))
      )
      let reply = await service.respond(toEnvelope: request)
      let response = try BootstrapEnvelope.decode(BootstrapResponse.self, from: reply)
      guard case let .metadata(metadata) = response else {
        Issue.record("unexpected \(response)")
        return
      }
      #expect(metadata.inbox?.items.count == 1)
      // A request without its attention payload creates nothing.
      let missing = try BootstrapEnvelope.encode(BootstrapRequest(operation: .attention))
      let refused = try BootstrapEnvelope.decode(
        BootstrapResponse.self,
        from: await service.respond(toEnvelope: missing)
      )
      #expect(refused == .failure(.malformed))
    }
  }

  @Test
  func `reveal focuses the linked pane and takes over only the confirmed lease`()
    async throws
  {
    try await withRegistry { registry in
      let endpoint = registry.service.listenAnonymously()
      let local = try await MuxConnection.connect(endpoint: endpoint, frontend: .native)
      guard
        case let .created(ws) = try await local.execute(
          .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
        )
      else { throw HostTestTimeout(what: "workspace") }
      let first = ws.tabs[0].activePane
      guard case let .attached(_, attached) = try await local.execute(.attach(.id(ws.id))),
        case let .layout(split) = try await local.execute(
          .split(pane: first, axis: .leftRight, launch: shellLaunch())
        )
      else { throw HostTestTimeout(what: "split") }
      _ = attached
      // The split focused the new pane; the link names the first one.
      #expect(split.activeTabSnapshot?.activePane != first)
      let id = SessionID(ws.id)
      let seenGeneration = try #require(
        await registry.workspaces().first?.leaseGeneration
      )

      // A stale confirmation (older generation) never displaces the Mac.
      let stale = try await registry.resume(
        id,
        target: ResumeTarget(pane: first, expectedLease: seenGeneration - 1)
      )
      let refused = TestClient(registry)
      try await refused.attach(stale)
      #expect(try await refused.errorCode() == .writerBusy)
      #expect(await local.attachment != nil)

      let grant = try await registry.resume(
        id,
        target: ResumeTarget(pane: first, expectedLease: seenGeneration)
      )
      let remote = TestClient(registry)
      _ = try await remote.attached(grant)
      let session = try #require(registry.session(id))
      try await hostEventually("linked pane focused") {
        session.diagnostics.activePane == first ? true : nil
      }
      #expect(await registry.workspaces().first?.leaseHolder?.transport == .remote)
      await local.close()
    }
  }
}
#endif
