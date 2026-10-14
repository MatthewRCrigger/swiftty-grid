import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization
import Testing

struct QuiesceOwnershipTests {
  @Test(arguments: [false, true])
  func anotherClientCannotChangeAnOwnedFreeze(_ on: Bool) async throws {
    let (h, owner, other) = try await frozenService()
    defer {
      Task {
        await owner.close();
        await other.close()
        withExtendedLifetime(h) {}
      }
    }
    await #expect { try await other.execute(.quiesce(on)) } throws: {
      ($0 as? MuxError)?.code == .quiescing
    }
    #expect(try await status(other).quiescing)
    await #expect {
      try await other.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    } throws: { ($0 as? MuxError)?.code == .quiescing }
    #expect(try await owner.execute(.quiesce(true)) == .ok)
    #expect(try await owner.execute(.quiesce(false)) == .ok)
    #expect(!((try await status(other)).quiescing))
    #expect(await h.service.isEmpty)
  }

  @Test
  func lostOwnerRestoresAdmissionAndCannotReleaseItsSuccessor() async throws {
    let (h, owner, other) = try await frozenService()
    defer {
      Task {
        await owner.close();
        await other.close()
        withExtendedLifetime(h) {}
      }
    }
    await owner.close()
    #expect(await until { (try? await status(other).quiescing) == false })
    #expect(try await other.execute(.quiesce(true)) == .ok)
    await owner.close()
    #expect(try await status(other).quiescing)
    #expect(try await other.execute(.quiesce(false)) == .ok)
    _ = try await other.execute(
      .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
    )
    #expect(try await status(other).workspaces == 1)
    _ = try await other.execute(.endAllWorkspaces)
    #expect(await until { await h.service.isEmpty })
  }

  @Test
  func ownerLossDoesNotReopenTerminalShutdown() async throws {
    let (h, owner, other) = try await frozenService()
    defer {
      Task {
        await owner.close();
        await other.close()
        withExtendedLifetime(h) {}
      }
    }
    let ready = Mutex(false)
    h.service.prepareToExit { ready.withLock { $0 = true } }
    #expect(await until { ready.withLock { $0 } })
    await owner.close()
    #expect(try await status(other).quiescing)
    await #expect { try await other.execute(.quiesce(false)) } throws: {
      ($0 as? MuxError)?.code == .quiescing
    }
  }

  @Test
  func competingUpdateAndItsRollbackCannotConsumeTheOwnersBarrier() async throws
  {
    let (h, owner, other) = try await frozenService()
    defer {
      Task {
        await owner.close();
        await other.close()
        withExtendedLifetime(h) {}
      }
    }
    let registration = OwnershipRegistration()
    let replacements = Mutex(0)
    let update = UpdateCoordinator(
      connect: { other },
      registration: registration,
      replace: { _ in replacements.withLock { $0 += 1 } },
    )
    await update.stage(URL(fileURLWithPath: "/tmp/Competing.app"))
    guard case .failed = await update.install(endWorkspaces: false) else {
      Issue.record("expected competing update refusal")
      return
    }
    #expect(registration.calls.withLock { $0 } == 0)
    #expect(replacements.withLock { $0 } == 0)
    #expect(try await status(owner).quiescing)
    #expect(try await owner.execute(.quiesce(false)) == .ok)
  }

  @Test
  func endAllWithoutAnUpdateOwnerCanStillResumeAdmission() async throws {
    let h = try Harness()
    let client = try await h.connect(.control)
    defer { Task { await client.close() } }
    _ = try await client.execute(.endAllWorkspaces)
    #expect(try await status(client).quiescing)
    #expect(try await client.execute(.quiesce(false)) == .ok)
    #expect(!((try await status(client)).quiescing))
  }

  private func frozenService() async throws -> (
    Harness, MuxConnection, MuxConnection
  ) {
    let h = try Harness()
    let owner = try await h.connect(.control)
    let other = try await h.connect(.control)
    _ = try await owner.execute(.quiesce(true))
    return (h, owner, other)
  }

  private func status(_ connection: MuxConnection) async throws -> ServiceStatus
  {
    guard case let .status(value) = try await connection.execute(.status) else {
      throw MuxError(.invalidRequest, "unexpected status reply")
    }
    return value
  }

  private func until(_ predicate: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while await !predicate(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(2))
    }
    return await predicate()
  }
}

private final class OwnershipRegistration: AgentRegistration, Sendable {
  let calls = Mutex(0)
  func unregister() async throws { calls.withLock { $0 += 1 } }
  func register() async throws { calls.withLock { $0 += 1 } }
}
