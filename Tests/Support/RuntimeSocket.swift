#if canImport(Darwin)
import Darwin
import Foundation

public enum RuntimeSocketError: Error, Equatable, Sendable {
  case invalidPath
  case invalidLimits
  case invalidEnvelope
  case timedOut
  case truncated
  case recordTooLarge(Int)
  case trailingData
  case system(String, Int32)
}

/// One local fixture request/response. All socket operations are nonblocking;
/// every phase shares a monotonic deadline and observes task cancellation.
public enum RuntimeSocket {
  public static func exchange(
    path: String,
    request: [UInt8],
    maximumBodyBytes: Int,
    timeout: Duration = .seconds(10),
  ) async throws -> [UInt8] {
    try Task.checkCancellation()
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !path.isEmpty, !path.utf8.contains(0), path.utf8.count < capacity
    else { throw RuntimeSocketError.invalidPath }
    guard maximumBodyBytes >= 0, maximumBodyBytes <= Int(UInt32.max),
      timeout > .zero
    else { throw RuntimeSocketError.invalidLimits }
    guard request.count >= 4, request.count - 4 <= maximumBodyBytes,
      bodyLength(request) == request.count - 4
    else { throw RuntimeSocketError.invalidEnvelope }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: path.utf8)
      buffer[path.utf8.count] = 0
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw RuntimeSocketError.system("socket", errno) }
    defer { Darwin.close(fd) }
    guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
      fcntl(fd, F_SETFL, O_NONBLOCK) == 0
    else { throw RuntimeSocketError.system("fcntl", errno) }
    var noSignal: Int32 = 1
    guard
      setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout<Int32>.size),
      ) == 0
    else { throw RuntimeSocketError.system("SO_NOSIGPIPE", errno) }
    let io = IO(fd: fd, deadline: ContinuousClock.now + timeout)
    while true {
      try io.check()
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
      if result == 0 { break }
      let failure = errno
      if failure == EINTR { continue }
      guard failure == EINPROGRESS || failure == EALREADY else {
        throw RuntimeSocketError.system("connect", failure)
      }
      try await io.ready(POLLOUT)
      var socketError: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0
      else { throw RuntimeSocketError.system("SO_ERROR", errno) }
      guard socketError == 0 else {
        throw RuntimeSocketError.system("connect", socketError)
      }
      break
    }
    try await io.write(request)
    let prefix = try await io.read(count: 4)
    let length = bodyLength(prefix)
    guard length <= maximumBodyBytes else {
      throw RuntimeSocketError.recordTooLarge(length)
    }
    let body = try await io.read(count: length)
    // The fixture server closes after its one response. Requiring EOF also
    // rejects trailing output arriving in a separate socket read.
    try await io.requireEOF()
    try io.check()
    return prefix + body
  }

  private static func bodyLength(_ prefix: [UInt8]) -> Int {
    prefix.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
  }

  private struct IO {
    let fd: Int32
    let deadline: ContinuousClock.Instant

    func check() throws {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw RuntimeSocketError.timedOut
      }
    }

    func ready(_ events: Int32) async throws {
      while true {
        try check()
        var descriptor = pollfd(fd: fd, events: Int16(events), revents: 0)
        let result = poll(&descriptor, 1, 0)
        if result > 0 {
          guard Int32(descriptor.revents) & POLLNVAL == 0 else {
            throw RuntimeSocketError.system("poll", EBADF)
          }
          return
        }
        if result < 0, errno != EINTR {
          throw RuntimeSocketError.system("poll", errno)
        }
        try await ContinuousClock()
          .sleep(until: min(.now + .milliseconds(10), deadline), )
      }
    }

    func write(_ bytes: [UInt8]) async throws {
      var offset = 0
      while offset < bytes.count {
        try check()
        let count = min(4096, bytes.count - offset)
        let result = bytes.withUnsafeBytes {
          Darwin.send(fd, $0.baseAddress! + offset, count, 0)
        }
        if result > 0 {
          offset += result;
          continue
        }
        let failure = errno
        if result < 0, failure == EINTR { continue }
        if result < 0, failure == EAGAIN || failure == EWOULDBLOCK {
          try await ready(POLLOUT)
          continue
        }
        throw RuntimeSocketError.system("send", result == 0 ? EPIPE : failure)
      }
    }

    func read(count: Int) async throws -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: count)
      var offset = 0
      while offset < count {
        try check()
        let result = bytes.withUnsafeMutableBytes {
          Darwin.recv(fd, $0.baseAddress! + offset, count - offset, 0)
        }
        if result > 0 {
          offset += result;
          continue
        }
        if result == 0 { throw RuntimeSocketError.truncated }
        let failure = errno
        if failure == EINTR { continue }
        if failure == EAGAIN || failure == EWOULDBLOCK {
          try await ready(POLLIN)
          continue
        }
        throw RuntimeSocketError.system("recv", failure)
      }
      return bytes
    }

    func requireEOF() async throws {
      while true {
        try check()
        var byte: UInt8 = 0
        let result = Darwin.recv(fd, &byte, 1, 0)
        if result == 0 { return }
        if result > 0 { throw RuntimeSocketError.trailingData }
        let failure = errno
        if failure == EINTR { continue }
        if failure == EAGAIN || failure == EWOULDBLOCK {
          try await ready(POLLIN)
          continue
        }
        throw RuntimeSocketError.system("recv", failure)
      }
    }
  }
}
#endif
