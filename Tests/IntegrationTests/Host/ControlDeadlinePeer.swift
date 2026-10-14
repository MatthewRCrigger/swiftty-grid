#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing

@testable import TerminalHost

/// One owned finite peer, independent of the repository server's own deadline.
final class ControlDeadlinePeer: @unchecked Sendable {
  private struct State {
    var stopped = false
    var active: Int32?
  }

  let path: String
  private let listener: Int32
  private let state = Mutex(State())
  private let completion = DispatchGroup()

  init(
    directory: URL,
    backlog: Int32 = 4,
    script: (@Sendable (Int32) throws -> Void)? = nil
  ) throws {
    path = directory.appendingPathComponent("peer.sock").path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var transferred = false
    defer { if !transferred { close(fd) } }
    try #require(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0)
    try #require(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
    var address = try ControlSocketServer.address(path)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    try #require(bound == 0)
    try #require(chmod(path, 0o600) == 0)
    try #require(listen(fd, backlog) == 0)
    listener = fd
    transferred = true
    guard let script else { return }
    completion.enter()
    DispatchQueue.global(qos: .userInitiated)
      .async { [self] in
        defer { completion.leave() }
        guard let client = acceptBeforeDeadline() else { return }
        let admitted = state.withLock { value in
          guard !value.stopped else { return false }
          value.active = client
          return true
        }
        guard admitted else {
          close(client);
          return
        }
        defer {
          state.withLock { value in
            value.active = nil
            close(client)
          }
        }
        do {
          try #require(fcntl(client, F_SETFD, FD_CLOEXEC) == 0)
          // macOS inherits O_NONBLOCK from the listener. The finite script
          // uses blocking I/O with kernel timeouts, just like the server.
          let flags = fcntl(client, F_GETFL)
          try #require(flags >= 0)
          try #require(fcntl(client, F_SETFL, flags & ~O_NONBLOCK) == 0)
          try setTimeouts(client, .seconds(2))
          try script(client)
        } catch { Issue.record(error) }
      }
  }

  deinit { stop() }

  private func acceptBeforeDeadline() -> Int32? {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline, !state.withLock({ $0.stopped }) {
      let client = accept(listener, nil, nil)
      if client >= 0 { return client }
      if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
        return nil
      }
      var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      _ = poll(&descriptor, 1, 10)
    }
    return nil
  }

  /// Revokes the active connection, joins its worker, then closes the listener.
  /// No descriptor is closed while the worker may still use or poll it.
  func stop() {
    let needsClose = state.withLock { value in
      guard !value.stopped else { return false }
      value.stopped = true
      if let client = value.active { shutdown(client, SHUT_RDWR) }
      shutdown(listener, SHUT_RDWR)
      return true
    }
    guard needsClose else { return }
    completion.wait()
    close(listener)
    unlink(path)
  }
}
#endif
