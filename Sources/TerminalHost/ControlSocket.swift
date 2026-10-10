#if os(macOS)
import Darwin
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization

public enum ControlSocketError: Error, Equatable, Sendable {
  /// The directory is not an owner-only (0700) directory of this user.
  case insecureDirectory
  /// The socket is missing, not a socket, or owned by another user.
  case insecureSocket
  case pathTooLong
  case peerRejected
  case system(String, Int32)
}

/// The owner-only directory holding the agent's control socket (spec §4).
public enum ControlDirectory {
  /// `~/Library/Application Support/SwiftMux/roaming`.
  public static var defaultURL: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/Application Support/SwiftMux/roaming")
  }

  /// Creates the directory with mode 0700 when missing, then verifies it
  /// is a real directory (not a symlink) owned by `uid` with no group or
  /// other permissions.
  public static func prepare(
    _ url: URL,
    uid: uid_t = getuid()
  ) throws(ControlSocketError) {
    let path = url.path
    if mkdir(path, 0o700) != 0, errno != EEXIST {
      throw .system("mkdir", errno)
    }
    try verify(url, uid: uid)
  }

  public static func verify(
    _ url: URL,
    uid: uid_t = getuid()
  ) throws(ControlSocketError) {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw .system("lstat", errno) }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == uid,
      info.st_mode & 0o077 == 0
    else { throw .insecureDirectory }
  }
}

/// Unix-domain control socket served by the agent. Each client sends
/// exactly one bounded bootstrap envelope and receives one response.
/// Peers must have the agent's UID (`getpeereid`).
public final class ControlSocketServer: @unchecked Sendable {
  public typealias Handler = @Sendable ([UInt8]) async -> [UInt8]

  public let path: String
  private let expectedUID: uid_t
  private let handler: Handler
  private let ioTimeout: Duration
  private let state = Mutex<(fd: Int32, source: DispatchSourceRead?)>((-1, nil))
  private let queue = DispatchQueue(label: "swifttyd.control-socket")

  /// - Parameters:
  ///   - directory: An owner-only directory (see `ControlDirectory`).
  ///   - expectedUID: The only peer UID served.
  public init(
    directory: URL,
    name: String = "control.sock",
    expectedUID: uid_t = getuid(),
    ioTimeout: Duration = .seconds(5),
    handler: @escaping Handler
  ) throws(ControlSocketError) {
    try ControlDirectory.verify(directory)
    path = directory.appendingPathComponent(name).path
    self.expectedUID = expectedUID
    self.handler = handler
    self.ioTimeout = ioTimeout
    guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    else { throw .pathTooLong }
  }

  deinit { stop() }

  public func start() throws(ControlSocketError) {
    // Replace only a stale socket of ours; never follow or remove others.
    var info = stat()
    if lstat(path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
        throw .insecureSocket
      }
      unlink(path)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .system("socket", errno) }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var address = try Self.address(path)
    // The process umask is shared by every thread, so it is left alone;
    // the owner-only directory already shields the socket until chmod.
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else {
      let code = errno
      close(fd)
      throw .system("bind", code)
    }
    guard chmod(path, 0o600) == 0 else {
      let code = errno
      close(fd)
      unlink(path)
      throw .system("chmod", code)
    }
    guard lstat(path, &info) == 0, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0
    else {
      close(fd)
      unlink(path)
      throw .insecureSocket
    }
    guard listen(fd, 16) == 0 else {
      let code = errno
      close(fd)
      throw .system("listen", code)
    }
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.acceptAll(fd) }
    source.setCancelHandler { close(fd) }
    source.resume()
    state.withLock { $0 = (fd, source) }
  }

  public func stop() {
    let source = state.withLock { s -> DispatchSourceRead? in
      defer { s = (-1, nil) }
      return s.source
    }
    guard let source else { return }
    source.cancel()
    unlink(path)
  }

  private func acceptAll(_ listener: Int32) {
    while true {
      let client = accept(listener, nil, nil)
      guard client >= 0 else { return }
      _ = fcntl(client, F_SETFD, FD_CLOEXEC)
      var uid: uid_t = 0
      var gid: gid_t = 0
      guard getpeereid(client, &uid, &gid) == 0, uid == expectedUID else {
        close(client)
        continue
      }
      let handler = handler
      let timeout = ioTimeout
      DispatchQueue.global(qos: .userInitiated).async {
        Self.serve(client, timeout: timeout, handler: handler)
      }
    }
  }

  private static func serve(
    _ fd: Int32,
    timeout: Duration,
    handler: @escaping Handler
  ) {
    // Blocking I/O with deadlines on a bounded per-client exchange.
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
    setTimeouts(fd, timeout)
    guard let request = try? readEnvelope(fd) else {
      close(fd)
      return
    }
    Task {
      let response = await handler(request)
      _ = writeAll(fd, response)
      close(fd)
    }
  }

  static func address(_ path: String) throws(ControlSocketError) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { throw .pathTooLong }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
  }
}

/// Client side of the control socket (used by `bootstrap --stdio`).
public enum ControlSocketClient {
  /// Sends one envelope and returns the one response envelope. Verifies
  /// the socket is owned by this user before connecting.
  public static func exchange(
    path: String,
    envelope: [UInt8],
    timeout: Duration = .seconds(10)
  ) throws(ControlSocketError) -> [UInt8] {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
      info.st_uid == getuid()
    else { throw .insecureSocket }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .system("socket", errno) }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var address = try ControlSocketServer.address(path)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw .system("connect", errno) }
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
      throw .peerRejected
    }
    setTimeouts(fd, timeout)
    guard writeAll(fd, envelope) else { throw .system("write", errno) }
    do {
      return try readEnvelope(fd)
    } catch {
      throw .peerRejected
    }
  }
}

// MARK: Bounded envelope I/O

func setTimeouts(_ fd: Int32, _ timeout: Duration) {
  let seconds = timeout.components.seconds
  var value = timeval(
    tv_sec: Int(seconds),
    tv_usec: Int32(timeout.components.attoseconds / 1_000_000_000_000)
  )
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
  var noSignal: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
}

/// Reads exactly one `UInt32BE(length)` + body envelope, rejecting an
/// over-limit length before reading the body.
func readEnvelope(_ fd: Int32) throws(FramingError) -> [UInt8] {
  var prefix = [UInt8](repeating: 0, count: 4)
  guard readExactly(fd, &prefix, count: 4) else { throw .truncated }
  guard let total = try BootstrapEnvelope.expectedLength(prefix) else {
    throw .truncated
  }
  var body = [UInt8](repeating: 0, count: total - 4)
  guard readExactly(fd, &body, count: total - 4) else { throw .truncated }
  return prefix + body
}

func readExactly(_ fd: Int32, _ buffer: inout [UInt8], count: Int) -> Bool {
  var offset = 0
  while offset < count {
    let n = buffer.withUnsafeMutableBytes {
      read(fd, $0.baseAddress! + offset, count - offset)
    }
    if n > 0 {
      offset += n
      continue
    }
    if n < 0, errno == EINTR { continue }
    return false
  }
  return true
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
  var offset = 0
  while offset < bytes.count {
    let n = bytes.withUnsafeBytes {
      write(fd, $0.baseAddress! + offset, bytes.count - offset)
    }
    if n > 0 {
      offset += n
      continue
    }
    if n < 0, errno == EINTR { continue }
    return false
  }
  return true
}
#endif
