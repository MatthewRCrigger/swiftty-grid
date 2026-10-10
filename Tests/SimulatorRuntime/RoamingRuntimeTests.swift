import Darwin
import Foundation
import ScreenProtocol
import SessionCore
import SwifttyCore
import TerminalSurface
import XCTest

/// Runs the direct-client roaming stack inside a simulator runtime against
/// a real `swifttyd serve` on the Mac (Scripts/test-roaming-simulator.sh).
/// The control socket stands in for the SSH exec hop, which needs the
/// user's SSH credentials.
final class RoamingRuntimeTests: XCTestCase {
  struct SocketBootstrapper: RemoteBootstrapper {
    let path: String

    func bootstrap(_ request: BootstrapRequest) async throws -> BootstrapResponse {
      let fd = socket(AF_UNIX, SOCK_STREAM, 0)
      guard fd >= 0 else { throw RemoteBootstrapError.unreachable }
      defer { close(fd) }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (i, byte) in path.utf8.prefix(buffer.count - 1).enumerated() {
          buffer[i] = byte
        }
      }
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      guard connected == 0 else { throw RemoteBootstrapError.unreachable }
      let request = try BootstrapEnvelope.encode(request)
      guard write(fd, request, request.count) == request.count else {
        throw RemoteBootstrapError.unreachable
      }
      var reply: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        if let total = try BootstrapEnvelope.expectedLength(reply),
          reply.count >= total
        { break }
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { break }
        reply += buffer[0 ..< n]
      }
      return try BootstrapEnvelope.decode(BootstrapResponse.self, from: reply)
    }
  }

  final class RecordingSink: PresentationSink, @unchecked Sendable {
    let display: TerminalSession
    let lock = NSLock()
    var results: [Bool] = []
    var lastLines: [String] = []
    init(_ display: TerminalSession) { self.display = display }
    func install(_ frame: PresentationFrame) -> Bool {
      let ok = display.installPresentation(frame)
      var lines: [String] = []
      for y in 0 ..< frame.rows {
        lines.append(
          frame.cells[(y * frame.columns) ..< ((y + 1) * frame.columns)]
            .map { $0.text.isEmpty ? " " : $0.text }.joined()
        )
      }
      lock.lock()
      results.append(ok)
      lastLines = lines
      lock.unlock()
      return ok
    }
    var summary: String {
      lock.lock(); defer { lock.unlock() }
      return "installs \(results)\nframe:\n" + lastLines.joined(separator: "\n")
    }
  }

  /// Waits until the screen has content and is unchanged for 750 ms.
  func settle(_ display: TerminalSession) async throws {
    var last = ""
    var stableSince = Date()
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      let now = display.snapshot().text.joined(separator: "\n")
      if now != last {
        last = now
        stableSince = Date()
      } else if !now.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        Date().timeIntervalSince(stableSince) > 0.75
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  func waitFor(
    _ what: String,
    timeout: TimeInterval = 20,
    _ condition: () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
      if Date() > deadline { XCTFail("timed out: \(what)"); throw CancellationError() }
      try await Task.sleep(for: .milliseconds(25))
    }
  }

  func testRoamingSessionSurvivesBackgroundingInSimulatorRuntime() async throws {
    let path = try XCTUnwrap(
      ProcessInfo.processInfo.environment["RST_CONTROL_SOCKET"],
      "run through Scripts/test-roaming-simulator.sh"
    )
    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let sink = RecordingSink(display)
    let client = RoamingClient(
      bootstrapper: SocketBootstrapper(path: path),
      connector: QUICGrantConnector(),
      sink: sink
    )
    let screen: @Sendable () -> String = { display.snapshot().text.joined(separator: "\n") }

    try await client.start(.create(GridSize(columns: 80, rows: 24)))
    try await waitFor("active") { await client.state == .active }
    // Interactive shells may discard typeahead sent before the first
    // prompt is drawn; wait for a stable screen first.
    try await settle(display)
    _ = await client.submit(.text("export SIM_MARK=sim-$((6*7))"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    try await settle(display)
    _ = await client.submit(.text("echo $SIM_MARK"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    do {
      try await waitFor("first echo") { screen().contains("sim-42") }
    } catch {
      let status = await client.status
      XCTFail("status: \(status)\nscreen:\n\(screen())\n\(sink.summary)")
      throw error
    }

    // A10 analogue: background detaches, foreground reattaches to the
    // same retained shell and requires a full screen before input.
    await client.enterBackground()
    let backgrounded = await client.state
    XCTAssertEqual(backgrounded, .backgroundDetached)
    let refused = await client.submit(.text("x"))
    XCTAssertFalse(refused.isAccepted)
    await client.enterForeground()
    try await waitFor("reattached") { await client.state == .active }
    try await settle(display)
    _ = await client.submit(.text("echo again-$SIM_MARK"))
    _ = await client.submit(.key(SemanticKey(.enter)))
    try await waitFor("retained shell") { screen().contains("again-sim-42") }

    await client.close(.terminate)
  }
}
