#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
@testable import TerminalHost
import TestSupport
import Testing

/// Forces partial writes, EAGAIN, blocking and errors in front of the
/// real PTY, recording exactly what the PTY accepted.
final class ScriptedWriter: PTYWriting, @unchecked Sendable {
  struct Plan {
    var maxChunk = Int.max
    /// Every other call reports EAGAIN.
    var alternateWouldBlock = false
    /// Total bytes accepted before blocking (EAGAIN) until raised.
    var limit: Int?
    var failure: Int32?
  }

  private struct State {
    var plan = Plan()
    var written: [UInt8] = []
    var calls = 0
  }

  private let state = Mutex(State())

  var written: [UInt8] { state.withLock { $0.written } }
  func update(_ change: (inout Plan) -> Void) { state.withLock { change(&$0.plan) } }

  func write(fd: Int32, _ buffer: UnsafeRawBufferPointer) -> PTYWriteResult {
    let decision = state.withLock { s -> (Int?, PTYWriteResult?) in
      s.calls += 1
      if let failure = s.plan.failure { return (nil, .failed(failure)) }
      if s.plan.alternateWouldBlock, s.calls % 2 == 0 { return (nil, .wouldBlock) }
      var allowed = min(s.plan.maxChunk, buffer.count)
      if let limit = s.plan.limit {
        allowed = min(allowed, limit - s.written.count)
      }
      return allowed > 0 ? (allowed, nil) : (nil, .wouldBlock)
    }
    if let result = decision.1 {
      // A blocked writer is retried when the PTY is writable; pace it.
      if result == .wouldBlock { usleep(500) }
      return result
    }
    let count = decision.0!
    let result = DarwinPTYWriter().write(
      fd: fd,
      UnsafeRawBufferPointer(rebasing: buffer.prefix(count))
    )
    if case let .wrote(n) = result {
      state.withLock { $0.written += buffer.prefix(n) }
    }
    return result
  }
}

private func input(
  _ epoch: UInt64,
  _ sequence: UInt64,
  _ operation: InputOperation
) -> ControlMessage {
  .input(.init(attachmentEpoch: epoch, sequence: sequence, operation: operation))
}

/// Printable, newline-free text: its paste encoding is the text itself.
private func pasteText(_ count: Int) -> String {
  let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789-_")
  return String((0 ..< count).map { alphabet[($0 * 7 + $0 / 13) % alphabet.count] })
}

/// A raw-mode program that copies its input to `$HOME/out`.
private let catScript = "stty raw -echo; printf READY; exec cat > \"$HOME/out\""

@Suite(.timeLimit(.minutes(1)))
struct HostInputWriterTests {
  @Test
  func `partial writes and EAGAIN deliver the exact bytes once`() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = ScriptedWriter()
    try await withRegistry(
      launch: { shellLaunch(catScript, in: directory) },
      writer: writer
    ) { registry in
      let grant = try registry.create(grid: GridSize(columns: 80, rows: 24))
      let client = TestClient(registry)
      _ = try await client.attached(grant)
      _ = try await client.snapshot("ready") { screenText($0).contains("READY") }
      writer.update {
        $0.maxChunk = 7
        $0.alternateWouldBlock = true
      }
      let text = pasteText(20_000)
      try await client.send(input(1, 1, .paste(text)))
      _ = try await client.message("ack", timeout: .seconds(30)) {
        if case .inputAck(1, 1) = $0 { return true }
        return false
      }
      #expect(writer.written == Array(text.utf8))
      let out = directory.appendingPathComponent("out")
      try await hostEventually("program received the paste") {
        (try? Data(contentsOf: out)).map(Array.init) == Array(text.utf8)
          ? true : nil
      }
    }
  }

  @Test
  func `a blocked paste is never acknowledged early and resumes its suffix`()
    async throws
  {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let writer = ScriptedWriter()
    try await withRegistry(
      launch: { shellLaunch(catScript, in: directory) },
      writer: writer
    ) { registry in
      let grant = try registry.create(grid: GridSize(columns: 80, rows: 24))
      let session = try #require(registry.session(grant.sessionID))
      let first = TestClient(registry)
      _ = try await first.attached(grant)
      _ = try await first.snapshot("ready") { screenText($0).contains("READY") }
      writer.update {
        $0.maxChunk = 100
        $0.limit = 300
      }
      let text = pasteText(5_000)
      try await first.send(input(1, 1, .paste(text)))
      try await hostEventually("blocked after a prefix") {
        writer.written.count == 300 ? true : nil
      }
      try await Task.sleep(for: .milliseconds(300))
      #expect(!first.inputAck(1))
      #expect(session.diagnostics.partialInputSequence == 1)
      #expect(session.diagnostics.lastAppliedInput == 0)

      // A different writer cannot take over while the paste is incomplete.
      #expect(throws: BootstrapErrorCode.writerBusy) {
        try registry.resume(grant.sessionID)
      }

      first.connection.sever()
      let second = TestClient(registry)
      let attached = try await second.attached(grant)
      #expect(attached.lastFullyAppliedInputSequence == 0)
      #expect(attached.partialInputSequence == 1)
      // Identical retry continues; a conflicting one is refused.
      try await second.send(input(2, 1, .paste(text)))
      try await second.send(input(2, 1, .paste("different")))
      #expect(try await second.errorCode() == .inputConflict)
      #expect(!second.inputAck(1))

      writer.update { $0.limit = nil }
      _ = try await second.message("ack after release", timeout: .seconds(30)) {
        if case .inputAck(2, 1) = $0 { return true }
        return false
      }
      // The accepted prefix was not written again.
      #expect(writer.written == Array(text.utf8))
      let out = directory.appendingPathComponent("out")
      try await hostEventually("program received the paste once") {
        (try? Data(contentsOf: out)).map(Array.init) == Array(text.utf8)
          ? true : nil
      }
      // The same writer may resume now that nothing is pending.
      let resumed = try registry.resume(
        grant.sessionID,
        writerID: grant.writerID
      )
      #expect(resumed.writerID == grant.writerID)
      #expect(resumed.applicationToken != grant.applicationToken)
    }
  }

  @Test
  func `a PTY write error is never acknowledged`() async throws {
    let writer = ScriptedWriter()
    try await withRegistry(writer: writer) { registry in
      let grant = try registry.create(grid: GridSize(columns: 80, rows: 24))
      let session = try #require(registry.session(grant.sessionID))
      let client = TestClient(registry)
      _ = try await client.attached(grant)
      _ = try await client.snapshot("prompt") { screenText($0).contains("$") }
      writer.update { $0.failure = EIO }
      try await client.send(input(1, 1, .committedText("echo never")))
      let reply = try await client.message("error") {
        if case .error = $0 { return true }
        return false
      }
      guard case let .error(error) = reply else { return }
      #expect(error.code == .internalError && error.sequence == 1)
      try await Task.sleep(for: .milliseconds(200))
      #expect(!client.inputAck(1))
      let diagnostics = session.diagnostics
      #expect(diagnostics.writerFailed)
      #expect(diagnostics.lastAppliedInput == 0)
      #expect(diagnostics.partialInputSequence == nil)
      #expect(writer.written.isEmpty)
    }
  }
}
#endif
