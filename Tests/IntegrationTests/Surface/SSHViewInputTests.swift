import Dispatch
import SessionCore
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SSHViewInputTests {
  @Test
  func queuedModeChangeUsesReservedRichTextAndInvalidTextRefundsCredit() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      writeLimit: 20
    )
    let refusals = Mutex<[InputRefusal]>([])
    backend.onInputRefusal = { reason in refusals.withLock { $0.append(reason) }
    }
    backend.start()
    let gate = DispatchSemaphore(value: 0)
    session.mutateAsync { _ in gate.wait() }
    session.receive(Array("\u{1B}[>24u".utf8))
    session.send(.text("漢"))
    session.send(.text("漢"))
    #expect(refusals.withLock { $0 } == [.backpressure])
    gate.signal()
    #expect(
      await eventually { channel.written == Array("\u{1B}[0;1;28450u".utf8) }
    )
    // A later writer operation proves the first write has retired its credit.
    await backend.proposeGrid(columns: 21, rows: 4)
    #expect(await eventually { channel.resizes.last?.columns == 21 })
    session.send(.text("a\u{1B}"))
    session.withState { _ in }
    session.send(.text("字"))
    #expect(
      await eventually {
        channel.written == Array("\u{1B}[0;1;28450u\u{1B}[0;1;23383u".utf8)
      }
    )
    #expect(refusals.withLock { $0 } == [.backpressure])
    await backend.close()
  }

  /// A refused focus report is dropped silently; typed input still
  /// reports its refusal.
  @Test
  func refusedFocusReportsRaiseNoRefusal() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(channel: channel, session: session)
    let refusals = Mutex<[InputRefusal]>([])
    backend.onInputRefusal = { reason in refusals.withLock { $0.append(reason) }
    }
    backend.start()
    await backend.close()
    session.send(.focus(false))
    #expect(refusals.withLock { $0 }.isEmpty)
    session.send(.text("x"))
    #expect(refusals.withLock { $0 } == [.closed])
  }

  @Test
  func viewInputIsAdmittedBeforeSessionQueue() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      writeLimit: 88,
    )
    let refusals = Mutex<[InputRefusal]>([])
    backend.onInputRefusal = { reason in refusals.withLock { $0.append(reason) }
    }
    backend.start()
    let gate = DispatchSemaphore(value: 0)
    session.mutateAsync { _ in gate.wait() }
    for _ in 0 ..< 64 { session.send(.text("xxxx")) }
    #expect(
      refusals.withLock { $0 } == Array(repeating: .backpressure, count: 60, )
    )
    gate.signal()
    session.withState { _ in }
    #expect(await eventually { channel.written.count >= 16 })
    #expect(channel.written.count == 16)
    #expect(
      await !(eventually(.milliseconds(50)) { channel.written.count > 16 })
    )
    await backend.close()
  }

  @Test
  func richKeyboardTextCannotBypassReservation() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      writeLimit: 128,
    )
    let refusals = Mutex<[InputRefusal]>([])
    backend.onInputRefusal = { reason in refusals.withLock { $0.append(reason) }
    }
    backend.start()
    session.feed(Array("\u{1B}[>31u".utf8))
    #expect(session.keyboardFlags == 31)
    session.send(
      .key(KeyEvent(.character("x"), text: String(repeating: "x", count: 100), )
      )
    )
    session.withState { _ in }
    #expect(refusals.withLock { $0 } == [.backpressure])
    #expect(channel.written.isEmpty)
    session.send(.key(KeyEvent(.character("x"), text: "x")))
    #expect(
      await eventually { channel.written == Array("\u{1B}[120;1;120u".utf8) }
    )
    await backend.close()
  }

  @Test
  func disabledFocusReportRefundsReservation() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(
      channel: channel,
      session: session,
      writeLimit: 3,
    )
    let refusals = Mutex<[InputRefusal]>([])
    backend.onInputRefusal = { reason in refusals.withLock { $0.append(reason) }
    }
    backend.start()
    session.send(.text(""))
    session.send(.bytes([]))
    session.send(.focus(true))
    session.withState { _ in }
    session.send(.bytes(Array("abc".utf8)))
    #expect(await eventually { channel.written == Array("abc".utf8) })
    #expect(refusals.withLock { $0.isEmpty })
    await backend.close()
  }

  @Test
  func closedSessionRefusesDirectViewInput() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(channel: channel, session: session)
    let refusals = Mutex<[InputRefusal]>([])
    backend.onInputRefusal = { reason in refusals.withLock { $0.append(reason) }
    }
    backend.start()
    await backend.close()
    session.send(.text("x"))
    #expect(refusals.withLock { $0 } == [.closed])
    session.withState { _ in }
    #expect(channel.written.isEmpty)
  }

  @Test
  func viewModesAndRawInputUseSameOrderedWriter() async {
    let session = TerminalSession(columns: 20, rows: 4)
    let channel = FakeByteChannel()
    let backend = SSHStreamBackend(channel: channel, session: session)
    backend.start()
    session.feed(
      Array("\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?1000h\u{1B}[?1006h".utf8)
    )
    session.send(.text("é"))
    session.send(.paste("p"))
    session.send(.key(KeyEvent(.up)))
    session.send(.mouse(MouseEvent(.press, .left, column: 1, row: 2)))
    session.send(.focus(true))
    session.send(.bytes(Array("raw".utf8)))
    let expected = Array(
      "é\u{1B}[200~p\u{1B}[201~\u{1B}[A\u{1B}[<0;2;3M\u{1B}[Iraw".utf8,
    )
    #expect(await eventually { channel.written == expected })
    await backend.close()
  }
}
