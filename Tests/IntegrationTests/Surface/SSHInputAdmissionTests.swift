import Dispatch
import SessionCore
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SSHInputAdmissionTests {
  private actor WriteGate {
    var waiting: CheckedContinuation<Void, Never>?
    var released = false

    func wait() async {
      guard !released else { return }
      await withCheckedContinuation { waiting = $0 }
    }

    func release() {
      released = true
      waiting?.resume()
      waiting = nil
    }
  }

  private final class Channel: TerminalByteChannel {
    let gate = WriteGate()
    let writes = Mutex<[UInt8]>([])
    let started = Mutex(false)

    func start(_: TerminalChannelHandler) {}
    func grantCredit(_: Int) {}
    func resize(columns _: Int, rows _: Int) async throws {}
    func close() async { await gate.release() }

    func write(_ bytes: [UInt8]) async throws {
      started.withLock { $0 = true }
      await gate.wait()
      writes.withLock { $0.append(contentsOf: bytes) }
    }
  }

  @Test
  func concurrentInputReservesBeforeQueuedEncoding() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      writeLimit: 88,
    )
    backend.start()
    let gate = DispatchSemaphore(value: 0)
    session.mutateAsync { _ in gate.wait() }
    let accepted = await withTaskGroup(of: Bool.self) { group in
      for _ in 0 ..< 64 {
        group.addTask {
          await backend.submit(.text("xxxx")) == .accepted(sequence: nil)
        }
      }
      var count = 0
      for await result in group where result { count += 1 }
      return count
    }
    #expect(accepted == 4)
    #expect(await backend.submit(.text("x")) == .refused(.backpressure))
    gate.signal()
    #expect(await eventually { channel.written.count == accepted * 4 })
    #expect(channel.written.count == 16)
    #expect(await backend.submit(.text("y")) == .accepted(sequence: nil))
    #expect(await eventually { channel.written.last == UInt8(ascii: "y") })
    await backend.close()
  }

  @Test
  func encodedSizeReplacesReservationUntilWriteCompletes() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = Channel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      writeLimit: 64,
    )
    backend.start()
    #expect(
      await backend.submit(.key(SemanticKey(.character("k"))))
        == .accepted(sequence: nil)
    )
    #expect(await eventually { channel.started.withLock { $0 } })
    // The key's 64-byte reservation has become one legacy byte. Switch the
    // queued commits to rich encoding: fourteen x scalars require 62 bytes.
    session.feed(Array("\u{1B}[>24u".utf8))
    #expect(
      await backend.submit(.text(String(repeating: "x", count: 14)))
        == .accepted(sequence: nil)
    )
    #expect(await backend.submit(.text("z")) == .refused(.backpressure))
    await channel.gate.release()
    let report =
      "\u{1B}[0;1;" + Array(repeating: "120", count: 14).joined(separator: ":")
      + "u"
    #expect(await eventually { channel.writes.withLock { $0.count == 63 } })
    #expect(channel.writes.withLock { $0 } == Array(("k" + report).utf8))
    #expect(await backend.submit(.text("y")) == .accepted(sequence: nil))
    #expect(
      await eventually {
        channel.writes.withLock {
          $0 == Array(("k" + report + "\u{1B}[0;1;121u").utf8)
        }
      }
    )
    await backend.close()
  }

  @Test
  func emptyPasteReleasesItsEncodingReservation() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      writeLimit: 16,
    )
    backend.start()
    let gate = DispatchSemaphore(value: 0)
    session.mutateAsync { _ in gate.wait() }
    #expect(await backend.submit(.paste("")) == .accepted(sequence: nil))
    #expect(await backend.submit(.text("xxxxx")) == .refused(.backpressure))
    gate.signal()
    session.withState { _ in }
    #expect(channel.written.isEmpty)
    #expect(await backend.submit(.text("x")) == .accepted(sequence: nil))
    #expect(await eventually { channel.written == [UInt8(ascii: "x")] })
    await backend.close()
  }

  @Test
  func closeBeforeEncodingDoesNotWriteAcceptedInput() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      writeLimit: 32,
    )
    backend.start()
    let gate = DispatchSemaphore(value: 0)
    session.mutateAsync { _ in gate.wait() }
    #expect(await backend.submit(.text("queued")) == .accepted(sequence: nil))
    await backend.close()
    gate.signal()
    session.withState { _ in }
    #expect(channel.written.isEmpty)
    #expect(await backend.submit(.text("x")) == .refused(.closed))
  }
}
