#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import SwifttyCore
import Synchronization
import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalPTYAmplifiedReplyTests {
  private static let program = #"""
    import os,sys,time,tty,select,threading
    tty.setraw(0)
    gate,result,mode=sys.argv[1:]
    def watchdog():
        time.sleep(12)
        os._exit(99)
    threading.Thread(target=watchdog,daemon=True).start()
    os.write(1,b'READY\n')
    data=b'\x1b[>q'*128
    while data: data=data[os.write(1,data):]
    while not os.path.exists(gate): time.sleep(0.005)
    if mode=='drain':
        expected=(b'\x1bP>|'+b'v'*4090+b'\x1b\\')*128
        offset=0
        deadline=time.monotonic()+4
        while offset<len(expected):
            remaining=deadline-time.monotonic()
            if remaining<=0 or not select.select([0],[],[],remaining)[0]: break
            data=os.read(0,min(65536,len(expected)-offset))
            if not data or data!=expected[offset:offset+len(data)]: break
            offset+=len(data)
        with open(result,'w') as f: f.write('MATCH' if offset==len(expected) else 'MISSING:'+str(offset))
    os.write(1,b'FINAL\n')
    os._exit(7)
    """#

  @Test(arguments: [4096, 65536], ["drain", "exit", "close"])
  func amplifiedQueriesHoldAtMostOneReplyBeyondTheWriteLimit(
    limit: Int,
    mode: String,
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pty-amplified-replies-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = directory.appendingPathComponent("release")
    let result = directory.appendingPathComponent("result")
    let session = TerminalSession(columns: 20, rows: 4)
    let recorded = Mutex<[UInt8]>([])
    session.onProgramOutput = { bytes in
      recorded.withLock { $0.append(contentsOf: bytes) }
    }
    session.mutate { $0.terminalVersion = String(repeating: "v", count: 4090) }
    let backend = LocalPTYBackend(session: session, writeLimit: limit)
    var configuration = SessionConfiguration()
    configuration.command = [
      "/usr/bin/python3", "-u", "-c", Self.program, gate.path, result.path,
      mode,
    ]
    do {
      try backend.start(configuration)
      let ready = ContinuousClock.now + .seconds(4)
      while backend.pendingInputBytes <= limit, ContinuousClock.now < ready {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(backend.pendingInputBytes > limit)
      #expect(backend.pendingInputBytes <= limit + 4096)
      try await Task.sleep(for: .milliseconds(100))
      #expect(backend.pendingInputBytes <= limit + 4096)
      if mode == "close" {
        await backend.close()
        #expect(backend.lifecycle == .closed)
      } else {
        try Data().write(to: gate, options: .atomic)
        let deadline = ContinuousClock.now + .seconds(6)
        while backend.lifecycle != .exited(7), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backend.lifecycle == .exited(7))
        #expect(
          session.withState { $0.screenLines.contains { $0.contains("FINAL") } }
        )
        let expectedOutput =
          "READY\n" + String(repeating: "\u{1b}[>q", count: 128, ) + "FINAL\n"
        #expect(recorded.withLock { $0 } == Array(expectedOutput.utf8))
        if mode == "drain" {
          #expect(try String(contentsOf: result, encoding: .utf8) == "MATCH")
        }
      }
      #expect(backend.pendingInputBytes == 0)
      #expect(!session.isRunning)
    } catch {
      await backend.close()
      throw error
    }
    await backend.close()
  }
}
#endif
