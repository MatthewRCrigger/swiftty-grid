import Foundation
import Observation
import ScreenProtocol
import SessionCore
import SSHClient
import SwifttyCore
import SwiftUI
import TerminalSurface

/// Acceptance test A2 on a physical iPhone (Scripts/test-handover.sh).
///
/// Runs as a plain app, not under XCTest, so switching the phone's Wi-Fi
/// off cannot cut a wireless debugging link. It keeps one roaming session
/// open; after every Wi-Fi ↔ cellular switch it waits for recovery and runs
/// `printf` with the shell PID in the retained shell on the Mac. The Mac
/// log is the evidence: one line per switch, all from the same shell PID.
@main
struct HandoverApp: App {
  @State
  private var runner = HandoverRunner()

  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading, spacing: 8) {
        Text("Roaming handover (A2)").font(.headline)
        Text(runner.headline).font(.title3.monospaced())
        ScrollView {
          Text(runner.lines.joined(separator: "\n")).font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding().task { await runner.run() }
    }
  }
}

@MainActor
@Observable
final class HandoverRunner {
  var headline = "starting"
  var lines: [String] = []
  private let gate = HandoverRunGate()

  private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  private func note(_ line: String) {
    lines.append(line)
    if lines.count > 200 { lines.removeFirst() }
  }

  func run() async {
    guard gate.begin() else { return }
    let env = ProcessInfo.processInfo.environment
    guard let host = env["RST_HANDOVER_HOST"],
      let port = env["RST_HANDOVER_PORT"].flatMap(Int.init),
      let password = env["RST_HANDOVER_PASSWORD"],
      let hostKey = env["RST_HANDOVER_HOSTKEY"],
      let logPath = env["RST_HANDOVER_LOG"],
      let identity = SSHClient.HostIdentity(host: host, port: port)
    else {
      headline = "missing configuration"
      return
    }
    guard
      let switches = HandoverExecution.switchCount(
        env["RST_HANDOVER_SWITCHES"],
      ), HandoverExecution.validLogPath(logPath)
    else {
      headline = "invalid switch count or log path"
      return
    }
    let previousIdleSetting = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true

    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let client = RoamingClient(
      bootstrapper: SSHBootstrapper(
        endpoint: SSHEndpoint(
          configuration: SSHClient.SSHClientConfiguration(
            host: host,
            port: port,
            username: "rst",
            connectTimeout: .seconds(20),
          ),
          credential: .password(password),
          trustStore: InMemoryHostTrustStore(keys: [identity: hostKey]),
        ),
      ),
      connector: QUICGrantConnector(),
      sink: display,
    )
    let paths = HandoverPathWatcher()
    do {
      try await HandoverExecution.withCleanup {
        try await perform(
          client,
          display: display,
          paths: paths,
          switches: switches,
          logPath: logPath,
        )
      } cleanup: {
        paths.stop()
        await client.setStatusHandler(nil)
        await client.close()
        UIApplication.shared.isIdleTimerDisabled = previousIdleSetting
      }
    } catch {
      headline =
        Task.isCancelled || error is CancellationError
        ? "canceled" : "failed: \(error)"
    }
  }

  private func perform(
    _ client: RoamingClient,
    display: TerminalSession,
    paths: HandoverPathWatcher,
    switches: Int,
    logPath: String,
  ) async throws {
    let seen = HandoverStateLog()
    await client.setStatusHandler { status in seen.record(status.state) }
    let quotedLog = HandoverExecution.shellQuote(logPath)
    func lines() -> [String] { display.snapshot().text }
    func command(_ command: String) async throws {
      try Task.checkCancellation()
      guard await client.submit(.text(command)).isAccepted else {
        throw Failure("command refused")
      }
      try Task.checkCancellation()
      guard await client.submit(.key(SemanticKey(.enter))).isAccepted else {
        throw Failure("Enter refused")
      }
    }
    func output(_ format: String) async throws {
      try await command("printf '\(format)\\n' \"$$\" | tee -a -- \(quotedLog)")
    }
    try await client.start(.create(GridSize(columns: 80, rows: 24)))
    guard
      try await HandoverExecution.wait(
        timeout: .seconds(60),
        { await client.state == .active },
      )
    else { throw Failure("attach failed") }
    try await output("ready-%s")
    guard
      try await HandoverExecution.wait(
        timeout: .seconds(30),
        { HandoverExecution.pid(in: lines(), prefix: "ready-") != nil },
      ), let shellPID = HandoverExecution.pid(in: lines(), prefix: "ready-")
    else { throw Failure("shell did not answer") }
    var initialPath: String?
    guard
      try await HandoverExecution.wait(
        timeout: .seconds(30),
        {
          let now = paths.current
          guard now == "wifi" || now == "cellular" else { return false }
          initialPath = now
          return true
        },
      ), let initialPath
    else { throw Failure("no Wi-Fi or cellular path") }
    var last = initialPath
    note("ready on \(last)")
    headline = "toggle Wi-Fi: 0/\(switches)"
    for hop in 1 ... switches {
      seen.reset()
      var nextPath: String?
      guard
        try await HandoverExecution.wait(
          timeout: .seconds(900),
          {
            let now = paths.current
            guard now != last, now == "wifi" || now == "cellular" else {
              return false
            }
            nextPath = now
            return true
          },
        ), let nextPath
      else { throw Failure("no switch within 15 min") }
      let clock = ContinuousClock()
      let started = clock.now
      last = nextPath
      await client.pathChanged()
      guard
        try await HandoverExecution.wait(
          timeout: .seconds(180),
          { await client.state == .active },
        )
      else { throw Failure("no recovery after switch \(hop)") }
      try await Task.sleep(for: .seconds(1))
      let mode = seen.reattached ? "reattached" : "migrated"
      try await output("hop-\(hop)-%s-\(last)-\(mode)")
      guard
        try await HandoverExecution.wait(
          timeout: .seconds(180),
          {
            HandoverExecution.pid(
              in: lines(),
              prefix: "hop-\(hop)-",
              suffix: "-\(last)-\(mode)",
            ) != nil
          },
        ),
        HandoverExecution.pid(
          in: lines(),
          prefix: "hop-\(hop)-",
          suffix: "-\(last)-\(mode)",
        ) == shellPID
      else {
        throw Failure("missing output or changed shell after switch \(hop)")
      }
      let elapsed = started.duration(to: clock.now).components
      let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
      note("switch \(hop) to \(last): " + String(format: "%.2fs", seconds))
      headline = "toggle Wi-Fi: \(hop)/\(switches)"
    }
    try await output("done-%s")
    guard
      try await HandoverExecution.wait(
        timeout: .seconds(30),
        { HandoverExecution.pid(in: lines(), prefix: "done-") == shellPID },
      )
    else { throw Failure("completion did not reach the shell") }
    headline = "done: \(switches) switches"
  }
}
