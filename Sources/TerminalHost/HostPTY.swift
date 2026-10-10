#if os(macOS)
import Darwin
import Foundation
import SwifttyCore

/// What a host session runs: by default the account's login shell.
public struct ShellLaunch: Sendable, Hashable {
  public var executable: String
  /// Full argv including argv[0] (e.g. `-zsh` for a login shell).
  public var arguments: [String]
  /// The complete environment; nothing else is inherited.
  public var environment: [String: String]
  public var workingDirectory: String?

  public init(
    executable: String,
    arguments: [String],
    environment: [String: String],
    workingDirectory: String? = nil
  ) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
  }

  /// The account's login shell from the password database (spec §4):
  /// argv[0] `-<name>`, `TERM=xterm-256color`, working directory `$HOME`.
  public static func loginShell(uid: uid_t = getuid()) -> ShellLaunch {
    var shell = "/bin/zsh"
    var home = NSHomeDirectory()
    var user = NSUserName()
    if let pw = getpwuid(uid) {
      if let s = pw.pointee.pw_shell, s.pointee != 0 {
        shell = String(cString: s)
      }
      if let h = pw.pointee.pw_dir, h.pointee != 0 { home = String(cString: h) }
      if let n = pw.pointee.pw_name, n.pointee != 0 { user = String(cString: n) }
    }
    let name = shell.split(separator: "/").last.map(String.init) ?? "sh"
    let inherited = ProcessInfo.processInfo.environment
    var environment: [String: String] = [
      "HOME": home,
      "USER": user,
      "LOGNAME": user,
      "SHELL": shell,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "TERM": "xterm-256color",
      "COLORTERM": "truecolor",
      "LANG": inherited["LANG"] ?? "en_US.UTF-8",
    ]
    if let tmp = inherited["TMPDIR"] { environment["TMPDIR"] = tmp }
    return ShellLaunch(
      executable: shell,
      arguments: ["-" + name],
      environment: environment,
      workingDirectory: home
    )
  }
}

/// Outcome of one nonblocking PTY write attempt.
public enum PTYWriteResult: Sendable, Equatable {
  /// The PTY accepted this many bytes (at least one).
  case wrote(Int)
  /// EAGAIN: wait for writability.
  case wouldBlock
  /// A hard error (`errno`); the bytes were not accepted.
  case failed(Int32)
}

/// The raw PTY write, abstracted so tests can force partial writes,
/// EAGAIN and errors. Called only on the session's owner queue.
public protocol PTYWriting: Sendable {
  func write(fd: Int32, _ bytes: UnsafeRawBufferPointer) -> PTYWriteResult
}

/// One `write(2)` per call.
public struct DarwinPTYWriter: PTYWriting {
  public init() {}

  public func write(
    fd: Int32,
    _ bytes: UnsafeRawBufferPointer
  ) -> PTYWriteResult {
    guard !bytes.isEmpty else { return .wrote(0) }
    while true {
      let n = Darwin.write(fd, bytes.baseAddress, bytes.count)
      if n > 0 { return .wrote(n) }
      if n < 0, errno == EINTR { continue }
      if n < 0, errno == EAGAIN { return .wouldBlock }
      return .failed(n < 0 ? errno : EIO)
    }
  }
}

/// Owns a PTY master, the retained slave and the shell process. The
/// descriptors close when the last reference goes away, which dispatch
/// sources extend through their cancel handlers.
final class HostPTY: @unchecked Sendable {
  let master: Int32
  /// Darwin discards unread master output once the last slave closes;
  /// holding one keeps final output readable after the shell exits.
  private let slave: Int32
  let pid: pid_t

  private init(master: Int32, slave: Int32, pid: pid_t) {
    self.master = master
    self.slave = slave
    self.pid = pid
  }

  deinit {
    Darwin.close(master)
    Darwin.close(slave)
  }

