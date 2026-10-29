import Foundation
@testable import RoamingApp
import Synchronization
import TerminalSurface
import Testing

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct ClientLifecycleQueueTests {
    @MainActor
    private final class Gate {
      private var continuation: CheckedContinuation<Void, Never>?
      var waiting: Bool { continuation != nil }

      func wait() async { await withCheckedContinuation { continuation = $0 } }

      func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
      }
    }

    @Test
    func clearingTheClientSkipsWaitingForegroundCalls() async throws {
      let fixture = try RoamingFixture()
      try #require(try await fixture.startActive())
      let queue = ClientLifecycleQueue()
      queue.use(fixture.client)
      let gate = Gate()
      defer { gate.release() }
      let first = try #require(
        queue.enqueue { client in
          await gate.wait()
          await client.enterBackground()
        }
      )
      try #require(await eventually { gate.waiting })
      let ran = Mutex(false)
      let pending = try #require(
        queue.enqueue { client in
          ran.withLock { $0 = true }
          await client.enterForeground()
          _ = await eventually(.milliseconds(200)) {
            await client.state == .active
          }
        }
      )
      let tail = try #require(
        queue.enqueue { client in await client.pathChanged() }
      )
      queue.use(nil)
      gate.release()
      await first.value
      await pending.value
      await tail.value
      #expect(!ran.withLock { $0 })
      #expect(await fixture.connector.connectCount == 1)
      await fixture.client.close()
    }

    @Test(arguments: [false, true])
    func replacementStartsWithoutWaitingForTheOldQueue(reuse: Bool) async throws
    {
      let old = try RoamingFixture()
      let next = try RoamingFixture()
      try #require(try await old.startActive())
      try #require(try await next.startActive())
      let selected = reuse ? old : next
      let queue = ClientLifecycleQueue()
      queue.use(old.client)
      let gate = Gate()
      defer { gate.release() }
      let first = try #require(queue.enqueue { _ in await gate.wait() })
      try #require(await eventually { gate.waiting })
      let ran = Mutex(false)
      let obsolete = try #require(
        queue.enqueue { client in
          ran.withLock { $0 = true }
          await client.proposeGrid(columns: 40, rows: 4)
        }
      )
      let tail = try #require(
        queue.enqueue { client in await client.proposeGrid(columns: 45, rows: 4)
        }
      )
      queue.use(nil)
      queue.use(selected.client)
      let fresh = try #require(
        queue.enqueue { client in await client.proposeGrid(columns: 25, rows: 4)
        }
      )
      // Observe the actual RST resize before releasing the old operation.
      #expect(
        await eventually(.milliseconds(200)) {
          await selected.host.resizes.count == 1
        }
      )
      gate.release()
      await first.value
      await obsolete.value
      await tail.value
      await fresh.value
      #expect(!ran.withLock { $0 })
      #expect(await eventually { await selected.host.columns == 25 })
      await old.client.close()
      await next.client.close()
    }

    @Test
    func terminateAfterAStartedDetachSkipsQueuedForeground() async throws {
      let fixture = try RoamingFixture()
      try #require(try await fixture.startActive())
      await fixture.host.blackHoleCurrent()
      let queue = ClientLifecycleQueue()
      queue.use(fixture.client)
      queue.enqueue { client in await client.enterBackground() }
      try #require(
        await eventually { await fixture.client.state == .backgroundDetached }
      )
      queue.enqueue { client in await client.enterForeground() }
      let pending = queue.use(nil)
      await pending?.value
      await fixture.client.close(.terminate)
      #expect(await fixture.client.state == .userClosed)
      #expect(await fixture.connector.connectCount == 1)
      #expect(await fixture.host.terminateCount == 1)
      #expect(
        fixture.bootstrapper.requests.withLock {
          $0.filter { $0.operation == .terminate }.count == 1
        }
      )
    }

    @Test
    func currentClientCallsKeepTheirSubmissionOrder() async throws {
      let fixture = try RoamingFixture()
      try #require(try await fixture.startActive())
      let queue = ClientLifecycleQueue()
      queue.use(fixture.client)
      let gate = Gate()
      defer { gate.release() }
      let applied = Mutex<[Int]>([])
      let first = try #require(
        queue.enqueue { client in
          await gate.wait()
          applied.withLock { $0.append(22) }
          await client.proposeGrid(columns: 22, rows: 4)
        }
      )
      try #require(await eventually { gate.waiting })
      let second = try #require(
        queue.enqueue { client in
          applied.withLock { $0.append(24) }
          await client.proposeGrid(columns: 24, rows: 4)
        }
      )
      #expect(applied.withLock { $0.isEmpty })
      gate.release()
      await first.value
      await second.value
      #expect(applied.withLock { $0 } == [22, 24])
      #expect(await eventually { await fixture.host.columns == 24 })
      await fixture.client.close()
    }

    @Test
    func callsRunWhileTheMainQueueIsBlocked() async throws {
      let fixture = try RoamingFixture()
      try #require(try await fixture.startActive())
      let queue = ClientLifecycleQueue()
      queue.use(fixture.client)
      // A quit blocks the main queue while it waits for a close, which
      // first waits for the call already dispatched.
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
          let call = queue.enqueue { client in
            await client.proposeGrid(columns: 30, rows: 4)
          }
          let finished = DispatchSemaphore(value: 0)
          Task.detached {
            await call?.value
            finished.signal()
          }
          #expect(finished.wait(timeout: .now() + 2) == .success)
          continuation.resume()
        }
      }
      #expect(await eventually { await fixture.host.columns == 30 })
      await fixture.client.close()
    }

    private func eventually(
      _ timeout: Duration = .seconds(2),
      _ condition: @MainActor () async -> Bool,
    ) async -> Bool {
      let deadline = ContinuousClock.now + timeout
      while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
      }
      return await condition()
    }
  }
}
