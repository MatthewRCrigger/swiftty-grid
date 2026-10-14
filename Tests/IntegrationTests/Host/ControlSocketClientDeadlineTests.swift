#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import Synchronization
import Testing

@testable import TerminalHost

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ControlSocketClientDeadlineTests {
  private func socketPair() throws -> [Int32] {
    var sockets: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    do {
      for fd in sockets {
        try #require(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0)
        try setTimeouts(fd, .seconds(1))
      }
    } catch {
      for fd in sockets { close(fd) }
      throw error
    }
    return sockets
  }

  @Test(arguments: [false, true])
  func partialPrefixOrBodyProgressCannotExtendTheClientBudget(
    _ body: Bool
  ) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let response = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let writes = Mutex(0)
    let peer = try ControlDeadlinePeer(directory: directory) { fd in
      try #require(fcntl(fd, F_GETFL) & O_NONBLOCK == 0)
      _ = try readEnvelope(fd)
      let bytes: [UInt8]
      if body {
        guard writeAll(fd, Array(response.prefix(4))) else { return }
        bytes = Array(response.dropFirst(4))
      } else {
        bytes = response
      }
      for byte in bytes {
        guard writeAll(fd, [byte]) else { return }
        writes.withLock { $0 += 1 }
        Thread.sleep(forTimeInterval: 0.07)
      }
    }
    defer { peer.stop() }
    let request = try BootstrapEnvelope.encode(
      BootstrapRequest(operation: .list)
    )
    let start = ContinuousClock.now
    #expect(throws: ControlSocketError.timedOut) {
      try ControlSocketClient.exchange(
        path: peer.path,
        envelope: request,
        timeout: .milliseconds(300)
      )
    }
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(writes.withLock { $0 } >= 2)
  }

  @Test
  func responseBodyReceivesOnlyTheBudgetLeftAfterItsPrefix() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let response = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let prefixSent = Mutex(false)
    let peer = try ControlDeadlinePeer(directory: directory) { fd in
      _ = try readEnvelope(fd)
      Thread.sleep(forTimeInterval: 0.15)
      guard writeAll(fd, Array(response.prefix(4))) else { return }
      prefixSent.withLock { $0 = true }
      Thread.sleep(forTimeInterval: 0.30)
      _ = writeAll(fd, Array(response.dropFirst(4)))
    }
    defer { peer.stop() }
    let request = try BootstrapEnvelope.encode(
      BootstrapRequest(operation: .list)
    )
    #expect(throws: ControlSocketError.timedOut) {
      try ControlSocketClient.exchange(
        path: peer.path,
        envelope: request,
        timeout: .milliseconds(350)
      )
    }
    #expect(prefixSent.withLock { $0 })
  }

  @Test
  func partialWritesStopAtTheSharedDeadlineAndKeepTheDescriptorOwned() throws {
    let sockets = try socketPair()
    defer { for fd in sockets { close(fd) } }
    let client = sockets[0]
    let peer = sockets[1]
    var sendBuffer: Int32 = 4096
    try #require(
      setsockopt(
        client,
        SOL_SOCKET,
        SO_SNDBUF,
        &sendBuffer,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0
    )
    let drained = Mutex(0)
    let completion = DispatchGroup()
    completion.enter()
    DispatchQueue.global(qos: .userInitiated)
      .async {
        defer { completion.leave() }
        let deadline = ContinuousClock.now + .seconds(2)
        var bytes = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
          let count = bytes.withUnsafeMutableBytes {
            read(peer, $0.baseAddress, $0.count)
          }
          guard count > 0 else { return }
          drained.withLock { $0 += count }
          Thread.sleep(forTimeInterval: 0.06)
        }
      }
    defer {
      shutdown(client, SHUT_RDWR)
      completion.wait()
    }
    let io = try ControlSocketClientIO(
      fd: client,
      timeout: .milliseconds(300),
      started: .now
    )
    let start = ContinuousClock.now
    #expect(throws: ControlSocketError.timedOut) {
      try io.write(Array(repeating: 7, count: 1024 * 1024))
    }
    #expect(start.duration(to: .now) < .seconds(1))
    #expect(drained.withLock { $0 } > 0)
    #expect(fcntl(client, F_GETFD) >= 0)
  }

  @Test
  func anExpiredBudgetCannotStartAConnectionOrEmptyWrite() throws {
    let sockets = try socketPair()
    defer { for fd in sockets { close(fd) } }
    let io = try ControlSocketClientIO(
      fd: sockets[0],
      timeout: .milliseconds(1),
      started: .now - .seconds(1)
    )
    var address = try ControlSocketServer.address(
      "/private/nonexistent-control.sock"
    )
    #expect(throws: ControlSocketError.timedOut) {
      try io.connect(to: &address)
    }
    #expect(throws: ControlSocketError.timedOut) { try io.write([]) }
    #expect(throws: ControlSocketError.timedOut) { try io.readEnvelope() }
    #expect(fcntl(sockets[0], F_GETFD) >= 0)
    // No absolute instant addition or milliseconds multiplication overflows.
    let long = try ControlSocketClientIO(
      fd: sockets[0],
      timeout: .seconds(Int64.max),
      started: .now
    )
    try long.write([])
  }

  @Test(arguments: [false, true])
  func rejectedResponseFramingRemainsAPeerFailure(_ oversized: Bool) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let peer = try ControlDeadlinePeer(directory: directory) { fd in
      _ = try readEnvelope(fd)
      _ = writeAll(fd, oversized ? [0, 0x10, 0, 1] : [0, 0])
    }
    defer { peer.stop() }
    let request = try BootstrapEnvelope.encode(
      BootstrapRequest(operation: .list)
    )
    #expect(throws: ControlSocketError.peerRejected) {
      try ControlSocketClient.exchange(
        path: peer.path,
        envelope: request,
        timeout: .seconds(1)
      )
    }
  }

  @Test
  func fullListenQueueStillFailsPromptlyWithItsConnectError() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let peer = try ControlDeadlinePeer(directory: directory, backlog: 1)
    defer { peer.stop() }
    let filler = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(filler >= 0)
    defer { close(filler) }
    try #require(fcntl(filler, F_SETFD, FD_CLOEXEC) == 0)
    let io = try ControlSocketClientIO(
      fd: filler,
      timeout: .seconds(1),
      started: .now
    )
    var address = try ControlSocketServer.address(peer.path)
    try io.connect(to: &address)
    let request = try BootstrapEnvelope.encode(
      BootstrapRequest(operation: .list)
    )
    let start = ContinuousClock.now
    #expect(throws: ControlSocketError.system("connect", ECONNREFUSED)) {
      try ControlSocketClient.exchange(
        path: peer.path,
        envelope: request,
        timeout: .milliseconds(500)
      )
    }
    #expect(start.duration(to: .now) < .seconds(1))
  }

  @Test
  func helperMapsAnElapsedClientDeadlineToAnUnavailableEnvelope() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let peer = try ControlDeadlinePeer(directory: directory) { fd in
      _ = try readEnvelope(fd)
      Thread.sleep(forTimeInterval: 0.40)
    }
    defer { peer.stop() }
    let request = try BootstrapEnvelope.encode(
      BootstrapRequest(operation: .list)
    )
    let response = BootstrapService.forward(
      envelope: request,
      socketPath: peer.path,
      timeout: .milliseconds(150)
    )
    #expect(
      try BootstrapEnvelope.decode(BootstrapResponse.self, from: response)
        == .failure(.agentUnavailable)
    )
  }
}
#endif
