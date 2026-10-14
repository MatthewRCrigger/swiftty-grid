#if os(macOS)
import Darwin
import ScreenProtocol

/// The caller retains and closes the descriptor after all synchronous I/O.
/// One monotonic budget covers every socket phase, including partial progress.
struct ControlSocketClientIO {
  let fd: Int32
  let timeout: Duration
  let started: ContinuousClock.Instant

  init(
    fd: Int32,
    timeout: Duration,
    started: ContinuousClock.Instant
  ) throws(ControlSocketError) {
    self.fd = fd
    self.timeout = timeout
    self.started = started
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw .system("fcntl O_NONBLOCK", errno)
    }
  }

  private func remaining() throws(ControlSocketError) -> Duration {
    let elapsed = started.duration(to: .now)
    guard elapsed < timeout else { throw .timedOut }
    return timeout - elapsed
  }

  /// Poll in finite turns and round a positive fractional millisecond upward.
  /// Taking the minimum before conversion avoids overflow for long budgets.
  private func pollMilliseconds(
    maximum: Duration
  ) throws(ControlSocketError) -> Int32 {
    let duration = min(try remaining(), maximum)
    let parts = duration.components
    let unit: Int64 = 1_000_000_000_000_000
    return Int32(parts.seconds * 1000 + (parts.attoseconds + unit - 1) / unit)
  }

  private func wait(_ event: Int16) throws(ControlSocketError) {
    while true {
      var descriptor = pollfd(fd: fd, events: event, revents: 0)
      let result = poll(
        &descriptor,
        1,
        try pollMilliseconds(maximum: .seconds(1))
      )
      if result < 0 {
        if errno == EINTR { continue }
        throw .system("poll", errno)
      }
      _ = try remaining()
      if result == 0 { continue }
      if descriptor.revents & Int16(POLLNVAL) != 0 {
        throw .system("poll", EBADF)
      }
      if descriptor.revents & (event | Int16(POLLHUP | POLLERR)) != 0 { return }
    }
  }

  /// An unconnected Unix socket may report EAGAIN while its listen queue is
  /// full. Its writable event need not mean a connect can now be admitted.
  private func retryConnect() throws(ControlSocketError) {
    let result = poll(nil, 0, try pollMilliseconds(maximum: .milliseconds(10)))
    if result < 0, errno != EINTR { throw .system("poll", errno) }
    _ = try remaining()
  }

  func connect(to address: inout sockaddr_un) throws(ControlSocketError) {
    while true {
      _ = try remaining()
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      if result == 0 || errno == EISCONN {
        _ = try remaining()
        return
      }
      let error = errno
      if error == EINTR { continue }
      if error == EAGAIN || error == EWOULDBLOCK {
        try retryConnect()
        continue
      }
      guard error == EINPROGRESS || error == EALREADY else {
        throw .system("connect", error)
      }
      try wait(Int16(POLLOUT))
      var completion: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &completion, &size) == 0 else {
        throw .system("getsockopt SO_ERROR", errno)
      }
      guard completion == 0 else { throw .system("connect", completion) }
      var peer = sockaddr_un()
      var peerSize = socklen_t(MemoryLayout<sockaddr_un>.size)
      let connected = withUnsafeMutablePointer(to: &peer) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          getpeername(fd, $0, &peerSize)
        }
      }
      if connected == 0 {
        _ = try remaining()
        return
      }
      guard errno == ENOTCONN else { throw .system("getpeername", errno) }
      try retryConnect()
    }
  }

  func write(_ bytes: [UInt8]) throws(ControlSocketError) {
    var offset = 0
    while offset < bytes.count {
      _ = try remaining()
      let count = bytes.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset)
      }
      if count > 0 {
        offset += count
      } else if count < 0, errno == EINTR {
        continue
      } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        try wait(Int16(POLLOUT))
      } else {
        throw .system("write", count == 0 ? EPIPE : errno)
      }
    }
    _ = try remaining()
  }

  private func readExactly(_ count: Int) throws(ControlSocketError) -> [UInt8] {
    _ = try remaining()
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      _ = try remaining()
      let received = bytes.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress! + offset, count - offset)
      }
      if received > 0 {
        offset += received
      } else if received < 0, errno == EINTR {
        continue
      } else if received < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        try wait(Int16(POLLIN))
      } else {
        throw .peerRejected
      }
    }
    _ = try remaining()
    return bytes
  }

  func readEnvelope() throws(ControlSocketError) -> [UInt8] {
    let prefix = try readExactly(4)
    let total: Int
    do {
      guard let expected = try BootstrapEnvelope.expectedLength(prefix) else {
        throw ControlSocketError.peerRejected
      }
      total = expected
    } catch { throw .peerRejected }
    let body = try readExactly(total - 4)
    _ = try remaining()
    return prefix + body
  }
}
#endif
