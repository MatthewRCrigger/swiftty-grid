#if os(macOS)
import Foundation
import Testing
import TestSupport

@Suite(.serialized)
@MainActor
struct HandoverExecutionTests {
  private enum Failure: Error { case intentional }

  @Test(arguments: ["0", "-1", "invalid", "9223372036854775808", ""])
  func invalidSwitchCountsAreRefused(_ value: String) {
    #expect(HandoverExecution.switchCount(value) == nil)
    #expect(HandoverExecution.switchCount(nil) == 50)
    #expect(HandoverExecution.switchCount("1") == 1)
  }

  @Test(arguments: ["0", "-1", "invalid", "", "9223372036854775808"])
  func scriptRejectsInvalidCountsBeforeStartingExternalFixtures(
    _ value: String,
  ) throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let result = try runShell(arguments: [
      root.appendingPathComponent("Scripts/test-handover.sh").path,
      "unused-device", value,
    ])
    #expect(result.status == 2)
    #expect(result.output.contains("switches must be a positive integer"), )
  }

  @Test(arguments: [
    "x y", "a'b", "$(printf injected)", "`printf injected`",
    "; printf injected", "-log", "漢",
  ])
  func quotedPathsRemainOneLiteralShellArgument(_ value: String) throws {
    let result = try runShell(arguments: [
      "-c", "printf '%s' " + HandoverExecution.shellQuote(value),
    ])
    #expect(result.status == 0)
    #expect(result.output == value)
  }

  private func runShell(
    arguments: [String]
  ) throws -> (status: Int32, output: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "handover-output-" + UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: url) }
    try Data().write(to: url)
    let output = try FileHandle(forWritingTo: url)
    defer { try? output.close() }
    let status = try TestCommand.run(
      "/bin/sh",
      arguments: arguments,
      timeout: .seconds(5),
      stdout: output.fileDescriptor,
      stderr: output.fileDescriptor,
      maxOutputBytes: 16 * 1024,
    )
    return try (status, String(decoding: Data(contentsOf: url), as: UTF8.self))
  }

  @Test
  func evidenceRequiresCompleteOutputWithAPositiveNumericPID() {
    for line in [
      "echo ready-$$", "printf 'ready-%s\\n' \"$$\"", "prompt ready-12",
      "ready-0", "ready-+1", "ready-12 trailing",
      "ready-999999999999999999999999",
    ] { #expect(HandoverExecution.pid(in: [line], prefix: "ready-") == nil) }
    #expect(
      HandoverExecution.pid(in: ["  ready-4312  "], prefix: "ready-") == 4312,
    )
    #expect(
      HandoverExecution.pid(
        in: ["hop-4-4312-wifi-migrated"],
        prefix: "hop-4-",
        suffix: "-wifi-migrated",
      ) == 4312,
    )
    #expect(
      HandoverExecution.pid(
        in: ["hop-4-4312-wifi-migrated"],
        prefix: "hop-5-",
        suffix: "-wifi-migrated",
      ) == nil,
    )
    for path in ["", "x\n", "x\r", "x\0", "x\t", "x\u{1B}"] {
      #expect(!HandoverExecution.validLogPath(path))
    }
    #expect(HandoverExecution.validLogPath("/tmp/path with 'quotes'"))
  }

  @Test
  func onlyOneTaskCanStartTheRunner() async {
    let gate = HandoverRunGate()
    let admitted = await withTaskGroup(of: Bool.self) { group in
      for _ in 0 ..< 100 { group.addTask { await gate.begin() } }
      var admitted = 0
      for await began in group where began { admitted += 1 }
      return admitted
    }
    #expect(admitted == 1)
    #expect(!gate.begin())
  }

  @Test(arguments: [false, true])
  func successAndFailureRunCleanupExactlyOnce(_ fail: Bool) async throws {
    var worked = 0
    var cleaned = 0
    do {
      try await HandoverExecution.withCleanup {
        worked += 1
        if fail { throw Failure.intentional }
      } cleanup: {
        cleaned += 1
      }
      #expect(!fail)
    } catch { #expect(fail && error is Failure) }
    #expect(worked == 1 && cleaned == 1)
  }

  @Test
  func cancellationStopsWaitingAndStillRunsCleanup() async throws {
    var polls = 0
    var cleaned = 0
    let start = ContinuousClock.now
    let waiting = Task {
      try await HandoverExecution.withCleanup {
        _ = try await HandoverExecution.wait(
          timeout: .seconds(30),
          pollInterval: .milliseconds(5),
        ) {
          polls += 1
          return false
        }
      } cleanup: {
        cleaned += 1
      }
    }
    defer { waiting.cancel() }
    while polls == 0 {
      try #require(ContinuousClock.now - start < .seconds(1))
      await Task.yield()
    }
    waiting.cancel()
    do {
      try await waiting.value
      Issue.record("canceled wait returned normally")
    } catch { #expect(error is CancellationError) }
    #expect(cleaned == 1)
    #expect(ContinuousClock.now - start < .seconds(1))
    #expect(
      try await HandoverExecution.wait(timeout: .zero) { false } == false,
    )
  }
}
#endif
