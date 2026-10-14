#if os(macOS)
import Darwin
import Foundation

/// Commands used by fixtures: isolated process groups, finite waits and
/// exclusive child collection. Output descriptors must refer to regular files.
public enum TestCommand {
  public enum Failure: Error, Equatable {
    case invalidArgument
    case systemCall(Int32)
    case timedOut
    case outputLimit
    case cleanup
  }

  public static func run(
    _ executable: String,
    arguments: [String],
    timeout: Duration = .seconds(30),
    stdout: Int32? = nil,
    stderr: Int32? = nil,
    maxOutputBytes: Int = 1 << 20,
    until: (() throws -> Bool)? = nil,
  ) throws -> Int32 {
    guard timeout > .zero, maxOutputBytes > 0, !executable.isEmpty,
      !([executable] + arguments).contains(where: { $0.utf8.contains(0) })
    else { throw Failure.invalidArgument }
    let pid = try spawn(
      executable,
      arguments: arguments,
      stdout: stdout,
      stderr: stderr,
    )
    let owned = OwnedChildWait(pid)
    let deadline = ContinuousClock.now + timeout
    func checkOutput() throws {
      for fd in [stdout, stderr].compactMap(\.self) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.systemCall(errno) }
        guard info.st_size <= maxOutputBytes else { throw Failure.outputLimit }
      }
    }
    var retired = false
    func retire() throws {
      if retired { return }
      // Keep the leader uncollected until its dedicated group is signaled.
      var info = siginfo_t()
      var result: Int32
      let deadline = ContinuousClock.now + .seconds(2)
      repeat {
        result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result >= 0 || errno != EINTR { break }
        if ContinuousClock.now >= deadline { throw Failure.cleanup }
      } while true
      guard result == 0 else { throw Failure.systemCall(errno) }
      if kill(-pid, SIGKILL) < 0, errno != ESRCH {
        let signalError = errno
        // Darwin can reject a zombie-only group. Accept that only when
        // the retained, waitable leader is verified as its sole member.
        var members = [pid_t](repeating: 0, count: 2)
        let count = members.withUnsafeMutableBytes {
          proc_listpgrppids(pid, $0.baseAddress, Int32($0.count))
        }
        guard signalError == EPERM, count == 1, members[0] == pid else {
          throw Failure.systemCall(signalError)
        }
        // The leader can become a zombie between the earlier peek and
        // kill. Refresh waitability before treating EPERM as harmless.
        try verifyExitedLeader(
          pid,
          deadline: deadline,
          signalError: signalError,
        )
      }
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero, owned.terminate(timeout: remaining) else {
        throw Failure.cleanup
      }
      retired = true
    }
    do {
      while true {
        try checkOutput()
        if try until?() == true {
          try retire()
          try checkOutput()
          return 128 + SIGKILL
        }
        var info = siginfo_t()
        let peek = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if peek < 0 {
          if errno == EINTR {
            if ContinuousClock.now >= deadline { throw Failure.timedOut }
            continue
          }
          throw Failure.systemCall(errno)
        }
        if info.si_pid == pid {
          let status =
            info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
          try retire()
          try checkOutput()
          return status
        }
        if ContinuousClock.now >= deadline { throw Failure.timedOut }
        usleep(1000)
      }
    } catch {
      try retire()
      throw error
    }
  }

  private static func verifyExitedLeader(
    _ pid: pid_t,
    deadline: ContinuousClock.Instant,
    signalError: Int32,
  ) throws {
    while true {
      var info = siginfo_t()
      let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
      if result == 0, info.si_pid == pid { return }
      if result < 0, errno != EINTR { throw Failure.systemCall(errno) }
      if ContinuousClock.now >= deadline {
        throw Failure.systemCall(signalError)
      }
      usleep(1000)
    }
  }

  private static func spawn(
    _ executable: String,
    arguments: [String],
    stdout: Int32?,
    stderr: Int32?,
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    for fd: Int32 in 0 ... 2 {
      try check(
        posix_spawn_file_actions_addopen(
          &actions,
          fd,
          "/dev/null",
          fd == 0 ? O_RDONLY : O_WRONLY,
          0,
        )
      )
    }
    for (source, destination) in [(stdout, Int32(1)), (stderr, Int32(2))] {
      if let source {
        var info = stat()
        guard source > 2, fstat(source, &info) == 0,
          info.st_mode & S_IFMT == S_IFREG
        else { throw Failure.invalidArgument }
        try check(
          posix_spawn_file_actions_adddup2(&actions, source, destination, )
        )
      }
    }
    var attributes: posix_spawnattr_t?
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    try check(
      posix_spawnattr_setflags(
        &attributes,
        Int16(
          POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK,
        )
      )
    )
    try check(posix_spawnattr_setpgroup(&attributes, 0))
    var defaults = sigset_t()
    sigfillset(&defaults)
    try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
    var mask = sigset_t()
    sigemptyset(&mask)
    try check(posix_spawnattr_setsigmask(&attributes, &mask))
    let environment = ProcessInfo.processInfo.environment.map {
      "\($0.key)=\($0.value)"
    }
    let argv = try strings([executable] + arguments)
    defer { for pointer in argv { free(pointer) } }
    let env = try strings(environment)
    defer { for pointer in env { free(pointer) } }
    var pid: pid_t = 0
    let result = argv.withUnsafeBufferPointer { arguments in
      env.withUnsafeBufferPointer { environment in
        posix_spawn(
          &pid,
          executable,
          &actions,
          &attributes,
          arguments.baseAddress!,
          environment.baseAddress!,
        )
      }
    }
    try check(result)
    return pid
  }

  private static func check(_ code: Int32) throws {
    if code != 0 { throw Failure.systemCall(code) }
  }

  private static func strings(
    _ values: [String]
  ) throws -> [UnsafeMutablePointer<CChar>?] {
    var result: [UnsafeMutablePointer<CChar>?] = []
    for value in values {
      guard let pointer = strdup(value) else {
        for pointer in result { free(pointer) }
        throw Failure.systemCall(ENOMEM)
      }
      result.append(pointer)
    }
    result.append(nil)
    return result
  }
}
#endif
