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
    try await withRegistry(
      launch: { shellLaunch(Self.blocked) },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 80, rows: 24)
        )
        let item = try await waitForItem(registry)
        #expect(item.category == .needsYou)
        #expect(item.workspace == grant.sessionID.workspace)
        let reference = AttentionReference(
          source: item.source,
          occurrence: item.occurrence
        )

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
        #expect(
          try await registry.metadata(.inbox(InboxQuery())).inbox?.counts
            .needsYou == 0
        )

        // A request cannot be "reviewed" away.
        await #expect(throws: BootstrapErrorCode.malformed) {
          _ = try await registry.metadata(.markReviewed(reference))
        }
        // Reading never took a lease.
        #expect(try await registry.workspaces().first?.isAttached == false)
      }
    )
  }

  @Test
  func `bootstrap envelopes carry attention requests end to end`() async throws
  {
    try await withRegistry(
      launch: { shellLaunch(Self.blocked) },
      { registry in
        _ = try await registry.create(grid: GridSize(columns: 80, rows: 24))
        _ = try await waitForItem(registry)
        let service = BootstrapService(registry: registry)
        let request = try BootstrapEnvelope.encode(
          BootstrapRequest(
            operation: .attention,
            attention: .inbox(InboxQuery())
          )
        )
        let reply = await service.respond(toEnvelope: request)
        let response = try BootstrapEnvelope.decode(
          BootstrapResponse.self,
          from: reply
        )
        guard case let .metadata(metadata) = response else {
          Issue.record("unexpected \(response)")
          return
        }
        #expect(metadata.inbox?.items.count == 1)
        // A request without its attention payload creates nothing.
        let missing = try BootstrapEnvelope.encode(
          BootstrapRequest(operation: .attention)
        )
        let refused = try BootstrapEnvelope.decode(
          BootstrapResponse.self,
          from: await service.respond(toEnvelope: missing)
        )
        #expect(refused == .failure(.malformed))
      }
    )
  }

  @Test
  func
    `reveal focuses the linked pane and takes over only the confirmed lease`()
    async throws
  {
    try await withRegistry { registry in
      let endpoint = registry.service.listenAnonymously()
      let local = try await MuxConnection.connect(
        endpoint: endpoint,
        frontend: .native
      )
      guard
        case let .created(ws) = try await local.execute(
          .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
        )
      else { throw HostTestTimeout(what: "workspace") }
      let first = ws.tabs[0].activePane
      guard
        case let .attached(_, attached) = try await local.execute(
          .attach(.id(ws.id))
        ),
        case let .layout(split) = try await local.execute(
          .split(pane: first, axis: .leftRight, launch: shellLaunch())
        )
      else { throw HostTestTimeout(what: "split") }
      _ = attached
      // The split focused the new pane; the link names the first one.
      #expect(split.activeTabSnapshot?.activePane != first)
      let id = SessionID(ws.id)
      let seenGeneration = try #require(
        try await registry.workspaces().first?.leaseGeneration
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
      #expect(
        try await registry.workspaces().first?.leaseHolder?.transport == .remote
      )
      await local.close()
    }
  }

  @Test
  func `a confirmed takeover applies to one attachment only`() async throws {
    try await withRegistry { registry in
      let endpoint = registry.service.listenAnonymously()
      let local = try await MuxConnection.connect(
        endpoint: endpoint,
        frontend: .native
      )
      guard
        case let .created(ws) = try await local.execute(
          .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
        )
      else { throw HostTestTimeout(what: "workspace") }
      _ = try await local.execute(.attach(.id(ws.id)))
      let id = SessionID(ws.id)
      let seen = try #require(
        try await registry.workspaces().first?.leaseGeneration
      )
      let grant = try await registry.resume(
        id,
        target: ResumeTarget(pane: ws.tabs[0].activePane, expectedLease: seen)
      )
      let remote = TestClient(registry)
      _ = try await remote.attached(grant)
      // The Mac takes control back explicitly.
      let now = try #require(
        try await registry.workspaces().first?.leaseGeneration
      )
      let mac = try await MuxConnection.connect(
        endpoint: endpoint,
        frontend: .native
      )
      _ = try await mac.execute(.takeover(.id(ws.id), expectedLease: now))
      try await hostEventually("remote fenced") { remote.isClosed ? true : nil }
      // Reconnecting with the same token is an ordinary attach: it never
      // takes over again.
      let again = TestClient(registry)
      try await again.attach(grant)
      #expect(try await again.errorCode() == .writerBusy)
      #expect(await mac.attachment != nil)
      await mac.close()
      await local.close()
    }
  }

  @Test
  func `a resumed workspace continues above the retired session's revisions`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      for _ in 0 ..< 3 {
        let client = TestClient(registry)
        _ = try await client.attached(
          try await registry.resume(grant.sessionID)
        )
        client.connection.sever()
        try await hostEventually("detached") {
          registry.session(grant.sessionID)?.status.isAttached == false
            ? true : nil
        }
      }
      let retired = try #require(registry.session(grant.sessionID)).floor
      #expect(retired.epoch >= 3)
      #expect(
        await registry.sweep(now: .now + .seconds(24 * 3600 + 1)) == [
          grant.sessionID
        ]
      )
      let fresh = try await registry.resume(grant.sessionID)
      let client = TestClient(registry)
      let attached = try await client.attached(fresh)
      // A warm client's store accepts only higher epochs and revisions.
      #expect(attached.attachmentEpoch > retired.epoch)
      let screen = try await client.snapshot("screen") { _ in true }
      #expect(screen.screenRevision > retired.screenRevision)
    }
  }

  @Test
  func `input pending at shell exit is retired and the writer can change`()
    async throws
  {
    try await withRegistry(
      launch: { shellLaunch("sleep 0.5; exit 7") },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 40, rows: 10)
        )
        let client = TestClient(registry)
        _ = try await client.attached(grant)
        // A program that never reads: input stays admitted until exit.
        for n in 1 ... 5 {
          try await client.send(
            .input(
              .init(
                attachmentEpoch: 1,
                sequence: UInt64(n),
                operation: .committedText("x")
              )
            )
          )
        }
        _ = try await client.message("SessionExited") {
          if case .sessionExited = $0 { return true }
          return false
        }
        let session = try #require(registry.session(grant.sessionID))
        try await hostEventually("retired") {
          session.diagnostics.pendingInputOperations == 0 ? true : nil
        }
        // Nothing is left to block a new writer (no writerBusy).
        _ = try await registry.resume(grant.sessionID)
      }
    )
  }

  @Test
  func `an exited pane in a split workspace never ends the live panes`()
    async throws
  {
    try await withRegistry(
      launch: { shellLaunch("sleep 0.3; exit 0") },
      { registry in
        let endpoint = registry.service.listenAnonymously()
        let grant = try await registry.create(
          grid: GridSize(columns: 80, rows: 24)
        )
        let local = try await MuxConnection.connect(
          endpoint: endpoint,
          frontend: .native
        )
        guard
          case let .attached(_, ws) = try await local.execute(
            .attach(.id(grant.sessionID.workspace))
          )
        else { throw HostTestTimeout(what: "attach") }
        let first = ws.tabs[0].activePane
        guard
          case let .layout(split) = try await local.execute(
            .split(pane: first, axis: .leftRight, launch: shellLaunch())
          )
        else { throw HostTestTimeout(what: "split") }
        let live = try #require(split.activeTabSnapshot?.activePane)
        _ = try await local.execute(.focusPane(first))
        await local.close()
        try await Task.sleep(for: .milliseconds(600))
        // The remote view shows the exited pane, but another pane lives.
        let client = TestClient(registry)
        _ = try await client.attached(
          try await registry.resume(grant.sessionID)
        )
        _ = try await client.message("SessionExited") {
          if case .sessionExited = $0 { return true }
          return false
        }
        client.connection.sever()
        let session = try #require(registry.session(grant.sessionID))
        try await hostEventually("detached") {
          session.status.isAttached ? nil : true
        }
        #expect(session.status.allPanesExited == false)
        _ = await registry.sweep(now: .now + .seconds(301))
        #expect(
          try await registry.workspaces().map(\.id) == [
            grant.sessionID.workspace
          ]
        )
        #expect(await registry.service.panePID(live) != nil)
      }
    )
  }

  @Test
  func `a new writer resumes even with input the pane never took`() async throws
  {
    // Raw mode: the tty holds unread input instead of discarding it, so
    // the PTY stops accepting and the pane's input budget fills.
    try await withRegistry(
      launch: { shellLaunch("stty raw -echo; exec sleep 30") },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 80, rows: 24)
        )
        let client = TestClient(registry)
        _ = try await client.attached(grant)
        // A program that never reads: the pane's input budget fills and the
        // last admitted paste waits, unsent.
        let chunk = String(repeating: "y", count: 30_000)
        let session = try #require(registry.session(grant.sessionID))
        // One paste at a time (the ledger admits one 30 KB paste), until
        // the pane refuses one for lack of room.
        var sequence: UInt64 = 0
        while session.diagnostics.pendingInputOperations == 0, sequence < 20 {
          sequence += 1
          try await client.send(
            .input(
              .init(
                attachmentEpoch: 1,
                sequence: sequence,
                operation: .paste(chunk)
              )
            )
          )
          let n = sequence
          try await hostEventually("ack or wait") {
            client.inputAck(n) || session.diagnostics.pendingInputOperations > 0
              ? true : nil
          }
        }
        #expect(session.diagnostics.pendingInputOperations > 0)
        client.connection.sever()
        try await hostEventually("detached") {
          session.status.isAttached ? nil : true
        }
        // A cold-started client (new writer) is not refused with writerBusy.
        let fresh = try await registry.resume(grant.sessionID)
        #expect(fresh.writerID != grant.writerID)
        #expect(session.diagnostics.pendingInputOperations == 0)
      }
    )
  }

  @Test
  func `a shell that exits while detached is noticed by the sweep`()
    async throws
  {
    try await withRegistry(
      launch: { shellLaunch("sleep 1; exit 0") },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 40, rows: 10)
        )
        let client = TestClient(registry)
        _ = try await client.attached(grant)
        client.connection.sever()
        let session = try #require(registry.session(grant.sessionID))
        try await hostEventually("detached") {
          session.status.isAttached ? nil : true
        }
        try await hostEventuallyAsync("pane exited", timeout: .seconds(10)) {
          try await registry.workspaces().first?.livePaneCount == 0 ? true : nil
        }
        #expect(session.status.state == .detached)
        #expect(
          await registry.sweep(now: .now + .seconds(301)) == [grant.sessionID]
        )
        try await hostEventuallyAsync("workspace ended") {
          try await registry.workspaces().isEmpty ? true : nil
        }
      }
    )
  }

  @Test
  func `concurrent attaches leave exactly one lease and no orphan`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let first = TestClient(registry)
      _ = try await first.attached(grant)
      for n in 1 ... 20 {
        try await first.send(
          .input(
            .init(
              attachmentEpoch: 1,
              sequence: UInt64(n),
              operation: .committedText("x")
            )
          )
        )
      }
      // Two more attaches race the in-flight input.
      let second = TestClient(registry)
      let third = TestClient(registry)
      try await second.attach(grant)
      try await third.attach(grant)
      try await hostEventually("settled") {
        let decided = [second, third]
          .filter { client in
            client.isClosed
              || client.messages.contains {
                if case .attached = $0 { return true }
                return false
              }
          }
        return decided.count == 2 ? true : nil
      }
      for client in [first, second, third] { client.connection.sever() }
      let session = try #require(registry.session(grant.sessionID))
      try await hostEventually("detached") {
        session.status.isAttached ? nil : true
      }
      // No in-process client kept the workspace lease.
      try await hostEventuallyAsync("lease released") {
        try await registry.workspaces().first?.isAttached == false ? true : nil
      }
    }
  }

  @Test
  func `reattaching mid-input never delivers an operation twice`() async throws
  {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("lines")
    try await withRegistry(
      launch: {
        shellLaunch("stty -echo; exec cat > \"$HOME/lines\"", in: directory)
      },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 80, rows: 24)
        )
        let total: UInt64 = 120
        var client = TestClient(registry)
        var epoch = try await client.attached(grant).attachmentEpoch
        var next: UInt64 = 1
        while next <= total {
          // Send a burst without waiting, then drop the connection while
          // answers are in flight and resend from the host's watermark.
          for n in next ... min(total, next + 7) {
            try? await client.send(
              .input(
                .init(
                  attachmentEpoch: epoch,
                  sequence: n,
                  operation: .committedText("L\(n)\n")
                )
              )
            )
          }
          client.connection.sever()
          client = TestClient(registry)
          let attached = try await client.attached(grant)
          epoch = attached.attachmentEpoch
          next = attached.lastFullyAppliedInputSequence + 1
        }
        try await hostEventually("all lines", timeout: .seconds(20)) {
          let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
          return text.split(separator: "\n").count >= Int(total) ? true : nil
        }
        try await Task.sleep(for: .milliseconds(300))
        let lines = try String(contentsOf: output, encoding: .utf8)
          .split(separator: "\n").map(String.init)
        #expect(lines == (1 ... total).map { "L\($0)" })
      }
    )
  }
}
#endif
