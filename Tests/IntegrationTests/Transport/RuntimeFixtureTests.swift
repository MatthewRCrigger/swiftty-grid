import Foundation
import Testing
import TestSupport

@Suite(.serialized)
@MainActor
struct RuntimeFixtureTests {
  private enum Failure: Error { case intentional }

  @Test(arguments: [false, true])
  func unsettledScreensThrowInsteadOfReturningSuccess(_ changing: Bool) async {
    var reads = 0
    do {
      try await RuntimeFixture.settle(
        timeout: .milliseconds(20),
        stableFor: .milliseconds(10),
        pollInterval: .milliseconds(1),
      ) {
        reads += 1
        return changing ? "frame \(reads)" : " \n\t "
      }
      Issue.record("unsettled screen returned success")
    } catch {
      #expect(error as? RuntimeFixtureError == .timedOut("settled screen"))
    }
    #expect(reads > 0)
  }

  @Test
  func stableIntervalRestartsWhenScreenChanges() async throws {
    var reads = 0
    var changedAt: ContinuousClock.Instant?
    try await RuntimeFixture.settle(
      timeout: .seconds(2),
      stableFor: .milliseconds(20),
      pollInterval: .milliseconds(1),
    ) {
      reads += 1
      if reads == 2 { changedAt = .now }
      return reads < 2 ? "first prompt" : "second prompt"
    }
    let changed = try #require(changedAt)
    #expect(changed.duration(to: .now) >= .milliseconds(20))
  }

  @Test
  func pollingDistinguishesReadinessAndTimeout() async throws {
    try await RuntimeFixture.wait("ready", timeout: .zero) { true }
    await #expect(throws: RuntimeFixtureError.timedOut("missing")) {
      try await RuntimeFixture.wait("missing", timeout: .zero) { false }
    }
  }

  @Test
  func invalidTimingIsRefused() async {
    await #expect(throws: RuntimeFixtureError.invalidTiming) {
      try await RuntimeFixture.wait("invalid", timeout: .seconds(-1)) { true }
    }
    await #expect(throws: RuntimeFixtureError.invalidTiming) {
      try await RuntimeFixture.wait("invalid", pollInterval: .zero) { true }
    }
    await #expect(throws: RuntimeFixtureError.invalidTiming) {
      try await RuntimeFixture.settle(stableFor: .seconds(-1)) { "prompt" }
    }
  }

  @Test(arguments: [false, true])
  func cleanupIsAwaitedExactlyOnceAndPreservesResultOrFailure(
    _ fail: Bool,
  ) async {
    var order: [String] = []
    do {
      let result = try await RuntimeFixture.withCleanup {
        order.append("work")
        if fail { throw Failure.intentional }
        return 42
      } cleanup: {
        order.append("cleanup starts")
        await Task.yield()
        order.append("cleanup ends")
      }
      #expect(!fail && result == 42)
    } catch { #expect(fail && error is Failure) }
    #expect(order == ["work", "cleanup starts", "cleanup ends"])
  }

  @Test
  func canceledPollingUnwindsNestedResourceCleanup() async throws {
    var order: [String] = []
    var polling = false
    let task = Task {
      try await RuntimeFixture.withCleanup {
        try await RuntimeFixture.withCleanup {
          try await RuntimeFixture.wait("never ready", timeout: .seconds(30)) {
            polling = true
            return false
          }
        } cleanup: {
          order.append("inner resource")
        }
      } cleanup: {
        order.append("outer resource")
      }
    }
    defer { task.cancel() }
    let deadline = ContinuousClock.now + .seconds(2)
    while !polling {
      try #require(ContinuousClock.now < deadline)
      await Task.yield()
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(order == ["inner resource", "outer resource"])
  }

  @Test(arguments: [false, true])
  func cancellationIsCheckedBeforeAndAfterSuccessfulWork(
    _ cancelBefore: Bool,
  ) async {
    var work = 0
    var cleanup = 0
    let task = Task {
      if cancelBefore { withUnsafeCurrentTask { $0?.cancel() } }
      try await RuntimeFixture.withCleanup {
        work += 1
        withUnsafeCurrentTask { $0?.cancel() }
      } cleanup: {
        cleanup += 1
      }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(work == (cancelBefore ? 0 : 1))
    #expect(cleanup == 1)
  }
}
