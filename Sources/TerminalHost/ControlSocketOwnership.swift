#if os(macOS)
import Darwin

/// Held by a server's locked listener state. The persistent lock file must
/// never be unlinked: all cooperating instances must lock the same inode.
final class ControlSocketOwnership {
  private let path: String
  private var lockFD: Int32
  private var socketIdentity: (device: dev_t, inode: ino_t)?

  init(path: String) throws(ControlSocketError) {
    self.path = path
    let fd = open(
      path + ".lock",
      O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
      0o600
    )
    guard fd >= 0 else { throw .system("open socket lock", errno) }
    var retained = false
    defer { if !retained { close(fd) } }
    var info = stat()
    guard fstat(fd, &info) == 0 else {
      throw .system("fstat socket lock", errno)
    }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0
    else { throw .insecureSocket }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw .system("flock", errno)
    }
    lockFD = fd
    retained = true
  }

  deinit { release() }

  /// Stop must release while still holding the server-state mutex; ARC may
  /// retain temporary ownership references past that mutex's unlock.
  func release() {
    guard lockFD >= 0 else { return }
    // Concurrent process creation may retain an inherited descriptor until
    // exec closes it. Unlock the shared file description before closing ours.
    while flock(lockFD, LOCK_UN) != 0, errno == EINTR {}
    close(lockFD)
    lockFD = -1
  }

  /// Also protects listeners from older versions that do not take the lock.
  func removeStaleSocket() throws(ControlSocketError) {
    var original = stat()
    guard lstat(path, &original) == 0 else {
      guard errno == ENOENT else { throw .system("lstat", errno) }
      return
    }
    guard original.st_mode & S_IFMT == S_IFSOCK, original.st_uid == getuid()
    else { throw .insecureSocket }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .system("socket probe", errno) }
    defer { close(fd) }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
      fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
    else { throw .system("fcntl socket probe", errno) }
    var address = try ControlSocketServer.address(path)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    let code = errno
    if connected != 0, code == ENOENT { return }
    guard connected != 0, code == ECONNREFUSED else {
      throw .system("bind", EADDRINUSE)
    }
    var current = stat()
    guard lstat(path, &current) == 0 else {
      guard errno == ENOENT else { throw .system("lstat", errno) }
      return
    }
    guard current.st_dev == original.st_dev, current.st_ino == original.st_ino,
      current.st_mode & S_IFMT == S_IFSOCK, current.st_uid == getuid()
    else { throw .insecureSocket }
    guard unlink(path) == 0 else { throw .system("unlink stale socket", errno) }
  }

  func claimSocket() throws(ControlSocketError) {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      throw .system("lstat bound socket", errno)
    }
    guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
      throw .insecureSocket
    }
    socketIdentity = (info.st_dev, info.st_ino)
  }

  /// Preserve a replacement path installed by a nonparticipating instance.
  func removeSocketIfOwned() {
    guard let identity = socketIdentity else { return }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
      info.st_uid == getuid(), info.st_dev == identity.device,
      info.st_ino == identity.inode
    else { return }
    unlink(path)
  }
}
#endif
