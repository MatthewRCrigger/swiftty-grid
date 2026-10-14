#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalPTYReplyPressureTests {
  enum Finish: CaseIterable, Sendable { case drain, exit, close }

  private static let queryProgram = #"""
    import os,sys,time,tty,threading
    tty.setraw(0)
    os.write(1,b'READY\n')
    def queries():
        data=b'\x1b[6n'*int(sys.argv[3])
        while data:
            data=data[os.write(1,data):]
    writer=threading.Thread(target=queries)
    writer.start()
    while not os.path.exists(sys.argv[1]):
        time.sleep(0.005)
    if sys.argv[2]=='exit':
        writer.join()
        os.write(1,b'FINAL\n')
        os._exit(7)
    expected=b'\x1b[2;6R'*int(sys.argv[3])
    offset=0
    while offset<len(expected):
        data=os.read(0,min(len(expected)-offset,65536))
        if not data or data!=expected[offset:offset+len(data)]:
            raise RuntimeError('required reply changed or ended')
        offset+=len(data)
    writer.join()
    os.write(1,b'DRAINED\n')
    while True: time.sleep(1)
    """#

  @Test(arguments: Finish.allCases)
  func queriesPauseReadsAndResumeWithoutLosingReplies(
    finish: Finish,
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pty-replies-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = directory.appendingPathComponent("release")
    let session = TerminalSession(columns: 20, rows: 4)
    let backend = LocalPTYBackend(
      session: session,
      writeLimit: finish == .exit ? 512 : 4096,
    )
    let received = Mutex(0)
    session.onProgramOutput = { bytes in received.withLock { $0 += bytes.count }
    }
    // Keep exit output small enough for its final marker to fit without
    // reading replies. Drain/close use a burst exceeding one PTY read.
    let requests = finish == .exit ? 257 : 50000
    // The main thread can start consuming replies while the writer is
    // blocked. Waiting for every query to be written before reading would
    // deadlock a correctly backpressured PTY in both directions.

    var configuration = SessionConfiguration()
    configuration.command = [
      "/usr/bin/python3", "-u", "-c", Self.queryProgram, gate.path,
      finish == .exit ? "exit" : "drain", String(requests),
    ]
    do {
      try backend.start(configuration)
      #expect(
        await eventually { backend.pendingInputBytes >= backend.writeLimit }
      )
      // A reply-producing read already admitted before the threshold may
      // cross it. DSR produces at most six bytes per four-byte request.
      let maximum = backend.writeLimit + 64 * 1024 * 6 / 4
      #expect(backend.pendingInputBytes <= maximum)
      if finish != .exit {
        #expect(received.withLock { $0 } < 6 + requests * 4)
      }
      let readBefore = session.withState { _ in received.withLock { $0 } }
      #expect(
        await
          !(eventually(.milliseconds(50)) {
            received.withLock { $0 } > readBefore
          })
      )
      #expect(backend.pendingInputBytes <= maximum)
      switch finish {
      case .drain:
        try Data().write(to: gate, options: .atomic)
        #expect(
          await eventually {
            session.withState {
              $0.screenLines.contains { $0.contains("DRAINED") }
            }
          }
        )
        #expect(backend.pendingInputBytes == 0)
        #expect(received.withLock { $0 } == 6 + requests * 4 + 8)
        #expect(backend.lifecycle == .active)
      case .exit:
        try Data().write(to: gate, options: .atomic)
        #expect(await eventually { backend.lifecycle == .exited(7) })
        #expect(
          session.withState { $0.screenLines.contains { $0.contains("FINAL") } }
        )
        #expect(backend.pendingInputBytes == 0)
        #expect(!session.isRunning)
      case .close:
        await backend.close()
        #expect(backend.pendingInputBytes == 0)
        #expect(backend.lifecycle == .closed)
        #expect(!session.isRunning)
      }
    } catch {
      await backend.close()
      throw error
    }
    await backend.close()
    #expect(!session.isRunning)
  }

  @Test
  func coreSessionWithoutBackendAlsoPausesAndDrainsReplies() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pty-core-replies-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = directory.appendingPathComponent("release")
    let session = TerminalSession(columns: 20, rows: 4)
    defer { session.stop() }
    let received = Mutex(0)
    session.onProgramOutput = { bytes in received.withLock { $0 += bytes.count }
    }
    var configuration = SessionConfiguration()
    configuration.command = [
      "/usr/bin/python3", "-u", "-c", Self.queryProgram, gate.path, "drain",
      "50000",
    ]
    try session.start(configuration)
    #expect(await eventually { received.withLock { $0 } >= 44000 })
    let readBefore = session.withState { _ in received.withLock { $0 } }
    #expect(readBefore < 200_006)
    #expect(
      await
        !(eventually(.milliseconds(50)) {
          received.withLock { $0 } > readBefore
        })
    )
    try Data().write(to: gate, options: .atomic)
    #expect(
      await eventually {
        session.withState { $0.screenLines.contains { $0.contains("DRAINED") } }
      }
    )
    #expect(received.withLock { $0 } == 200_014)
    #expect(session.isRunning)
  }

  @Test
  func fullUserInputStillAllowsOutputBeforeChildReadsStdin() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pty-duplex-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = directory.appendingPathComponent("release")
    let session = TerminalSession(columns: 20, rows: 4)
    let backend = LocalPTYBackend(session: session, writeLimit: 4096)
    let refusals = Mutex(0)
    backend.onInputRefusal = { _ in refusals.withLock { $0 += 1 } }
    let received = Mutex(0)
    session.onProgramOutput = { bytes in received.withLock { $0 += bytes.count }
    }
    let program = #"""
      import os,sys,time,tty
      tty.setraw(0)
      os.write(1,b'READY\n')
      while not os.path.exists(sys.argv[1]):
          time.sleep(0.005)
      with open(sys.argv[1]) as f:
          remaining=int(f.read())
      output=b'p'*200000
      while output:
          output=output[os.write(1,output):]
      while remaining:
          data=os.read(0,min(remaining,65536))
          if not data or any(b!=120 for b in data):
              raise RuntimeError('input changed or ended')
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
      #expect(await eventually { received.withLock { $0 } >= 6 })
      #expect(
        await backend.submit(.text(String(repeating: "x", count: 4096)))
          == .refused(.backpressure)
      )
      #expect(backend.pendingInputBytes == 0)
      // Raw user bytes fill the byte budget exactly. Semantic text reserves
      // additional space for keyboard modes that may change before encoding.
      session.send(.bytes([UInt8](repeating: 120, count: 4096)))
      #expect(refusals.withLock { $0 } == 0)
      session.withState { _ in }
      let available = backend.writeLimit - backend.pendingInputBytes
      #expect(available > 0)
      session.send(.bytes([UInt8](repeating: 120, count: available)))
      #expect(refusals.withLock { $0 } == 0)
      session.withState { _ in }
      #expect(backend.pendingInputBytes == backend.writeLimit)
      try Data(String(4096 + available).utf8).write(to: gate, options: .atomic)
      #expect(await eventually { received.withLock { $0 } == 200_014 })
      #expect(backend.pendingInputBytes == 0)
      #expect(
        session.withState { $0.screenLines.contains { $0.contains("DRAINED") } }
      )
      #expect(backend.lifecycle == .active)
    } catch {
      await backend.close()
      throw error
    }
    await backend.close()
  }
}
#endif
