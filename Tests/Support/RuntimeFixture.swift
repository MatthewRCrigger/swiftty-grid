import Foundation

public enum RuntimeFixtureError: Error, Equatable, Sendable {
  case timedOut(String)
  case invalidTiming
}

/// Shared by external runtime tests and locally exercised without a device.
public enum RuntimeFixture {
  public static func wait(
    _ what: String,
    timeout: Duration = .seconds(20),
    pollInterval: Duration = .milliseconds(25),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool,
  ) async throws {
    guard timeout >= .zero, pollInterval > .zero else {
      throw RuntimeFixtureError.invalidTiming
    }
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while true {
      try Task.checkCancellation()
      if await condition() {
        try Task.checkCancellation()
        return
      }
      guard clock.now < deadline else {
        throw RuntimeFixtureError.timedOut(what)
      }
      try await clock.sleep(until: min(clock.now + pollInterval, deadline))
    }
  }

  public static func settle(
    timeout: Duration = .seconds(20),
    stableFor: Duration = .milliseconds(750),
    pollInterval: Duration = .milliseconds(50),
    isolation: isolated (any Actor)? = #isolation,
    _ screen: () -> String,
  ) async throws {
    guard stableFor >= .zero else { throw RuntimeFixtureError.invalidTiming }
    var last: String?
    var since = ContinuousClock.now
    try await wait(
      "settled screen",
      timeout: timeout,
      pollInterval: pollInterval,
      isolation: isolation,
    ) {
      let current = screen()
      if current != last {
        last = current
        since = .now
      }
      return !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && since.duration(to: .now) >= stableFor
    }
  }

  public static func withCleanup<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ work: () async throws -> T,
    cleanup: () async -> Void,
  ) async throws -> T {
    let result: T
    do {
      try Task.checkCancellation()
      result = try await work()
      try Task.checkCancellation()
    } catch {
      await cleanup()
      throw error
    }
    await cleanup()
    return result
  }
}
