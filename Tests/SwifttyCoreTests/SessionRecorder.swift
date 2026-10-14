import Foundation
@testable import SwifttyCore
@testable import SwifttyEngine
import Synchronization
import Testing
import TestSupport

/// Records real applications for the replay tests (`Tests/SwifttyMobileTests/Fixtures`),
/// which check that the same bytes produce the same screen through
/// `receive`, where no PTY exists (iOS). Run with `SWIFTTY_RECORD=1`.
@Suite(
  .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["SWIFTTY_RECORD"] == "1")
)
struct SessionRecorder {
  static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("SwifttyMobileTests/Fixtures")

  final class Recorder: Sendable {
    let session = TerminalSession(columns: 80, rows: 24)
    let bytes = Mutex<[UInt8]>([])

    init(_ command: [String], env: [String: String] = [:]) throws {
      session.onProgramOutput = { [weak self] chunk in
        self?.bytes.withLock { $0 += chunk }
      }
      var config = SessionConfiguration(command: command, environment: env)
      config.removedEnvironment = ["TMUX", "TMUX_PANE"]
      try session.start(config)
    }

    func screen() -> String {
      session.withState { state in
        (0 ..< state.rows).map { state.text(row: $0) }.joined(separator: "\n")
      }
    }

    enum ReadinessFailure: Error, Equatable {
      case timedOut(String)
      case exited(String)
    }

    /// Missing markers stop the recording before it can publish fixtures.
    func wait(for text: String, timeout: Duration = .seconds(10)) throws {
      precondition(timeout > .zero)
      let deadline = ContinuousClock.now + timeout
      while true {
        let readiness = session.withState { state in
          let screen = (0 ..< state.rows).map { state.text(row: $0) }
            .joined(separator: "\n")
          return (screen.contains(text), session.isRunning)
        }
        if readiness.0 { return }
        if !readiness.1 { throw ReadinessFailure.exited(text) }
        if ContinuousClock.now >= deadline {
          throw ReadinessFailure.timedOut(text)
        }
        usleep(20000)
      }
    }

    func type(_ s: String) { session.send(.text(s)) }

    /// Physical reads can include a tail still held behind reply pressure.
    /// Replay the captured bytes so the saved text describes all of them.
    func capture() -> (data: [UInt8], text: String) {
      let data = session.withState { _ in bytes.withLock { $0 } }
      var replay = TerminalState(columns: 80, rows: 24)
      replay.discardsReplies = true
      var parser = Parser()
      parser.consume(data.span, into: &replay)
      let text = (0 ..< replay.rows).map { replay.text(row: $0) }
        .joined(separator: "\n")
      return (data, text)
    }

    /// Saves received bytes and the screen produced by replaying them.
    func save(_ name: String) throws {
      usleep(300_000)  // let the application finish drawing
      let (data, text) = capture()
      try FileManager.default.createDirectory(
        at: SessionRecorder.fixtures,
        withIntermediateDirectories: true
      )
      try Data(data)
        .write(
          to: SessionRecorder.fixtures.appendingPathComponent("\(name).bin")
        )
      try text.write(
        to: SessionRecorder.fixtures.appendingPathComponent("\(name).txt"),
        atomically: true,
        encoding: .utf8
      )
    }
  }

  @Test
  func shell() throws {
    let r = try Recorder(["/bin/sh"], env: ["PS1": "$ ", "ENV": ""])
    defer { r.session.stop() }
    try r.wait(for: "$")
    r.type(
      "printf '\\033[1;31mred\\033[0m \\033[4:3;58;5;2mcurly\\033[0m 中文 e\\314\\201\\n'\r"
    )
    try r.wait(for: "curly")
    r.type(
      "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do echo line-$i; done\r"
    )
    try r.wait(for: "line-30")
    try r.save("shell")
  }

  @Test
  func vim() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swiftty-record-" + UUID().uuidString + ".txt"
    )
    defer { try? FileManager.default.removeItem(at: file) }
    let r = try Recorder([
      "/usr/bin/vim", "-u", "NONE", "-i", "NONE", "-N", "-n", file.path,
    ])
    defer { r.session.stop() }
    try r.wait(for: "~")
    r.type("ifirst line\rsecond line\rthird line")
    r.session.send(.key(KeyEvent(.escape)))
    r.type(":set number\r")
    try r.wait(for: "  3 third line")
    try r.save("vim")
    r.type(":q!\r")
  }

  @Test
  func less() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swiftty-record-less-" + UUID().uuidString + ".txt"
    )
    defer { try? FileManager.default.removeItem(at: file) }
    try (1 ... 300).map { "row \($0)" }.joined(separator: "\n")
      .write(to: file, atomically: true, encoding: .utf8)
    let r = try Recorder(
      ["/usr/bin/less", file.path],
      env: ["LESS": "", "LESSHISTFILE": "-"]
    )
    defer { r.session.stop() }
    try r.wait(for: "row 1\n")
    r.type(" ")
    try r.wait(for: "row 30")
    r.type("/row 4\r")
    try r.wait(for: "row 49")
    try r.save("less")
    r.type("q")
  }

  @Test(.enabled(if: IntegrationTests.which("tmux") != nil))
  func tmux() throws {
    let tmux = try #require(IntegrationTests.which("tmux"))
    let socket = "swiftty-record-" + UUID().uuidString
    defer {
      do {
        _ = try TestCommand.run(
          tmux,
          arguments: ["-L", socket, "kill-server"],
          timeout: .seconds(3)
        )
      } catch { Issue.record("tmux cleanup failed: \(error)") }
    }
    // A neutral prompt and status line, so the fixture names no user or host.
    let conf = FileManager.default.temporaryDirectory.appendingPathComponent(
      "swiftty-record-" + UUID().uuidString + ".tmux.conf"
    )
    defer { try? FileManager.default.removeItem(at: conf) }
    try """
    set -g status-left '[0] '
    set -g status-right ''
    set -g window-status-format '#I'
    set -g window-status-current-format '#I*'
    set -g default-command "env PS1='$ ' ENV= /bin/sh"
    """
    .write(to: conf, atomically: true, encoding: .utf8)
    let r = try Recorder(
      [tmux, "-L", socket, "-f", conf.path, "new-session"],
      env: ["PS1": "$ "]
    )
    defer { r.session.stop() }
    try r.wait(for: "$")
    r.type("echo left-pane\r")
    try r.wait(for: "left-pane")
    r.session.send(.key(KeyEvent(.character("b"), modifiers: .control)))
    r.type("%")
    try r.wait(for: "│")
    r.type("echo right-pane\r")
    try r.wait(for: "right-pane")
    try r.save("tmux")
  }

  @Test
  func top() throws {
    // Only `nobody`'s processes, so the fixture lists nothing of this machine's.
    let r = try Recorder([
      "/usr/bin/top", "-s", "1", "-n", "10", "-U", "nobody",
    ])
    defer { r.session.stop() }
    try r.wait(for: "PID")
    usleep(1_200_000)  // one refresh
    try r.save("top")
    r.type("q")
  }
}

struct SessionRecorderLifetimeTests {
  @Test
  func `a retained session accepts output after its recorder is released`()
    throws
  {
    var recorder: SessionRecorder.Recorder? = try SessionRecorder.Recorder([
      "/usr/bin/true"
    ])
    let session = try #require(recorder).session
    defer { session.stop() }
    recorder = nil
    session.feed(Array("retained".utf8))
    #expect(session.snapshot().text.first == "retained")
  }
}
