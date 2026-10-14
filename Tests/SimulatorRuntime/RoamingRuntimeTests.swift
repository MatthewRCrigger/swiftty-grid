import Foundation
import ScreenProtocol
import SessionCore
import SwifttyCore
import TerminalSurface
import XCTest

/// Runs the direct-client roaming stack inside a simulator runtime against
/// a real SwiftMux service with roaming (`swiftmux-agent --roaming-config`) on
/// the Mac (Scripts/test-roaming-simulator.sh).
/// The control socket stands in for the SSH exec hop, which needs the
/// user's SSH credentials.
final class RoamingRuntimeTests: XCTestCase {
  struct SocketBootstrapper: RemoteBootstrapper {
    let path: String

    func bootstrap(
      _ request: BootstrapRequest
    ) async throws -> BootstrapResponse {
      let reply = try await RuntimeSocket.exchange(
        path: path,
        request: BootstrapEnvelope.encode(request),
        maximumBodyBytes: RSTLimits.maxBootstrapEnvelopeBytes,
      )
      return try BootstrapEnvelope.decode(BootstrapResponse.self, from: reply)
    }
  }

  final class RecordingSink: PresentationSink, Sendable {
    private let recorder: RuntimePresentationRecorder<PresentationFrame>
    init(_ display: TerminalSession) {
      recorder = RuntimePresentationRecorder(
        install: { display.installPresentation($0) },
        snapshot: { display.snapshot().text },
      )
    }

    func install(_ frame: PresentationFrame) -> Bool { recorder.install(frame) }

    var summary: String { recorder.summary }
  }

  /// Waits until the screen has content and is unchanged for 750 ms.
  func settle(_ display: TerminalSession) async throws {
    try await RuntimeFixture.settle {
      display.snapshot().text.joined(separator: "\n")
    }
  }

  func waitFor(
    _ what: String,
    timeout: TimeInterval = 20,
    _ condition: () async -> Bool,
  ) async throws {
    try await RuntimeFixture.wait(what, timeout: .seconds(timeout), condition)
  }

  func testRoamingSessionSurvivesBackgroundingInSimulatorRuntime() async throws
  {
    let path = try XCTUnwrap(
      ProcessInfo.processInfo.environment["RST_CONTROL_SOCKET"],
      "run through Scripts/test-roaming-simulator.sh",
    )
    let display = TerminalSession(presentationColumns: 80, rows: 24)
    let sink = RecordingSink(display)
    let client = RoamingClient(
      bootstrapper: SocketBootstrapper(path: path),
      connector: QUICGrantConnector(),
      sink: sink,
    )
    let screen: @Sendable () -> String = {
      display.snapshot().text.joined(separator: "\n")
    }

    try await RuntimeFixture.withCleanup {
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
    } cleanup: {
      await client.close(.terminate)
    }
  }
}