  /// Spawns `launch` as a session leader whose controlling terminal is a
  /// new PTY (posix_spawn with `POSIX_SPAWN_SETSID`, then opening the
  /// slave by path in the child). The master is nonblocking.
  static func spawn(
    _ launch: ShellLaunch,
    columns: Int,
    rows: Int
  ) throws(SwifttyCore.POSIXError) -> HostPTY {
    var masterFD: Int32 = -1
    var slaveFD: Int32 = -1
    var size = winsize(columns: columns, rows: rows)
    var name = [CChar](repeating: 0, count: 128)
    guard openpty(&masterFD, &slaveFD, &name, nil, &size) == 0 else {
      throw SwifttyCore.POSIXError("openpty")
    }
    _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
    _ = fcntl(slaveFD, F_SETFD, FD_CLOEXEC)
    let flags = fcntl(masterFD, F_GETFL)
    guard flags >= 0, fcntl(masterFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
      let error = SwifttyCore.POSIXError("fcntl(O_NONBLOCK)")
      Darwin.close(masterFD)
      Darwin.close(slaveFD)
      throw error
    }
    var attrs = termios()
    if tcgetattr(slaveFD, &attrs) == 0 {
      attrs.c_iflag |= tcflag_t(IUTF8)
      tcsetattr(slaveFD, TCSANOW, &attrs)
    }
    let ttyName = String(
      decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    do {
      let pid = try spawnChild(launch, ttyName: ttyName)
      return HostPTY(master: masterFD, slave: slaveFD, pid: pid)
    } catch {
      Darwin.close(masterFD)
      Darwin.close(slaveFD)
      throw error
    }
  }

  private static func spawnChild(
    _ launch: ShellLaunch,
    ttyName: String
  ) throws(SwifttyCore.POSIXError) -> pid_t {
    guard !launch.arguments.isEmpty,
      !launch.executable.utf8.contains(0),
      !launch.arguments.contains(where: { $0.utf8.contains(0) }),
      launch.workingDirectory?.utf8.contains(0) != true
    else { throw SwifttyCore.POSIXError("invalid launch", code: EINVAL) }
    let environment = launch.environment.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
    guard
      !environment.contains(where: { $0.utf8.contains(0) }),
      !launch.environment.keys.contains(where: {
        $0.isEmpty || $0.utf8.contains(0x3D)
      })
    else { throw SwifttyCore.POSIXError("invalid environment", code: EINVAL) }

    var actions: posix_spawn_file_actions_t?
    try check(posix_spawn_file_actions_init(&actions), "file_actions_init")
    defer { posix_spawn_file_actions_destroy(&actions) }
    // Opening the slave by path after setsid makes it the controlling
    // terminal of the new session.
    try check(
      posix_spawn_file_actions_addopen(&actions, 0, ttyName, O_RDWR, 0),
      "file_actions_addopen"
    )
    try check(posix_spawn_file_actions_adddup2(&actions, 0, 1), "adddup2")
    try check(posix_spawn_file_actions_adddup2(&actions, 0, 2), "adddup2")
    if let cwd = launch.workingDirectory {
      try check(posix_spawn_file_actions_addchdir(&actions, cwd), "addchdir")
    }

    var attributes: posix_spawnattr_t?
    try check(posix_spawnattr_init(&attributes), "spawnattr_init")
    defer { posix_spawnattr_destroy(&attributes) }
    let flags =
      POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_SETSIGMASK
    try check(posix_spawnattr_setflags(&attributes, Int16(flags)), "setflags")
    var all = sigset_t()
    sigfillset(&all)
    try check(posix_spawnattr_setsigdefault(&attributes, &all), "sigdefault")
    var none = sigset_t()
    sigemptyset(&none)
    try check(posix_spawnattr_setsigmask(&attributes, &none), "sigmask")

    var pid: pid_t = 0
    let status = withCStrings(launch.arguments) { argv in
      withCStrings(environment) { env in
        posix_spawn(&pid, launch.executable, &actions, &attributes, argv, env)
      }
    }
    guard status == 0 else { throw SwifttyCore.POSIXError("posix_spawn", code: status) }
    return pid
  }

  private static func check(_ status: Int32, _ op: String) throws(SwifttyCore.POSIXError) {
    guard status == 0 else { throw SwifttyCore.POSIXError(op, code: status) }
  }

  func resize(columns: Int, rows: Int) -> Bool {
    var size = Self.winsize(columns: columns, rows: rows)
    return ioctl(master, TIOCSWINSZ, &size) == 0
  }

  static func winsize(columns: Int, rows: Int) -> Darwin.winsize {
    Darwin.winsize(
      ws_row: UInt16(clamping: rows),
      ws_col: UInt16(clamping: columns),
      ws_xpixel: 0,
      ws_ypixel: 0
    )
  }
}

private func withCStrings<R>(
  _ strings: [String],
  _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
  let pointers = strings.map { strdup($0) } + [nil]
  defer { for p in pointers { free(p) } }
  return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// Waits for `pid` without blocking; returns the decoded exit status
/// (128 + signal for a signaled child) once it has been reaped.
func reapChild(_ pid: pid_t, blocking: Bool) -> Int32? {
  var status: Int32 = 0
  var result: pid_t
  repeat {
    result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
  } while result < 0 && errno == EINTR
  guard result == pid else { return nil }
  return (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
}
#endif
