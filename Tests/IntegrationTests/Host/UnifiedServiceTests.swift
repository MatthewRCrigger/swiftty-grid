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
    .input(.init(attachmentEpoch: epoch, sequence: sequence, operation: operation))
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
      #expect(await registry.list().map(\.sessionID).contains(id))
      #expect(await registry.list().first { $0.sessionID == id }?.state == .attached)

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
      while let event = try await withHostTimeout(.seconds(5), { try await local.nextEvent() })
      {
        if case .detached = event {
          told = true
          break
        }
      }
      #expect(told)
      #expect(
        await registry.workspaces().first?.leaseHolder?.transport == .remote
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
        await registry.workspaces().first?.isAttached == false ? true : nil
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
