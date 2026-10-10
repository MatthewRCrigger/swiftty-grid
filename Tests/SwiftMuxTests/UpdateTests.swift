import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization
import Testing

/// A fake launchd: unregistering stops accepting the old service, and
/// registering starts a new instance.
final class FakeLaunchd: AgentRegistration, @unchecked Sendable {
  let state: Mutex<(harness: Harness?, log: [String])>

  init(_ harness: Harness) { state = Mutex((harness, [])) }

  func unregister() async throws {
    state.withLock {
      $0.harness = nil
      $0.log.append("unregister")
    }
  }

  func register() async throws {
    let fresh = try Harness()
    state.withLock {
      $0.harness = fresh
      $0.log.append("register")
    }
  }

  func connect() async throws -> MuxConnection {
    guard let h = state.withLock({ $0.harness }) else {
      throw MuxError(.connectionLost, "not registered")
    }
    return try await h.connect(.control)
  }

  var log: [String] { state.withLock { $0.log } }
}

final class Replaced: Sendable {
  let urls = Mutex<[URL]>([])
  var value: [URL] { urls.withLock { $0 } }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct UpdateTests {
  func coordinator(
    _ launchd: FakeLaunchd,
    replaced: Replaced
  ) -> UpdateCoordinator {
    UpdateCoordinator(
      connect: { try await launchd.connect() },
      registration: launchd,
      replace: { url in replaced.urls.withLock { $0.append(url) } }
    )
  }

  @Test
  func stagingKeepsAdmissionAndSessions() async throws {
    let h = try Harness()
    let launchd = FakeLaunchd(h)
    let update = coordinator(launchd, replaced: Replaced())
    await update.stage(URL(fileURLWithPath: "/tmp/New.app"))
    let c = try await h.connect()
    try await c.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    #expect(launchd.log.isEmpty)
  }

  @Test
  func cancelBeforeUnregistrationRestoresAdmission() async throws {
    let h = try Harness()
    let launchd = FakeLaunchd(h)
    let replaced = Replaced()
    let update = coordinator(launchd, replaced: replaced)
    let c = try await h.connect()
    try await c.execute(
      .newWorkspace(NewWorkspaceRequest(name: "keep", launch: shellLaunch()))
    )
    await update.stage(URL(fileURLWithPath: "/tmp/New.app"))
    let install = Task { await update.install(endWorkspaces: false) }
    // While waiting at the barrier, new work and attachments are refused.
    try await Task.sleep(for: .milliseconds(150))
    await #expect(throws: MuxError.self) {
      try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    }
    let terminal = try await h.connect()
    await #expect(throws: MuxError.self) {
      try await terminal.execute(.attach(.name("keep")))
    }
    #expect(await update.phase == .awaitingBarrier)
    await update.cancel()
    #expect(await install.value == .cancelled)
    #expect(launchd.log.isEmpty)
    #expect(replaced.value.isEmpty)
    // Normal admission is back; the session survived.
    try await c.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    guard case let .workspaces(list) = try await c.execute(.listWorkspaces)
    else { return }
    #expect(list.contains { $0.name == "keep" })
  }

  @Test
  func barrierTimeoutPreservesSessions() async throws {
    let h = try Harness()
    let launchd = FakeLaunchd(h)
    let update = coordinator(launchd, replaced: Replaced())
    await update.setBarrierTimeout(.milliseconds(300))
    let c = try await h.connect()
    try await c.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    await update.stage(URL(fileURLWithPath: "/tmp/New.app"))
    guard case .failed = await update.install(endWorkspaces: false) else {
      Issue.record("expected failure")
      return
    }
    #expect(launchd.log.isEmpty)
    guard case let .status(s) = try await c.execute(.status) else { return }
    #expect(s.workspaces == 1)
    #expect(!s.quiescing)
  }

  @Test
  func endWorkspacesAndUpdateFollowsTheOrderedBarrier() async throws {
    let h = try Harness()
    let launchd = FakeLaunchd(h)
    let replaced = Replaced()
    let update = coordinator(launchd, replaced: replaced)
    let c = try await h.connect()
    try await c.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    let old = await c.welcome!.server
    let bundle = URL(fileURLWithPath: "/tmp/New.app")
    await update.stage(bundle)
    let phase = await update.install(endWorkspaces: true)
    guard case let .finished(newServer) = phase else {
      Issue.record("install: \(phase)")
      return
    }
    #expect(newServer != old)
    #expect(launchd.log == ["unregister", "register"])
    #expect(replaced.value == [bundle])
    guard case let .status(s) = try await c.execute(.status) else { return }
    #expect(s.workspaces == 0 && s.panes == 0)
  }
}

extension UpdateCoordinator {
  func setBarrierTimeout(_ d: Duration) { barrierTimeout = d }
}
