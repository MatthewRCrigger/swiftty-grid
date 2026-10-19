#if os(macOS)
@testable import AppleTransport
import Foundation
import Network
import ScreenProtocol
import SessionCore
import Synchronization
import Testing

/// A snapshot cancelled before the client processes its stream's
/// readiness still returns its stream credit (split from
/// QUICTransportTests to keep both files within lint limits).
extension QUICTransportTests {
  @Test(arguments: [false, true], [false, true])
  func cancellationBeforeClientProcessesReadinessReturnsSnapshotCredit(
    cancelAtAdoption: Bool,
    separateFIN: Bool
  ) async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    let client = try await connector()
      .connectQUIC(
        host: "127.0.0.1",
        port: listener.port,
        pin: loopbackIdentity.pin,
      )
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    )
    try await transportEventually { accepted.count == 1 }
    let (server, _) = try #require(accepted.all.first)
    client.enableSnapshotReadDiagnosticsForTesting()
    server.enableSnapshotReadDiagnosticsForTesting()
    let wire = SnapshotCancellationWriter()
    @Sendable
    func cancelSnapshot() {
      wire.cancel()
      server.cancelSnapshot(stream: 1)
    }
    func step(_ stage: String, _ body: () async throws -> Void) async throws {
      do { try await body() } catch {
        Issue.record(
          Comment(
            rawValue: """
              queued cancellation stage=\(stage), snapshot lengths=\(inbox.snapshots.map(\.count))
              separate FIN=\(separateFIN), wire=\(wire.progress)
              client: \(client.snapshotDiagnosticsForTesting)
              server: \(server.snapshotDiagnosticsForTesting)
              """
          )
        )
        throw error
      }
    }
    let payload = snapshotPayload(
      bodyLength: RSTLimits.maxSnapshotEncodedBytes,
      fill: 1
    )
    let gate = Mutex((armed: true, suspended: false))
    client.setBeforeInboundStartForTesting { [weak client] in
      guard let client else { return }
      let adopted = gate.withLock { gate -> Bool in
        guard gate.armed else { return false }
        client.queue.suspend()
        gate.suspended = true
        return true
      }
      // Cancel in the adoption callback as well as from the polling caller:
      // the polling caller may not run until native send completion.
      if adopted, cancelAtAdoption { cancelSnapshot() }
    }
    func releaseGate() {
      let resume = gate.withLock { gate in
        gate.armed = false
        let resume = gate.suspended
        gate.suspended = false
        return resume
      }
      client.setBeforeInboundStartForTesting(nil)
      if resume { client.queue.resume() }
    }
    defer { releaseGate() }
    let write = separateFIN ? wire.write : nil
    let send = Task {
      try await server.sendSnapshot(
        payload,
        stream: 1,
        beforeRegistration: nil,
        write: write
      )
    }
    defer { send.cancel() }
    try await step("peer stream adoption") {
      try await transportEventually(.seconds(2)) {
        gate.withLock { $0.suspended }
      }
    }
    if !cancelAtAdoption { cancelSnapshot() }
    _ = await send.result
    // Cancellation resumes the waiter before Network finishes the stream.
    // Hold readiness until the native finish has actually been submitted.
    try await step("native finish") {
      try await transportEventually(.seconds(2)) {
        server.snapshotDiagnosticsForTesting.contains("outbound finish,")
      }
    }
    releaseGate()
    try await step("cancellation credit") {
      try await transportEventually(.seconds(2)) {
        client.snapshotDiagnosticsForTesting.contains("released=1,")
      }
    }
    // The server cancels its finished stream only after the client released it.
    try await step("native retirement") {
      try await transportEventually(.seconds(2)) {
        server.snapshotDiagnosticsForTesting.contains("outbound retire,")
      }
    }
    let good = snapshotPayload(bodyLength: 100, fill: 2)
    try await step("replacement send") {
      try await server.sendSnapshot(good, stream: 2)
    }
    try await expectReplacementDelivered(
      good,
      inbox: inbox,
      client: client,
      server: server
    )
  }

  /// The stream after a cancelled one is delivered and its credit
  /// returned, on connections that both stay open.
  private func expectReplacementDelivered(
    _ good: [UInt8],
    inbox: Inbox,
    client: QUICRSTConnection,
    server: QUICRSTConnection
  ) async throws {
    do {
      try await transportEventually(.seconds(2)) {
        inbox.snapshots.last == good
      }
      try await transportEventually(.seconds(2)) {
        client.snapshotDiagnosticsForTesting.contains("released=2,")
      }
    } catch {
      Issue.record(
        Comment(
          rawValue: """
            queued cancellation snapshot lengths=\(inbox.snapshots.map(\.count))
            client: \(client.snapshotDiagnosticsForTesting)
            server: \(server.snapshotDiagnosticsForTesting)
            """
        )
      )
      throw error
    }
    #expect(!client.isClosed)
    #expect(!server.isClosed)
  }
}

private final class SnapshotCancellationWriter: Sendable {
  private let state = Mutex(
    (allowFIN: true, bodyCallback: false, finSubmitted: false)
  )

  var progress: (allowFIN: Bool, bodyCallback: Bool, finSubmitted: Bool) {
    state.withLock { $0 }
  }

  func cancel() { state.withLock { $0.allowFIN = false } }

  var write: QUICRSTConnection.ControlWrite {
    { stream, bytes, completed in
      stream.send(
        content: bytes,
        contentContext: .finalMessage,
        isComplete: false,
        completion: .contentProcessed { error in
          let submitted = self.state.withLock { wire -> Bool in
            wire.bodyCallback = true
            guard error == nil, wire.allowFIN else { return false }
            wire.finSubmitted = true
            stream.send(
              content: nil,
              contentContext: .finalMessage,
              isComplete: true,
              completion: .contentProcessed(completed)
            )
            return true
          }
          if !submitted { completed(error) }
        }
      )
    }
  }
}
#endif
