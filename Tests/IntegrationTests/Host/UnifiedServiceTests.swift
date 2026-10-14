#if os(macOS)
import Foundation
import Synchronization
import ScreenProtocol
import SessionCore
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
@testable import TerminalHost
import TestSupport
import Testing

/// One service, two transports (spec.inbox.md §1, §12 risk 7): the native
/// XPC frontend and RST/1 roaming clients reach the same panes under one
/// single-writer rule.
@Suite(.timeLimit(.minutes(1)))
struct UnifiedServiceTests {
  private func input(
    _ epoch: UInt64,
    _ sequence: UInt64,
    _ operation: InputOperation
  ) -> ControlMessage {
    .input(
      .init(attachmentEpoch: epoch, sequence: sequence, operation: operation)
    )
  }

  @Test(arguments: [false, true], [false, true])
  func serviceRefusesInvalidLeaseCommandsBeforeChangingOwnership(
    _ takeover: Bool,
    _ revoke: Bool
  ) async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let local = try await MuxConnection.connect(
        endpoint: registry.service.listenAnonymously(),
        frontend: .native
      )
      let queue = DispatchQueue(label: "test.expiring.local-session")
      let remote = MuxLocalSession(queue: queue)
      queue.sync {
        remote.connect(to: registry.service, frontend: .native, remote: true)
      }
      defer { queue.sync { remote.close() } }
      do {
        if takeover {
          _ = try await local.execute(.attach(.id(grant.sessionID.workspace)))
        }
        guard case .success = await remote.request(.status) else {
          throw HostTestTimeout(what: "in-process remote client ready")
        }
        let generation = try #require(
          try await registry.workspaces().first?.leaseGeneration
        )
        let command: MuxCommand =
          takeover
          ? .takeover(.id(grant.sessionID.workspace), expectedLease: generation)
          : .attach(.id(grant.sessionID.workspace))
        let release = DispatchSemaphore(value: 0)
        let blocked = Mutex(false)
        registry.service.queue.async {
          blocked.withLock { $0 = true }
          if release.wait(timeout: .now() + 10) == .timedOut {
            Issue.record("service lease command deadline gate timed out")
          }
        }
        defer { release.signal() }
        try await hostEventually("service lease command deadline gate") {
          blocked.withLock { $0 } ? true : nil
        }
        let allowed = Mutex(true)
        let requesting = Task {
          await remote.request(
            command,
            expiresAt: revoke ? nil : .now + .milliseconds(80),
            isAdmitted: { allowed.withLock { $0 } }
          )
        }
        defer { requesting.cancel() }
        do {
          try await hostEventually("lease command waiting on service") {
            queue.sync { remote.pendingRequestCount == 1 ? true : nil }
          }
          if revoke {
            allowed.withLock { $0 = false }
          } else {
            try await Task.sleep(for: .milliseconds(120))
          }
          release.signal()
          let result = await requesting.value
          if case .failure(let error) = result {
            #expect(error.code == .unauthorized)
          } else {
            Issue.record("invalid lease command changed service ownership")
          }
          let after = try #require(try await registry.workspaces().first)
          #expect(after.leaseGeneration == generation)
          if takeover {
            #expect(after.leaseHolder?.transport == .local)
          } else {
            #expect(after.leaseHolder == nil)
          }
          // A later request with valid admission can still acquire.
          let recovery = await remote.request(command)
          if case .success(.attached) = recovery {
          } else {
            Issue.record(
              "valid lease command rejected after admission refusal: \(recovery)"
            )
          }
        } catch {
          release.signal()
          _ = await requesting.value
          throw error
        }
      } catch {
        await local.close()
        throw error
      }
      await local.close()
    }
  }

  @Test(arguments: [false, true], [false, true])
  func reservedGrantExpiryKeepsALocallyUsedWorkspace(
    _ keepAttached: Bool,
    _ useSwitch: Bool
  ) async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let local = try await MuxConnection.connect(
        endpoint: registry.service.listenAnonymously(),
        frontend: .native
      )
      do {
        let starting: WorkspaceID
        if useSwitch {
          guard
            case .created(let origin) = try await local.execute(
              .newWorkspace(
                NewWorkspaceRequest(name: "origin", launch: shellLaunch())
              )
            )
          else { throw HostTestTimeout(what: "local origin workspace") }
          starting = origin.id
        } else {
          starting = grant.sessionID.workspace
        }
        guard
          case .attached(_, let initialWorkspace) = try await local.execute(
            .attach(.id(starting))
          )
        else { throw HostTestTimeout(what: "local reservation attachment") }
        var workspace = initialWorkspace
        if useSwitch {
          guard
            case .layout(let switched) = try await local.execute(
              .switchWorkspace(.id(grant.sessionID.workspace))
            )
          else { throw HostTestTimeout(what: "local reservation switch") }
          workspace = switched
        }
        guard let pane = workspace.activeTabSnapshot?.activePane else {
          throw HostTestTimeout(what: "local reservation pane")
        }
        let pid = try #require(await registry.service.panePID(pane))
        if !keepAttached { _ = try await local.execute(.detach) }
        #expect(registry.session(grant.sessionID)?.status.everAttached == false)
        #expect(
          await registry.sweep(now: .now + .seconds(61)) == [grant.sessionID]
        )
        #expect(registry.session(grant.sessionID) == nil)
        #expect(
          try await registry.workspaces()
            .contains { $0.id == grant.sessionID.workspace }
        )
        #expect(isAlive(pid))
        let resumed = try await registry.resume(grant.sessionID)
        #expect(resumed.sessionID == grant.sessionID)
      } catch {
        await local.close()
        throw error
      }
      await local.close()
    }
  }

  @Test(arguments: [false, true])
  func conditionalRetentionEndChecksAllCurrentPanes(
    _ addLivePane: Bool
  ) async throws {
    try await withRegistry(
      launch: { shellLaunch("exit 3") },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 80, rows: 24)
        )
        try await hostEventuallyAsync(
          "exited workspace ready for conditional retention"
        ) {
          try await registry.workspaces().first?.livePaneCount == 0 ? true : nil
        }
        let local = try await MuxConnection.connect(
          endpoint: registry.service.listenAnonymously(),
          frontend: .native
        )
        do {
          if addLivePane {
            _ = try await local.execute(.attach(.id(grant.sessionID.workspace)))
            _ = try await local.execute(
              .newTab(name: "live", launch: shellLaunch())
            )
            #expect(try await registry.workspaces().first?.livePaneCount == 1)
          }
          let ended = await withCheckedContinuation { continuation in
            registry.service.endExitedWorkspace(grant.sessionID.workspace) {
              continuation.resume(returning: $0)
            }
          }
          #expect(ended == !addLivePane)
          let remaining = try await registry.workspaces()
          if addLivePane {
            #expect(remaining.first?.id == grant.sessionID.workspace)
            #expect(remaining.first?.livePaneCount == 1)
          } else {
            #expect(remaining.isEmpty)
          }
        } catch {
          await local.close()
          throw error
        }
        await local.close()
      }
    )
  }

  @Test
  func staleExitStatusDoesNotEndANewLiveNativePane() async throws {
    try await withRegistry(
      launch: { shellLaunch("exit 3") },
      { registry in
        let grant = try await registry.create(
          grid: GridSize(columns: 80, rows: 24)
        )
        let remote = TestClient(registry)
        defer { remote.connection.close() }
        _ = try await remote.attached(grant)
        let session = try #require(registry.session(grant.sessionID))
        try await hostEventually("all original panes exited") {
          session.status.allPanesExited ? true : nil
        }
        remote.connection.close()
        try await hostEventually("exited remote attachment released") {
          !session.status.isAttached ? true : nil
        }
        let local = try await MuxConnection.connect(
          endpoint: registry.service.listenAnonymously(),
          frontend: .native
        )
        do {
          _ = try await local.execute(.attach(.id(grant.sessionID.workspace)))
          guard
            case .layout(let workspace) = try await local.execute(
              .newTab(name: "live", launch: shellLaunch())
            ), let pane = workspace.activeTabSnapshot?.activePane
          else { throw HostTestTimeout(what: "new live native pane") }
          let pid = try #require(await registry.service.panePID(pane))
          #expect(session.status.allPanesExited)
          #expect(try await registry.workspaces().first?.livePaneCount == 1)
          #expect(
            await registry.sweep(now: .now + .seconds(301)) == [grant.sessionID]
          )
          #expect(
            try await registry.workspaces().first?.id
              == grant.sessionID.workspace
          )
          #expect(try await registry.workspaces().first?.livePaneCount == 1)
          #expect(isAlive(pid))
        } catch {
          await local.close()
          throw error
        }
        await local.close()
      }
    )
  }

  @Test(arguments: [false, true])
  func resumeRejectsUnobservedWorkspaceEnd(_ wasAttached: Bool) async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let session = try #require(registry.session(grant.sessionID))
      if wasAttached {
        let remote = TestClient(registry)
        defer { remote.connection.close() }
        _ = try await remote.attached(grant)
        remote.connection.close()
        try await hostEventually("remote detached before external end") {
          session.status.state == .detached ? true : nil
        }
        try await hostEventuallyAsync(
          "remote lease released before external end"
        ) {
          try await registry.workspaces().first?.leaseHolder == nil ? true : nil
        }
      }
      let local = try await MuxConnection.connect(
        endpoint: registry.service.listenAnonymously(),
        frontend: .control
      )
      do {
        _ = try await local.execute(
          .endWorkspace(.id(grant.sessionID.workspace))
        )
        #expect(session.status.state != .terminated)
        let floor = session.floor
        for keepWriter in [false, true] {
          await #expect(throws: BootstrapErrorCode.unknownSession) {
            try await registry.resume(
              grant.sessionID,
              writerID: keepWriter ? grant.writerID : nil
            )
          }
        }
        #expect(registry.session(grant.sessionID) == nil)
        #expect(session.status.state == .terminated)
        #expect(session.floor == floor)
      } catch {
        await local.close()
        throw error
      }
      await local.close()
    }
  }

  @Test(arguments: [false, true])
  func externallyEndedWorkspaceRevokesRemoteAuthorization(
    _ keepWriter: Bool
  ) async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(
        grid: GridSize(columns: 80, rows: 24)
      )
      let remote = TestClient(registry)
      defer { remote.connection.close() }
      let attached = try await remote.attached(grant)
      let session = try #require(registry.session(grant.sessionID))
      let local = try await MuxConnection.connect(
        endpoint: registry.service.listenAnonymously(),
        frontend: .control
      )
      do {
        _ = try await local.execute(
          .endWorkspace(.id(grant.sessionID.workspace))
        )
        _ = try await remote.message("external workspace termination") {
          if case .terminated(let epoch) = $0 {
            return epoch == attached.attachmentEpoch
          }
          return false
        }
        try await hostEventually("remote session terminated") {
          session.status.state == .terminated ? true : nil
        }
        #expect(!session.status.isAttached)
        await #expect(throws: BootstrapErrorCode.unknownSession) {
          try await registry.resume(
            grant.sessionID,
            writerID: keepWriter ? grant.writerID : nil
          )
        }
        let floor = session.floor
        #expect(throws: HostInputLedger.Rejection.wrongWriter) {
          try session.authorize(writer: grant.writerID)
        }
        let late = TestClient(registry)
        defer { late.connection.close() }
        try await late.attach(grant)
        #expect(try await late.errorCode() == .unknownSession)
        #expect(session.floor == floor)
        #expect(try await registry.workspaces().isEmpty)
      } catch {
        await local.close()
        throw error
      }
      await local.close()
    }
  }

  @Test
  func `a native workspace is resumable remotely with explicit takeover only`()
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
          .newWorkspace(NewWorkspaceRequest(name: "mac", launch: shellLaunch()))
        )
      else { throw HostTestTimeout(what: "workspace") }
      let pane = ws.tabs[0].activePane
      _ = try await local.execute(.attach(.id(ws.id)))
      try await local.send(.text("export MARK=from-mac\r"), to: pane)
      let pid = try #require(await registry.service.panePID(pane))

      // The workspace is listed for remote clients under its own identity.
      let id = SessionID(ws.id)
      #expect(try await registry.list().map(\.sessionID).contains(id))
      #expect(
        try await registry.list().first { $0.sessionID == id }?.state
          == .attached
      )

      // Without takeover the remote client is refused; nothing changes.
      let polite = try await registry.resume(id)
      let refused = TestClient(registry)
      try await refused.attach(polite)
      #expect(try await refused.errorCode() == .writerBusy)
      #expect(await local.attachment != nil)

      // With explicit takeover the Mac is fenced and told.
      let grant = try await registry.resume(id, takeover: true)
      let remote = TestClient(registry)
      _ = try await remote.attached(grant)
      var told = false
      while let event = try await withHostTimeout(
        .seconds(5),
        { try await local.nextEvent() }
      ) {
        if case .detached = event {
          told = true
          break
        }
      }
      #expect(told)
      #expect(
        try await registry.workspaces().first?.leaseHolder?.transport == .remote
      )

      // Same shell, same environment: no duplicate PTY.
      try await remote.send(input(1, 1, .committedText("echo $MARK-$$")))
      try await remote.send(input(1, 2, .key(SemanticKey(.enter))))
      _ = try await remote.snapshot("same shell") {
        $0.textLines.contains("from-mac-\(pid)")
      }

      // Detaching remotely frees the lease for the Mac again.
      try await remote.send(.detach(epoch: 1))
      try await hostEventuallyAsync("lease released") {
        try await registry.workspaces().first?.isAttached == false ? true : nil
      }
      _ = try await local.execute(.attach(.id(ws.id)))
      await local.close()
    }
  }
}

func withHostTimeout<T: Sendable>(
  _ duration: Duration,
  _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw HostTestTimeout(what: "event")
    }
    let value = try await group.next()!
    group.cancelAll()
    return value
  }
}
#endif
