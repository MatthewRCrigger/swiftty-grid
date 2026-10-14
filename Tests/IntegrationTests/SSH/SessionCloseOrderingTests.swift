import NIOCore
@testable import SSHClient
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SessionCloseOrderingTests {
  @Test
  func closingSFTPReleasesPendingRequestsBeforeAcknowledgement() async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      let client = try await connection.openSFTP()
      server.state.faults.withLock { $0.holdNextRealpathResponse = true }
      let finished = Mutex(false)
      let request = Task {
        defer { finished.withLock { $0 = true } }
        return try await client.realpath(".")
      }
      #expect(
        try await waitUntil {
          server.state.heldSFTPResponse.withLock { $0 != nil }
        }
      )
      server.state.faults.withLock { $0.dropAllServerWrites = true }
      let closing = Task { await client.close() }
      #expect(
        try await waitUntil(timeout: .seconds(1)) { finished.withLock { $0 } }
      )
      await #expect(throws: SFTPError.connectionClosed) {
        _ = try await request.value
      }
      await closing.value
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }

  enum Setup: CaseIterable, Sendable {
    case exec, execEmpty, pty, shell, sftp
    var reply: SessionSetupReply {
      switch self {
      case .exec, .execEmpty: .exec
      case .pty: .pty
      case .shell: .shell
      case .sftp: .sftp
      }
    }
  }

  @Test(arguments: Setup.allCases, [false, true])
  func lateSetupReplyDoesNotWriteAfterClose(
    setup: Setup,
    timeout: Bool,
  ) async throws {
    let server = try await TestSSHServer.start()
    do {
      let connection = try await server.connect()
      let gate = IncomingGateState()
      try await connection.channel.eventLoop
        .submit {
          try connection.channel.pipeline.syncOperations.addHandler(
            HoldIncomingSSH(state: gate),
            position: .first,
          )
        }
        .get()
      // Channel acceptance precedes the gated setup reply. Real encrypted
      // success and close ACK are delivered in TCP order after the public
      // operation has cancelled or timed out.
      server.state.beforeSetupReply.withLock {
        $0 = { reply in
          if reply == setup.reply { gate.enabled.withLock { $0 = true } }
        }
      }
      let request = Task {
        switch setup {
        case .exec, .execEmpty:
          _ = try await connection.execute(
            command: "wait-forever",
            stdin: setup == .execEmpty ? [] : Array("must-not-be-sent".utf8),
            limits: .init(timeout: timeout ? .seconds(1) : .seconds(30)),
          )
        case .pty, .shell:
          _ = try await connection.openShell(
            columns: 80,
            rows: 24,
            setupTimeout: timeout ? .seconds(1) : .seconds(30),
          ) { _ in }
        case .sftp:
          _ = try await connection.openSFTP(
            requestTimeout: timeout ? .seconds(1) : .seconds(30),
          )
        }
      }
      #expect(try await waitUntil { gate.held.withLock { $0 > 0 } })
      if timeout {
        do {
          try await request.value
          Issue.record("Setup unexpectedly completed before its gated reply")
        } catch {
          switch setup.reply {
          case .exec: #expect(error as? SSHClientError == .execTimeout)
          case .pty, .shell:
            #expect(error as? SSHClientError == .channelSetupTimeout)
          case .sftp: #expect(error as? SFTPError == .requestTimedOut)
          }
        }
      } else {
        request.cancel()
        await #expect(throws: CancellationError.self) {
          _ = try await request.value
        }
      }
      let activeBeforeReply = connection.isActive
      #expect(activeBeforeReply)
      try await connection.channel.eventLoop
        .submit {
          let handler = try connection.channel.pipeline.syncOperations.handler(
            type: HoldIncomingSSH.self
          )
          handler.release()
        }
        .get()
      // Drain any parent-close callback scheduled by the SDK error path.
      try await connection.channel.eventLoop.submit {}.get()
      let activeAfterReply = connection.isActive
      #expect(activeAfterReply)
      #expect(!server.state.execStdinFinished.withLock { $0 })
      server.state.beforeSetupReply.withLock { $0 = nil }
      let next = try await connection.openSFTP()
      #expect(next.isActive)
      await next.close()
      await connection.close()
    } catch {
      await server.shutdown()
      throw error
    }
    await server.shutdown()
  }
}

private final class IncomingGateState: Sendable {
  let enabled = Mutex(false)
  let held = Mutex(0)
}

/// Holds real encrypted TCP input on the client's event loop, preserving its
/// order. No SSH messages are fabricated and no production handler is replaced.
private final class HoldIncomingSSH: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let state: IncomingGateState
  var context: ChannelHandlerContext?
  var buffers: [ByteBuffer] = []

  init(state: IncomingGateState) { self.state = state }

  func handlerAdded(context: ChannelHandlerContext) { self.context = context }

  func handlerRemoved(context: ChannelHandlerContext) { self.context = nil }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if state.enabled.withLock({ $0 }) {
      buffers.append(unwrapInboundIn(data))
      state.held.withLock { $0 += 1 }
    } else {
      context.fireChannelRead(data)
    }
  }

  func release() {
    state.enabled.withLock { $0 = false }
    let pending = buffers
    buffers.removeAll()
    for buffer in pending { context?.fireChannelRead(NIOAny(buffer)) }
    context?.fireChannelReadComplete()
  }
}
