#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
@testable import TerminalHost
import TestSupport
import Testing

private func envelope(_ request: BootstrapRequest) throws -> [UInt8] {
  try BootstrapEnvelope.encode(request)
}

private func response(_ bytes: [UInt8]) throws -> BootstrapResponse {
  try BootstrapEnvelope.decode(BootstrapResponse.self, from: bytes)
}

@Suite(.timeLimit(.minutes(1)))
struct ControlSocketTests {
  final class HandlerGate: Sendable {
    let waiting = Mutex<
      (released: Bool, continuation: CheckedContinuation<Void, Never>?)
    >((false, nil))
    let cancelled = Mutex(false)
    let finished = Mutex(false)

    func suspend() async {
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          let released = waiting.withLock { value in
            guard !value.released else { return true }
            value.continuation = continuation
            return false
          }
          if released { continuation.resume() }
        }
      } onCancel: {
        self.cancelled.withLock { $0 = true }
      }
      finished.withLock { $0 = true }
    }

    func release() {
      let continuation = waiting.withLock { value in
        value.released = true
        defer { value.continuation = nil }
        return value.continuation
      }
      continuation?.resume()
    }
  }

  private func connectToControl(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    var transferred = false
    defer { if !transferred { close(fd) } }
    try #require(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0)
    try setTimeouts(fd, .milliseconds(100))
    var address = try ControlSocketServer.address(path)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(result == 0)
    transferred = true
    return fd
  }

  private func peerClosed(_ fd: Int32) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(500)
    while ContinuousClock.now < deadline {
      var byte: UInt8 = 0
      let count = recv(fd, &byte, 1, MSG_DONTWAIT)
      if count == 0 || (count < 0 && errno == ECONNRESET) { return true }
      if count > 0 { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  @Test
  func stopClosesAcceptedReadsAndCancelsSuspendedHandlers() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = HandlerGate()
    defer { gate.release() }
    let reply = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let calls = Mutex(0)
    let server = try ControlSocketServer(directory: directory) { _ in
      let first = calls.withLock { value in
        defer { value += 1 }
        return value == 0
      }
      if first { await gate.suspend() }
      return reply
    }
    try server.start()
    defer { server.stop() }
    let partial = try connectToControl(server.path)
    defer { close(partial) }
    #expect(writeAll(partial, [0]))
    let complete = try connectToControl(server.path)
    defer { close(complete) }
    #expect(
      writeAll(complete, try envelope(BootstrapRequest(operation: .list)))
    )
    try await hostEventually("suspended control handler") {
      gate.waiting.withLock { $0.continuation != nil } ? true : nil
    }
    server.stop()
    #expect(await peerClosed(partial))
    #expect(await peerClosed(complete))
    #expect(gate.cancelled.withLock { $0 })
    // The old handler deliberately ignores cancellation until released.
    // Restart must serve new work without waiting for it.
    try server.start()
    #expect(
      try ControlSocketClient.exchange(
        path: server.path,
        envelope: envelope(BootstrapRequest(operation: .list)),
        timeout: .seconds(1)
      ) == reply
    )
    gate.release()
    try await hostEventually("released control handler") {
      gate.finished.withLock { $0 } ? true : nil
    }
  }

  @Test(arguments: [false, true])
  func exchangeDeadlineCannotBeExtendedByProgressOrAStalledHandler(
    _ stall: Bool
  ) async throws { try await checkExchangeDeadline(stall: stall) }

  @Test
  func stalledHandlerRequestDoesNotWaitForAScheduledSender() async throws {
    try await checkExchangeDeadline(stall: true, delayScheduledSender: true)
  }

  private func startDeadlineSender(
    fd: Int32,
    bytes: [UInt8],
    stall: Bool,
    delayScheduledSender: Bool
  ) -> Task<Void, Never>? {
    if stall {
      // The handler case needs a complete request before its short exchange
      // deadline; do not make admission depend on another task being run.
      let written = writeAll(fd, bytes)
      let writeError = errno
      #expect(written, "request write failed, errno \(writeError)")
      return nil
    }
    return Task {
      // Model a sender task that cannot run until after exchange expiry.
      if delayScheduledSender { #expect(await peerClosed(fd)) }
      for byte in bytes {
        guard !Task.isCancelled, writeAll(fd, [byte]) else { return }
        do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
      }
    }
  }

  private func checkExchangeDeadline(
    stall: Bool,
    delayScheduledSender: Bool = false
  ) async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let gate = HandlerGate()
    defer { gate.release() }
    let reply = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let server = try ControlSocketServer(
      directory: directory,
      ioTimeout: .milliseconds(200)
    ) { _ in
      await gate.suspend()
      return reply
    }
    try server.start()
    defer { server.stop() }
    let fd = try connectToControl(server.path)
    defer { close(fd) }
    let bytes = try envelope(BootstrapRequest(operation: .list))
    let sender = startDeadlineSender(
      fd: fd,
      bytes: bytes,
      stall: stall,
      delayScheduledSender: delayScheduledSender
    )
    do {
      if stall {
        try await hostEventually(
          "deadline handler admission",
          timeout: .seconds(1)
        ) { gate.waiting.withLock { $0.continuation != nil } ? true : nil }
      }
      let completionDeadline = ContinuousClock.now + .milliseconds(500)
      #expect(await peerClosed(fd))
      if stall {
        // Expiry shuts down I/O before cancelling the handler outside
        // the socket lock. Share the existing EOF observation budget;
        // peer EOF does not order that later callback.
        try await hostEventually(
          "expired handler cancellation",
          timeout: max(.zero, completionDeadline - ContinuousClock.now)
        ) { gate.cancelled.withLock { $0 } ? true : nil }
      }
    } catch {
      sender?.cancel()
      await sender?.value
      throw error
    }
    sender?.cancel()
    await sender?.value
    gate.release()
    if stall {
      try await hostEventually("expired handler cleanup") {
        gate.finished.withLock { $0 } ? true : nil
      }
    }
  }

  enum AdmissionPhase: Sendable { case active, expired, restarted }

  @Test(arguments: [AdmissionPhase.active, .expired, .restarted])
  func cancelledHandlersRetainAdmissionUntilTheyFinish(
    _ phase: AdmissionPhase
  ) async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let capacity = 32
    let gates = (0 ..< capacity).map { _ in HandlerGate() }
    defer { for gate in gates { gate.release() } }
    let calls = Mutex(0)
    let reply = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let server = try ControlSocketServer(
      directory: directory,
      ioTimeout: phase == .expired ? .seconds(1) : .seconds(10)
    ) { _ in
      let index = calls.withLock { value in
        defer { value += 1 }
        return value
      }
      if index < gates.count { await gates[index].suspend() }
      return reply
    }
    try server.start()
    defer { server.stop() }
    var clients: [Int32] = []
    defer { for fd in clients { close(fd) } }
    let request = try envelope(BootstrapRequest(operation: .list))
    for index in 0 ..< capacity {
      let fd = try connectToControl(server.path)
      clients.append(fd)
      try #require(writeAll(fd, request))
      // Wait for acceptance before the next connect, keeping the kernel's
      // smaller listen backlog out of this application admission test.
      try await hostEventually("admitted handler \(index)") {
        gates[index].waiting.withLock { $0.continuation != nil } ? true : nil
      }
    }
    try await hostEventually("all admitted handlers") {
      gates.allSatisfy { $0.waiting.withLock { $0.continuation != nil } }
        ? true : nil
    }
    switch phase {
    case .active: break
    case .expired:
      try await hostEventually("all expired handlers", timeout: .seconds(2)) {
        gates.allSatisfy { $0.cancelled.withLock { $0 } } ? true : nil
      }
    case .restarted:
      server.stop()
      try server.start()
    }
    let excess = try connectToControl(server.path)
    clients.append(excess)
    // A connection over the limit can be closed before its request is sent.
    _ = writeAll(excess, request)
    #expect(await peerClosed(excess))
    #expect(calls.withLock { $0 } == capacity)
    gates[0].release()
    // Handler completion precedes exchange cleanup by a few instructions.
    // Observe recovery through real requests with a finite polling budget.
    let recovered = try await hostEventually(
      "admission capacity recovery",
      timeout: .seconds(2)
    ) {
      try? ControlSocketClient.exchange(
        path: server.path,
        envelope: request,
        timeout: .milliseconds(100)
      )
    }
    #expect(recovered == reply)
    #expect(calls.withLock { $0 } == capacity + 1)
    #expect(gates.dropFirst().allSatisfy { !$0.finished.withLock { $0 } })
  }

  @Test
  func ownershipReleaseDoesNotWaitForDeallocation() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("control.sock").path
    var first: ControlSocketOwnership? = try ControlSocketOwnership(path: path)
    first?.release()
    let second = try ControlSocketOwnership(path: path)
    defer { second.release() }
    // Deallocating the released owner must not close the replacement's fd,
    // even when the kernel reuses the descriptor number.
    first = nil
    #expect(throws: ControlSocketError.system("flock", EWOULDBLOCK)) {
      try ControlSocketOwnership(path: path)
    }
  }

  @Test
  func concurrentInstancesHaveOneSocketOwner() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reply = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let servers = try (0 ..< 16)
      .map { _ in try ControlSocketServer(directory: directory) { _ in reply } }
    defer { for server in servers { server.stop() } }
    let winners = Mutex<[Int]>([])
    let unexpected = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: servers.count) { index in
      do {
        try servers[index].start()
        winners.withLock { $0.append(index) }
      } catch {
        if let socketError = error as? ControlSocketError,
          case .system("flock", EWOULDBLOCK) = socketError
        {
        } else {
          unexpected.withLock { $0.append("\(error)") }
        }
      }
    }
    let started = winners.withLock { $0 }
    try #require(started.count == 1)
    #expect(unexpected.withLock { $0 }.isEmpty)
    let winner = started[0]
    for (index, server) in servers.enumerated() where index != winner {
      server.stop()
    }
    #expect(
      try response(
        ControlSocketClient.exchange(
          path: servers[winner].path,
          envelope: envelope(BootstrapRequest(operation: .list)),
          timeout: .seconds(1)
        )
      ) == .sessions([])
    )
    servers[winner].stop()
    try servers[(winner + 1) % servers.count].start()
  }

  @Test(arguments: [false, true])
  func socketOwnershipRejectsUnsafeLockFiles(_ symlink: Bool) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try ControlSocketServer(directory: directory) { $0 }
    defer { server.stop() }
    let lock = URL(fileURLWithPath: server.path + ".lock")
    let protected = directory.appendingPathComponent("protected")
    try Data("keep".utf8).write(to: protected)
    if symlink {
      try FileManager.default.createSymbolicLink(
        at: lock,
        withDestinationURL: protected
      )
    } else {
      try Data().write(to: lock)
      try #require(chmod(lock.path, 0o644) == 0)
    }
    #expect(throws: (any Error).self) { try server.start() }
    #expect(try String(contentsOf: protected, encoding: .utf8) == "keep")
    var info = stat()
    #expect(lstat(server.path, &info) == -1 && errno == ENOENT)
  }

  @Test
  func competingInstancesCannotReplaceTheLiveSocket() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reply = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let first = try ControlSocketServer(directory: directory) { _ in reply }
    let second = try ControlSocketServer(directory: directory) { _ in reply }
    defer {
      first.stop();
      second.stop()
    }
    try first.start()
    #expect(throws: (any Error).self) { try second.start() }
    #expect(
      try response(
        ControlSocketClient.exchange(
          path: first.path,
          envelope: envelope(BootstrapRequest(operation: .list)),
          timeout: .seconds(1)
        )
      ) == .sessions([])
    )
    first.stop()
    try second.start()
    first.stop()
    #expect(
      try response(
        ControlSocketClient.exchange(
          path: second.path,
          envelope: envelope(BootstrapRequest(operation: .list)),
          timeout: .seconds(1)
        )
      ) == .sessions([])
    )
    // A nonparticipating actor may replace a path. Stop must preserve it.
    try #require(unlink(second.path) == 0)
    let replacement = directory.appendingPathComponent("control.sock")
    try Data("keep".utf8).write(to: replacement)
    second.stop()
    #expect(try String(contentsOf: replacement, encoding: .utf8) == "keep")
  }

  @Test(arguments: [false, true])
  func existingSocketMustBeStaleBeforeReplacement(_ live: Bool) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try ControlSocketServer(directory: directory) { $0 }
    defer { server.stop() }
    var fd = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { if fd >= 0 { close(fd) } }
    var address = try ControlSocketServer.address(server.path)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(bound == 0)
    try #require(chmod(server.path, 0o600) == 0)
    if live {
      try #require(listen(fd, 1) == 0)
      #expect(throws: (any Error).self) { try server.start() }
    } else {
      close(fd)
      fd = -1
      try server.start()
      var info = stat()
      #expect(
        lstat(server.path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK
      )
    }
  }

  @Test(arguments: [1, 16])
  func repeatedStartsKeepTheExistingListener(_ callers: Int) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reply = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let server = try ControlSocketServer(directory: directory) { _ in reply }
    try server.start()
    defer { server.stop() }
    var original = stat()
    try #require(lstat(server.path, &original) == 0)
    // Keep the original filesystem inode alive even if a broken repeated
    // start unlinks the path, preventing accidental inode reuse.
    try #require(
      link(server.path, directory.appendingPathComponent("original.sock").path)
        == 0
    )
    let errors = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: callers) { _ in
      do { try server.start() } catch {
        errors.withLock { $0.append("\(error)") }
      }
    }
    #expect(errors.withLock { $0 }.isEmpty)
    var current = stat()
    try #require(lstat(server.path, &current) == 0)
    #expect(current.st_ino == original.st_ino)
    #expect(
      try response(
        ControlSocketClient.exchange(
          path: server.path,
          envelope: envelope(BootstrapRequest(operation: .list)),
          timeout: .seconds(1)
        )
      ) == .sessions([])
    )
    server.stop()
    #expect(lstat(server.path, &current) == -1 && errno == ENOENT)
    try server.start()
    #expect(
      try response(
        ControlSocketClient.exchange(
          path: server.path,
          envelope: envelope(BootstrapRequest(operation: .list)),
          timeout: .seconds(1)
        )
      ) == .sessions([])
    )
  }

  @Test
  func concurrentStopAndRestartKeepsTheFinalSocketAvailable() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reply = try BootstrapEnvelope.encode(BootstrapResponse.sessions([]))
    let server = try ControlSocketServer(directory: directory) { _ in reply }
    defer { server.stop() }
    let errors = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      for _ in 0 ..< 20 {
        server.stop()
        do { try server.start() } catch {
          errors.withLock { $0.append("\(error)") }
        }
      }
    }
    #expect(errors.withLock { $0 }.isEmpty)
    try server.start()
    #expect(
      try response(
        ControlSocketClient.exchange(
          path: server.path,
          envelope: envelope(BootstrapRequest(operation: .list)),
          timeout: .seconds(1)
        )
      ) == .sessions([])
    )
  }

  @Test(arguments: [
    Duration.zero, .seconds(-1), .nanoseconds(-1),
    Duration(
      secondsComponent: Int64.max,
      attosecondsComponent: 999_999_999_999_999_999
    ),
  ])
  func invalidSocketTimeoutsAreRejected(_ timeout: Duration) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(throws: ControlSocketError.invalidTimeout) {
      try ControlSocketServer(directory: directory, ioTimeout: timeout) { $0 }
    }
    #expect(throws: ControlSocketError.invalidTimeout) {
      try ControlSocketClient.exchange(
        path: directory.appendingPathComponent("absent.sock").path,
        envelope: [],
        timeout: timeout
      )
    }
  }

  @Test
  func socketOptionErrorsAreReported() throws {
    #expect(throws: ControlSocketError.system("setsockopt SO_RCVTIMEO", EBADF))
    { try setTimeouts(-1, .seconds(1)) }
  }

  @Test
  func fractionalTimeoutCannotDisableSocketDeadlines() async throws {
    var fds: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer {
      close(fds[0]);
      close(fds[1])
    }
    try setTimeouts(fds[0], .nanoseconds(1))
    for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
      var value = timeval()
      var length = socklen_t(MemoryLayout<timeval>.size)
      try #require(getsockopt(fds[0], SOL_SOCKET, option, &value, &length) == 0)
      #expect(value.tv_sec > 0 || value.tv_usec > 0)
    }
    let peer = fds[1]
    let fallback = Task.detached {
      try? await Task.sleep(for: .milliseconds(500))
      if !Task.isCancelled { shutdown(peer, SHUT_RDWR) }
    }
    let start = ContinuousClock.now
    #expect(throws: FramingError.truncated) { try readEnvelope(fds[0]) }
    let elapsed = start.duration(to: .now)
    fallback.cancel()
    await fallback.value
    #expect(elapsed < .milliseconds(250))
  }

  @Test
  func `bootstrap envelope round trip over the control socket`() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try ControlDirectory.prepare(directory)
    let registry = SessionRegistry(
      service: try makeService(),
      identity: testIdentity()
    )
    let service = BootstrapService(registry: registry)
    let server = try ControlSocketServer(directory: directory) {
      await service.respond(toEnvelope: $0)
    }
    try server.start()
    defer { server.stop() }

    var info = stat()
    #expect(lstat(server.path, &info) == 0)
    #expect(info.st_mode & S_IFMT == S_IFSOCK)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(info.st_uid == getuid())
    #expect(lstat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)

    let request = BootstrapRequest(
      operation: .create,
      initialGrid: GridSize(columns: 100, rows: 30)
    )
    let reply = try response(
      BootstrapService.forward(
        envelope: try envelope(request),
        socketPath: server.path
      )
    )
    guard case let .granted(grant) = reply else {
      Issue.record("expected a grant, got \(reply)")
      return
    }
    #expect(grant.endpoint == testIdentity().endpoint)
    #expect(
      grant.serverCertificateSHA256 == testIdentity().certificate.sha256Hex
    )
    #expect(grant.initialGrid == GridSize(columns: 100, rows: 30))
    #expect((try await registry.list()).count == 1)

    let listed = try response(
      BootstrapService.forward(
        envelope: try envelope(BootstrapRequest(operation: .list)),
        socketPath: server.path
      )
    )
    #expect(listed == .sessions((try await registry.list())))
    await registry.terminate(grant.sessionID)
  }

  @Test
  func `malformed and unsupported requests create nothing`() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = SessionRegistry(
      service: try makeService(),
      identity: testIdentity()
    )
    let service = BootstrapService(registry: registry)
    let server = try ControlSocketServer(directory: directory) {
      await service.respond(toEnvelope: $0)
    }
    try server.start()
    defer { server.stop() }

    let oversized: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF] + Array("{}".utf8)
    #expect(
      try response(
        BootstrapService.forward(envelope: oversized, socketPath: server.path)
      ) == .failure(.malformed)
    )
    let truncated = Array(
      try envelope(BootstrapRequest(operation: .list)).dropLast()
    )
    #expect(
      try response(
        BootstrapService.forward(envelope: truncated, socketPath: server.path)
      ) == .failure(.malformed)
    )
    let unsupported = try envelope(
      BootstrapRequest(
        operation: .create,
        protocols: ["RST/9"],
        initialGrid: GridSize(columns: 80, rows: 24)
      )
    )
    #expect(
      try response(
        BootstrapService.forward(envelope: unsupported, socketPath: server.path)
      ) == .failure(.unsupportedVersion)
    )
    // The agent validates independently of the stdio client.
    #expect(
      try response(await service.respond(toEnvelope: unsupported))
        == .failure(.unsupportedVersion)
    )
    #expect((try await registry.list()).isEmpty)
  }

  @Test
  func `peers with another UID are refused`() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = SessionRegistry(
      service: try makeService(),
      identity: testIdentity()
    )
    let service = BootstrapService(registry: registry)
    let server = try ControlSocketServer(
      directory: directory,
      expectedUID: getuid() + 1
    ) { await service.respond(toEnvelope: $0) }
    try server.start()
    defer { server.stop() }
    let request = try envelope(
      BootstrapRequest(
        operation: .create,
        initialGrid: GridSize(columns: 80, rows: 24)
      )
    )
    #expect(
      try response(
        BootstrapService.forward(envelope: request, socketPath: server.path)
      ) == .failure(.agentUnavailable)
    )
    #expect((try await registry.list()).isEmpty)
  }

  @Test
  func `insecure directories and missing agents are rejected`() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    chmod(directory.path, 0o755)
    #expect(throws: ControlSocketError.insecureDirectory) {
      try ControlSocketServer(directory: directory) { $0 }
    }
    chmod(directory.path, 0o700)
    let request = try envelope(BootstrapRequest(operation: .list))
    let missing = directory.appendingPathComponent("control.sock").path
    #expect(
      try response(
        BootstrapService.forward(envelope: request, socketPath: missing)
      ) == .failure(.agentUnavailable)
    )
  }

  @Test
  func `stdin envelopes are bounded before the body is read`() throws {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    defer {
      close(fds[0])
      close(fds[1])
    }
    let prefix: [UInt8] = [0x00, 0x10, 0x00, 0x01]  // 1 MiB + 1
    _ = prefix.withUnsafeBytes { write(fds[1], $0.baseAddress, 4) }
    #expect(throws: FramingError.recordTooLarge(0x0010_0001)) {
      try BootstrapService.readEnvelope(from: fds[0])
    }
    let good = try envelope(BootstrapRequest(operation: .list))
    _ = good.withUnsafeBytes { write(fds[1], $0.baseAddress, good.count) }
    #expect(try BootstrapService.readEnvelope(from: fds[0]) == good)
  }

  @Test
  func `service and bootstrap helper resolve the same configuration`() {
    #expect(
      HostConfiguration.resolvedConfigurationURL(environment: [:])
        == HostConfiguration.defaultConfigurationURL
    )
    #expect(
      HostConfiguration.resolvedConfigurationURL(environment: [
        HostConfiguration.environmentKey: "/tmp/rst.json"
      ])
      .path == "/tmp/rst.json"
    )
  }

  @Test
  func configurationErrorsCannotSelectAnotherControlSocket() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    let environment = [HostConfiguration.environmentKey: file.path]
    // Explicitly selected missing, malformed and oversized files must not
    // turn into a request to an unrelated default service.
    #expect(throws: (any Error).self) {
      try HostConfiguration.resolvedSocketPath(environment: environment)
    }
    try Data("{".utf8).write(to: file)
    #expect(throws: (any Error).self) {
      try HostConfiguration.resolvedSocketPath(environment: environment)
    }
    try Data(repeating: 0x20, count: 64 * 1024 + 1).write(to: file)
    #expect(throws: (any Error).self) {
      try HostConfiguration.resolvedSocketPath(environment: environment)
    }
    let configured = HostConfiguration(
      bindAddress: "::1",
      advertisedHost: "host.local",
      stateDirectory: directory.path
    )
    try JSONEncoder().encode(configured).write(to: file)
    #expect(
      try HostConfiguration.resolvedSocketPath(environment: environment)
        == directory.appendingPathComponent("control.sock").path
    )
  }

  @Test
  func configurationReadsHaveAFiniteByteLimit() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    let config = HostConfiguration(
      bindAddress: "::1",
      advertisedHost: "host.local"
    )
    var data = try JSONEncoder().encode(config)
    data.append(Data(repeating: 0x20, count: 64 * 1024 - data.count))
    try data.write(to: file)
    #expect(try HostConfiguration.load(from: file) == config)
    data.append(0x20)
    try data.write(to: file)
    #expect(throws: CocoaError(.fileReadTooLarge)) {
      try HostConfiguration.load(from: file)
    }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    // A sparse oversized file exercises rejection before allocating or
    // reading its contents, while using negligible fixture disk space.
    try handle.truncate(atOffset: 64 * 1024 * 1024)
    #expect(throws: CocoaError(.fileReadTooLarge)) {
      try HostConfiguration.load(from: file)
    }
    #expect(throws: POSIXError(.EINVAL)) {
      try HostConfiguration.load(from: directory)
    }
  }

  @Test
  func `configuration requires an explicit bind address`() throws {
    let json = #"{"bindAddress":"192.168.1.5","advertisedHost":"mac.local"}"#
    let config = try JSONDecoder()
      .decode(HostConfiguration.self, from: Data(json.utf8))
    #expect(config.port == 51222)
    #expect(config.bindAddress == "192.168.1.5")
    #expect(throws: (any Error).self) {
      try JSONDecoder()
        .decode(
          HostConfiguration.self,
          from: Data(#"{"advertisedHost":"mac.local"}"#.utf8)
        )
    }
  }
}
#endif
