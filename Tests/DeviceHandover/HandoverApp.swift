import Foundation
import Network
import Observation
import ScreenProtocol
import SessionCore
import SSHClient
import SwiftUI
import SwifttyCore
import TerminalSurface

/// Acceptance test A2 on a physical iPhone (Scripts/test-handover.sh).
///
/// Runs as a plain app, not under XCTest, so switching the phone's Wi-Fi
/// off cannot cut a wireless debugging link. It keeps one roaming session
/// open; after every Wi-Fi ↔ cellular switch it waits for recovery and runs
/// `echo hop-N-$$ | tee -a <log>` in the retained shell on the Mac. The Mac
/// log is the evidence: one line per switch, all from the same shell PID.
@main
struct HandoverApp: App {
  @State private var runner = HandoverRunner()

  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading, spacing: 8) {
        Text("Roaming handover (A2)").font(.headline)
        Text(runner.headline).font(.title3.monospaced())
        ScrollView {
          Text(runner.lines.joined(separator: "\n"))
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding()
      .task { await runner.run() }
    }
  }
}

@MainActor @Observable
final class HandoverRunner {
  var headline = "starting"
  var lines: [String] = []

  private func note(_ line: String) {
    lines.append(line)
    if lines.count > 200 { lines.removeFirst() }
  }

  func run() async {
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
    let switches = env["RST_HANDOVER_SWITCHES"].flatMap(Int.init) ?? 50
    UIApplication.shared.isIdleTimerDisabled = true

    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let client = RoamingClient(
      bootstrapper: SSHBootstrapper(
        endpoint: SSHEndpoint(
          configuration: SSHClient.SSHClientConfiguration(
            host: host,
            port: port,
            username: "rst",
            connectTimeout: .seconds(20)
          ),
          credential: .password(password),
          trustStore: InMemoryHostTrustStore(keys: [identity: hostKey])
        )
      ),
      connector: QUICGrantConnector(),
      sink: display
    )
    let paths = PathWatcher()
    func screen() -> String { display.snapshot().text.joined(separator: "\n") }
    func run(_ command: String) async {
      _ = await client.submit(.text(command))
      _ = await client.submit(.key(SemanticKey(.enter)))
    }

    do {
      try await client.start(.create(GridSize(columns: 80, rows: 24)))
    } catch {
      headline = "start failed: \(error)"
      return
    }
    guard await wait(seconds: 60, { await client.state == .active }) else {
      headline = "attach failed"
      return
    }
    try? await Task.sleep(for: .seconds(2))  // let the prompt draw
    await run("echo ready-$$ | tee -a \(logPath)")
    guard await wait(seconds: 30, { screen().contains("ready-") }) else {
      headline = "shell did not answer"
      return
    }
    headline = "toggle Wi-Fi: 0/\(switches)"
    note("ready on \(paths.current)")

    var last = paths.current
    for hop in 1 ... switches {
      guard await wait(seconds: 900, {
        let now = paths.current
        return now != last && (now == "wifi" || now == "cellular")
      }) else {
        headline = "no switch within 15 min"
        return
      }
      let started = Date()
      last = paths.current
      await client.pathChanged()
      guard await wait(seconds: 180, { await client.state == .active }) else {
        headline = "no recovery after switch \(hop)"
        await run("echo FAILED-recovery-\(hop) | tee -a \(logPath)")
        return
      }
      await run("echo hop-$((\(hop)*1))-$$-\(last) | tee -a \(logPath)")
      guard await wait(seconds: 180, { screen().contains("hop-\(hop)-") }) else {
        headline = "no output after switch \(hop)"
        return
      }
      let seconds = Date().timeIntervalSince(started)
      note(String(format: "switch %d to %@: %.2fs", hop, last, seconds))
      headline = "toggle Wi-Fi: \(hop)/\(switches)"
    }
    await run("echo done-$$ | tee -a \(logPath)")
    headline = "done: \(switches) switches"
  }

  private func wait(
    seconds: Double,
    _ condition: () async -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !(await condition()) {
      if Date() > deadline { return false }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return true
  }
}

/// The phone's current primary interface: "wifi", "cellular" or "none".
final class PathWatcher: @unchecked Sendable {
  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var kind = "none"

  init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let kind: String =
        path.status != .satisfied ? "none"
        : path.usesInterfaceType(.wifi) ? "wifi"
        : path.usesInterfaceType(.cellular) ? "cellular" : "other"
      self?.lock.lock()
      self?.kind = kind
      self?.lock.unlock()
    }
    monitor.start(queue: DispatchQueue(label: "handover.path"))
  }

  var current: String {
    lock.lock(); defer { lock.unlock() }
    return kind
  }
}
