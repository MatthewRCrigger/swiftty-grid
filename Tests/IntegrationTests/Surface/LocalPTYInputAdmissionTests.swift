#if os(macOS) && !targetEnvironment(macCatalyst)
import Dispatch
import Foundation
import SessionCore
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalPTYInputAdmissionTests {
  @Test(arguments: [false, true])
  func secondWrapperCannotReplaceCreditOrStopOwner(active: Bool) async throws {
    let session = TerminalSession(columns: 20, rows: 4)
    let owner = LocalPTYBackend(session: session, writeLimit: 16)
    var configuration = SessionConfiguration()
    configuration.command = ["/bin/cat"]
    if active { try owner.start(configuration) }
    let other = LocalPTYBackend(session: session, writeLimit: 1)
    do {
      try other.start(configuration)
      Issue.record("A second wrapper must not acquire the session's writer")
    } catch let error as LocalPTYBackendError {
      #expect(error == .invalidState(.connecting))
    }
    await other.close()
    if !active { try owner.start(configuration) }
    let refusals = Mutex<[InputRefusal]>([])
    owner.onInputRefusal = { reason in refusals.withLock { $0.append(reason) } }
    session.send(.text("ok"))
    #expect(
      await eventually {
        session.withState { $0.screenLines.contains { $0.contains("ok") } }
      }
    )
    #expect(refusals.withLock { $0.isEmpty })
    #expect(owner.pendingInputBytes == 0)
    #expect(owner.lifecycle == .active && session.isRunning)
    await owner.close()
  }

  @Test(arguments: [false, true])
  func stalledRawChildBoundsInputAndDrainsExactly(native: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pty-admission-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = directory.appendingPathComponent("release")
    let session = TerminalSession(columns: 30, rows: 4)
    let backend = LocalPTYBackend(session: session)
    let refusals = Mutex(0)
    backend.onInputRefusal = { reason in
      #expect(reason == .backpressure)
      refusals.withLock { $0 += 1 }
    }
    let program = #"""
      import os,sys,time,tty
      tty.setraw(0)
      os.write(1,b'READY\n')
      while not os.path.exists(sys.argv[1]):
          time.sleep(0.005)
      with open(sys.argv[1]) as f:
          remaining=int(f.read())
      while remaining:
          data=os.read(0,min(remaining,65536))
          if not data or any(b!=120 for b in data):
              raise RuntimeError('accepted input changed or ended')
          remaining-=len(data)
      os.write(1,b'DRAINED\n')
      while True: time.sleep(1)
      """#
    var configuration = SessionConfiguration()
    configuration.command = [
      "/usr/bin/python3", "-u", "-c", program, gate.path,
    ]
    do {
      try backend.start(configuration)
      #expect(
        await eventually {
          session.withState { $0.screenLines.contains { $0.contains("READY") } }
        }
      )
      var accepted = 0
      for _ in 0 ..< 64 {
        let input = String(repeating: "x", count: 8192)
        if native {
          session.send(.text(input))
        } else {
          switch await backend.submit(.text(input)) {
          case .accepted: accepted += 1
          case .refused(.backpressure): break
          default: Issue.record("Unexpected admission result")
          }
        }
        #expect(backend.pendingInputBytes <= backend.writeLimit)
      }
      if native { accepted = 64 - refusals.withLock { $0 } }
      #expect(accepted > 0 && accepted < 64)
      let expected = accepted * 8192
      try Data(String(expected).utf8).write(to: gate, options: .atomic)
      #expect(
        await eventually {
          session.withState {
            $0.screenLines.contains { $0.contains("DRAINED") }
          }
        }
      )
      #expect(backend.pendingInputBytes == 0)
      #expect(backend.lifecycle == .active)
    } catch {
      await backend.close()
      throw error
    }
    await backend.close()
    #expect(!session.isRunning)
  }

  @Test
  func nativeInputIsReservedBeforeEncodingAndReportedSynchronously()
    async throws
  {
    let session = TerminalSession(columns: 20, rows: 4)
    let backend = LocalPTYBackend(session: session, writeLimit: 88)
    var configuration = SessionConfiguration()
    configuration.command = ["/bin/cat"]
    try backend.start(configuration)
    let refusals = Mutex<[InputRefusal]>([])
    backend.onInputRefusal = { [weak backend] reason in
      #expect(backend?.lifecycle == .active)
      refusals.withLock { $0.append(reason) }
    }
    let gate = DispatchSemaphore(value: 0)
    session.mutateAsync { _ in gate.wait() }
    for _ in 0 ..< 64 { session.send(.text("xxxx")) }
    #expect(backend.pendingInputBytes == 88)
    #expect(
      refusals.withLock { $0 } == Array(repeating: .backpressure, count: 60, )
    )
    gate.signal()
    session.withState { _ in }
    #expect(backend.pendingInputBytes == 0)
    await backend.close()
  }

  @Test
  func emptyEncodingRefundsCreditAndRichKeyboardCannotBypassIt() async throws {
    let session = TerminalSession(columns: 20, rows: 4)
    let backend = LocalPTYBackend(session: session, writeLimit: 128)
    var configuration = SessionConfiguration()
    configuration.command = ["/bin/cat"]
    try backend.start(configuration)
    let refusals = Mutex<[InputRefusal]>([])
    backend.onInputRefusal = { reason in refusals.withLock { $0.append(reason) }
    }
    session.send(.focus(true))
    session.withState { _ in }
    #expect(backend.pendingInputBytes == 0)
    session.feed(Array("\u{1B}[>31u".utf8))
    session.send(
      .key(KeyEvent(.character("x"), text: String(repeating: "x", count: 100), )
      )
    )
    #expect(refusals.withLock { $0 } == [.backpressure])
    #expect(backend.pendingInputBytes == 0)
    session.send(.text("ok"))
    session.withState { _ in }
    #expect(backend.pendingInputBytes == 0)
    await backend.close()
  }

  @Test
  func closeInvalidatesInputAlreadyQueuedForEncoding() async throws {
    let session = TerminalSession(columns: 20, rows: 4)
    let backend = LocalPTYBackend(session: session, writeLimit: 22)
    var configuration = SessionConfiguration()
    configuration.command = ["/bin/cat"]
    try backend.start(configuration)
    let gate = DispatchSemaphore(value: 0)
    session.mutateAsync { _ in gate.wait() }
    #expect(await backend.submit(.text("xxxx")) == .accepted(sequence: nil))
    let closing = Task { await backend.close() }
    #expect(
      await eventually {
        backend.lifecycle == .closed && backend.pendingInputBytes == 0
      }
    )
    gate.signal()
    await closing.value
    #expect(backend.pendingInputBytes == 0)
    #expect(!session.isRunning)
    #expect(await backend.submit(.text("late")) == .refused(.closed))
  }
}
#endif
