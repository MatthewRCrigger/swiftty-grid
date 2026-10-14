import Darwin
import Foundation
@testable import SwiftMuxClient
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LaunchAgentCommandTests {
  @Test(arguments: [Int32(0), 113, 124])
  func completedCommandsPreserveExactExitStatus(status: Int32) throws {
    #expect(
      try LaunchAgentCommand.runExecutable(
        "/bin/sh",
        arguments: ["-c", "exit \(status)"],
        timeout: .seconds(2),
      ) == status
    )
  }

  @Test
  func spawnAndSignalFailuresAreErrors() throws {
    #expect(throws: LaunchAgentCommand.Failure.invalidArgument) {
      try LaunchAgentCommand.runExecutable(
        "/bin/sh",
        arguments: ["bad\0argument"],
        timeout: .seconds(2),
      )
    }
    #expect(
      throws: LaunchAgentCommand.Failure.systemCall("posix_spawn", ENOENT, )
    ) {
      try LaunchAgentCommand.runExecutable(
        "/no-such-swiftty-command-" + UUID().uuidString,
        arguments: [],
        timeout: .seconds(2),
      )
    }
    #expect(throws: LaunchAgentCommand.Failure.signaled(SIGTERM)) {
      try LaunchAgentCommand.runExecutable(
        "/bin/sh",
        arguments: ["-c", "kill -TERM $$"],
        timeout: .seconds(2),
      )
    }
  }

  @Test
  func timeoutKillsAndReapsNoncooperativeChildAndPreservesPlist() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("agent-command-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let plist = directory.appendingPathComponent("agent.plist")
    try Data("preserve".utf8).write(to: plist)
    var probed = false
    let started = ContinuousClock.now
    #expect(throws: LaunchAgentCommand.Failure.timedOut) {
      try LaunchAgentRemoval.remove(
        bootout: {
          try LaunchAgentCommand.runExecutable(
            "/bin/sh",
            arguments: [
              "-c",
              "trap '' TERM HUP; echo $$ > \"$1\"; while :; do sleep 30; done",
              "sh", pidFile.path,
            ],
            timeout: .milliseconds(200),
          )
        },
        probe: {
          probed = true;
          return 113
        },
        removePlist: { try LaunchAgentRemoval.unlinkPlist(at: plist) },
      )
    }
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(!probed)
    #expect(try Data(contentsOf: plist) == Data("preserve".utf8))
    let pid = try #require(
      pid_t(
        String(contentsOf: pidFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      )
    )
    let deadline = ContinuousClock.now + .seconds(2)
    var reaped = false
    repeat {
      var info = siginfo_t()
      reaped =
        waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1
        && errno == ECHILD
      if reaped { break }
      usleep(10000)
    } while ContinuousClock.now < deadline
    #expect(reaped)
  }
}
