#if os(macOS)
import Foundation
@testable import SwifttyCore
@testable import SwifttyEngine
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct RecorderCheckpointTests {
  @Test
  func aPausedReadProducesMatchingCapturedBytesAndText() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("recorder-checkpoint-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = directory.appendingPathComponent("release")
    let program = #"""
      import os,sys,time,tty,threading
      tty.setraw(0)
      def watchdog():
          time.sleep(12)
          os._exit(99)
      threading.Thread(target=watchdog,daemon=True).start()
      while not os.path.exists(sys.argv[1]): time.sleep(0.005)
      data=b'\x1b[>q'*128+b'UNPARSED'
      while data: data=data[os.write(1,data):]
      time.sleep(12)
      """#
    let recorder = try SessionRecorder.Recorder([
      "/usr/bin/python3", "-c", program, gate.path,
    ])
    defer { recorder.session.stop() }
    recorder.session.mutate {
      $0.terminalVersion = String(repeating: "v", count: 4090, )
    }
    try Data().write(to: gate, options: .atomic)
    let deadline = ContinuousClock.now + .seconds(4)
    while !recorder.bytes.withLock({
      String(decoding: $0, as: UTF8.self).contains("UNPARSED")
    }), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(
      recorder.bytes.withLock {
        String(decoding: $0, as: UTF8.self).contains("UNPARSED")
      }
    )
    try #require(!recorder.screen().contains("UNPARSED"))
    let captured = recorder.capture()
    var replay = TerminalState(columns: 80, rows: 24)
    replay.discardsReplies = true
    var parser = Parser()
    parser.consume(captured.data.span, into: &replay)
    let text = (0 ..< replay.rows).map { replay.text(row: $0) }
      .joined(separator: "\n")
    #expect(captured.text == text)
    #expect(captured.text.contains("UNPARSED"))
  }
}
#endif
