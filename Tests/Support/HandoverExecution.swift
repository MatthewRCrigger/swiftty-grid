import Foundation

@MainActor
public final class HandoverRunGate {
  private var started = false
  public init() {}
  public func begin() -> Bool {
    guard !started else { return false }
    started = true
    return true
  }
}

public enum HandoverExecution {
  public static func switchCount(_ configured: String?) -> Int? {
    guard let configured else { return 50 }
    guard let count = Int(configured), count > 0 else { return nil }
    return count
  }

  public static func validLogPath(_ path: String) -> Bool {
    !path.isEmpty
      && !path.unicodeScalars.contains(
        where: CharacterSet.controlCharacters.contains,
      )
  }

  public static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// A rendered output line, never a substring of the echoed command.
  public static func pid(
    in lines: [String],
    prefix: String,
    suffix: String = "",
  ) -> Int? {
    for line in lines {
      let line = line.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix(prefix), line.hasSuffix(suffix),
        line.count > prefix.count + suffix.count
      else { continue }
      let digits = line.dropFirst(prefix.count).dropLast(suffix.count)
      guard digits.utf8.allSatisfy({ (48 ... 57).contains($0) }),
        let pid = Int(digits), pid > 0
      else { continue }
      return pid
    }
    return nil
  }

  @MainActor
  public static func wait(
    timeout: Duration,
    pollInterval: Duration = .milliseconds(100),
    _ condition: @MainActor () async -> Bool,
  ) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while true {
      try Task.checkCancellation()
      if await condition() {
        try Task.checkCancellation()
        return true
      }
      guard clock.now < deadline else { return false }
      try await clock.sleep(until: min(clock.now + pollInterval, deadline))
    }
  }

  @MainActor
  public static func withCleanup(
    _ work: @MainActor () async throws -> Void,
    cleanup: @MainActor () async -> Void,
  ) async throws {
    do {
      try Task.checkCancellation()
      try await work()
      try Task.checkCancellation()
    } catch {
      await cleanup()
      throw error
    }
    await cleanup()
  }
}
