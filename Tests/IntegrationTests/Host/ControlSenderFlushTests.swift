#if os(macOS)
import Foundation
import ScreenProtocol
import Synchronization
@testable import TerminalHost
import Testing

@Suite
struct ControlSenderFlushTests {
  @Test
  func aCompletedSendIsFlushedBeforeClose() async throws {
    let connection = RecordingConnection()
    let sender = ControlSender(
      connection: connection,
      flushCloseLimit: .milliseconds(200)
    )
    sender.send(.ping(epoch: 1, nonce: 2))
    sender.closeAfterFlush()
    try await hostEventually("flush close", timeout: .seconds(2)) {
      connection.isClosed ? true : nil
    }
    #expect(connection.received.count == 1)
  }

  @Test
  func aStuckSendDoesNotHoldTheFlushClose() async throws {
    let connection = ParkedConnection()
    let sender = ControlSender(
      connection: connection,
      flushCloseLimit: .milliseconds(40)
    )
    sender.send(.ping(epoch: 1, nonce: 2))
    try await hostEventually("send parked", timeout: .seconds(2)) {
      connection.isParked ? true : nil
    }
    sender.closeAfterFlush()
    try await hostEventually("bounded flush close", timeout: .milliseconds(500))
    { connection.isClosed ? true : nil }
  }
}

private final class RecordingConnection: RSTConnection, @unchecked Sendable {
  private let state = Mutex<(records: [[UInt8]], closed: Bool)>(([], false))
  var isClosed: Bool { state.withLock { $0.closed } }
  var received: [[UInt8]] { state.withLock { $0.records } }

  func start(_ handler: RSTConnectionHandler) {}
  func sendControl(_ record: [UInt8]) async throws {
    state.withLock { $0.records.append(record) }
  }
  func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {}
  func cancelSnapshot(stream id: UInt64) {}
  func close() { state.withLock { $0.closed = true } }
}

private final class ParkedConnection: RSTConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var parked = false
  private var closed = false

  var isClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return closed
  }
  var isParked: Bool {
    lock.lock()
    defer { lock.unlock() }
    return parked
  }

  func start(_ handler: RSTConnectionHandler) {}

  func sendControl(_ record: [UInt8]) async throws {
    try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      parked = true
      self.continuation = continuation
      lock.unlock()
    }
  }

  func sendSnapshot(_ payload: [UInt8], stream id: UInt64) async throws {}
  func cancelSnapshot(stream id: UInt64) {}

  func close() {
    lock.lock()
    closed = true
    let continuation = continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(throwing: RSTTransportError.closed)
  }
}
#endif
