import Darwin
import Foundation
import SwiftMuxProtocol

/// A spawned pane process: the PTY master, a retained slave (Darwin drops
/// unread output once the last slave closes) and the shell's pid.
struct LaunchedProcess: Sendable {
  var master: Int32
  var slave: Int32
  var pid: pid_t
  var warnings: [String]
}

/// Starts pane processes through the fresh `swmux-launcher` executable.
/// No Swift code runs in a forked child of the service.
struct PaneLauncher: Sendable {
  var launcherPath: String
  var innerTerm: String
  /// Extra terminfo search directory for `innerTerm`, if installed there.
  var terminfoDirectory: String?

  /// Resolves the program for `spec` using its environment snapshot.
  static func resolve(
    _ spec: LaunchSpec,
    environment: [String: String]
  ) throws(MuxError) -> (path: String, argv: [String]) {
    guard let command = spec.command, let program = command.first else {
      let shell = loginShell(environment)
      let base = shell.split(separator: "/").last.map(String.init) ?? shell
      // A leading dash in argv[0] asks the shell to act as a login shell.
      return (shell, ["-" + base])
    }
    for part in command where part.utf8.contains(0) {
      throw MuxError(.invalidRequest, "argument contains NUL: \(part)")
    }
    guard !program.isEmpty else {
      throw MuxError(.invalidRequest, "empty program")
    }
    if program.contains("/") { return (program, command) }
    let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for dir in path.split(separator: ":") {
      let candidate = "\(dir)/\(program)"
      if access(candidate, X_OK) == 0 { return (candidate, command) }
    }
    throw MuxError(.launchFailed, "\(program): command not found")
  }

  static func loginShell(_ environment: [String: String]) -> String {
    if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell,
      shell.pointee != 0
    {
      return String(cString: shell)
    }
    return environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
  }

  /// The pane's environment: the creation snapshot plus inner identity.
  func environment(
    for spec: LaunchSpec,
    pane: PaneID,
    workspace: WorkspaceID
  ) -> [String: String] {
    var env = spec.environment
    if env["HOME"] == nil, let pw = getpwuid(getuid()) {
      env["HOME"] = String(cString: pw.pointee.pw_dir)
    }
    if env["USER"] == nil, let pw = getpwuid(getuid()) {
      env["USER"] = String(cString: pw.pointee.pw_name)
      env["LOGNAME"] = env["USER"]
    }
    if env["PATH"] == nil { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    env["SHELL"] = env["SHELL"] ?? Self.loginShell(env)
    // Programs see the inner engine, never the outer host or tmux.
    for key in [
      "TMUX", "TMUX_PANE", "TERMINFO", "TERM_SESSION_ID", "ITERM_SESSION_ID",
    ] { env.removeValue(forKey: key) }
    env["TERM"] = innerTerm
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "swmux"
    env["TERM_PROGRAM_VERSION"] = SMX.build
    env["SWMUX"] = "1"
    env["SWMUX_PANE"] = pane.description
    env["SWMUX_WORKSPACE"] = workspace.description
    if let dir = terminfoDirectory {
      // A trailing empty entry keeps the system database.
      let existing = env["TERMINFO_DIRS"].map { ":" + $0 } ?? ":"
      env["TERMINFO_DIRS"] = dir + existing
    }
    return env
  }

  /// Allocates a PTY with deliberate cooked termios and spawns the
  /// launcher, which execs the program as session leader.
  func launch(
    _ spec: LaunchSpec,
    pane: PaneID,
    workspace: WorkspaceID,
    columns: Int,
    rows: Int
  ) throws(MuxError) -> LaunchedProcess {
    let env = environment(for: spec, pane: pane, workspace: workspace)
    let (program, argv) = try Self.resolve(spec, environment: env)
    let directory =
      spec.workingDirectory ?? env["HOME"]
      ?? FileManager.default.homeDirectoryForCurrentUser.path
    guard !directory.utf8.contains(0) else {
      throw MuxError(.invalidRequest, "directory contains NUL")
    }
    for (k, v) in env
    where k.isEmpty || k.utf8.contains(0) || k.contains("=")
      || v.utf8.contains(0)
    { throw MuxError(.invalidRequest, "invalid environment entry \(k)") }

    var size = winsize(
      ws_row: UInt16(clamping: max(1, rows)),
      ws_col: UInt16(clamping: max(1, columns)),
      ws_xpixel: 0,
      ws_ypixel: 0
    )
    var attrs = Self.interactiveTermios()
    var master: Int32 = -1
    var slave: Int32 = -1
    guard openpty(&master, &slave, nil, &attrs, &size) == 0 else {
      throw MuxError(
        .launchFailed,
        "openpty: \(String(cString: strerror(errno)))"
      )
    }
    _ = fcntl(master, F_SETFD, FD_CLOEXEC)
    _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
    let flags = fcntl(master, F_GETFL)
    _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

    var pipeFDs: [Int32] = [-1, -1]
    guard pipe(&pipeFDs) == 0 else {
      close(master)
      close(slave)
      throw MuxError(.launchFailed, "pipe: \(String(cString: strerror(errno)))")
    }
    _ = fcntl(pipeFDs[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)
    // The child receives the slave as fd 3 and the pipe as fd 4. Sources
    // already at 3 or 4 would collide: `dup2(3, 3)` keeps close-on-exec,
    // and crossed duplicates overwrite each other. Move both above.
    slave = Self.aboveChildDescriptors(slave)
    pipeFDs[1] = Self.aboveChildDescriptors(pipeFDs[1])
    guard slave >= 0, pipeFDs[1] >= 0 else {
      close(master)
      if slave >= 0 { close(slave) }
      close(pipeFDs[0])
      if pipeFDs[1] >= 0 { close(pipeFDs[1]) }
      throw MuxError(.launchFailed, "fcntl: \(String(cString: strerror(errno)))")
    }

    func cleanup() {
      close(master)
      close(slave)
      close(pipeFDs[0])
      if pipeFDs[1] >= 0 { close(pipeFDs[1]) }
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, slave, 3)
    posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], 4)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // No POSIX_SPAWN_SETSID: the launcher creates the one session itself.
    let spawnFlags =
      POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(spawnFlags))
    var all = sigset_t()
    sigfillset(&all)
    posix_spawnattr_setsigdefault(&attributes, &all)
    var none = sigset_t()
    sigemptyset(&none)
    posix_spawnattr_setsigmask(&attributes, &none)

    let launcherArgv = [launcherPath, directory, program] + argv
    let envStrings = env.map { "\($0.key)=\($0.value)" }
    var pid: pid_t = 0
    let status = withCStrings(launcherArgv) { cArgv in
      withCStrings(envStrings) { cEnv in
        posix_spawn(&pid, launcherPath, &actions, &attributes, cArgv, cEnv)
      }
    }
    guard status == 0 else {
      cleanup()
      throw MuxError(
        .launchFailed,
        "spawn \(launcherPath): \(String(cString: strerror(status)))"
      )
    }
    close(pipeFDs[1])
    pipeFDs[1] = -1

    // The launcher either reports and execs (closing the pipe on exec)
    // or reports a failure and exits. EOF alone is not success.
    var report = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
      let n = read(pipeFDs[0], &buffer, buffer.count)
      if n > 0 {
        report.append(contentsOf: buffer[0 ..< n])
        if report.count > 4096 { break }
        continue
      }
      if n < 0, errno == EINTR { continue }
      break
    }
    close(pipeFDs[0])
    let lines = String(decoding: report, as: UTF8.self).split(separator: "\n")
    let failure = lines.first { $0.hasPrefix("E ") }
    let ready = lines.contains { $0.hasPrefix("S ") }
    if let failure = failure ?? (ready ? nil : "E launcher no-report 0") {
      var st: Int32 = 0
      while waitpid(pid, &st, 0) < 0, errno == EINTR {}
      close(master)
      close(slave)
      let parts = failure.split(separator: " ")
      let code = parts.count > 2 ? Int32(parts[2]) ?? 0 : 0
      throw MuxError(
        .launchFailed,
        "\(parts.count > 1 ? parts[1] : "launch"): \(code == 0 ? "failed" : String(cString: strerror(code))) (\(program))"
      )
    }
    let warnings = lines.filter { $0.hasPrefix("W ") }.map(String.init)
    return LaunchedProcess(
      master: master,
      slave: slave,
      pid: pid,
      warnings: warnings
    )
  }

  /// A close-on-exec duplicate of `fd` numbered 5 or higher (closing
  /// `fd`); `fd` itself when it already is. -1 on failure.
  static func aboveChildDescriptors(_ fd: Int32) -> Int32 {
    guard fd < 5 else { return fd }
    let moved = fcntl(fd, F_DUPFD_CLOEXEC, 5)
    close(fd)
    return moved
  }

  /// Cooked interactive settings, matching the BSD `ttydefaults`.
  static func interactiveTermios() -> termios {
    var t = termios()
    t.c_iflag = tcflag_t(BRKINT | ICRNL | IMAXBEL | IXON | IXANY | IUTF8)
    t.c_oflag = tcflag_t(OPOST | ONLCR)
    t.c_cflag = tcflag_t(CREAD | CS8 | HUPCL)
    t.c_lflag = tcflag_t(
      ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOKE | ECHOCTL
    )
    func control(_ c: Character) -> cc_t { cc_t(c.asciiValue! & 0x1F) }
    withUnsafeMutableBytes(of: &t.c_cc) { cc in
      cc[Int(VEOF)] = control("D")
      cc[Int(VEOL)] = 0xFF
      cc[Int(VEOL2)] = 0xFF
      cc[Int(VERASE)] = 0x7F
      cc[Int(VWERASE)] = control("W")
      cc[Int(VKILL)] = control("U")
      cc[Int(VREPRINT)] = control("R")
      cc[Int(VINTR)] = control("C")
      cc[Int(VQUIT)] = 0x1C
      cc[Int(VSUSP)] = control("Z")
      cc[Int(VDSUSP)] = control("Y")
      cc[Int(VSTART)] = control("Q")
      cc[Int(VSTOP)] = control("S")
      cc[Int(VLNEXT)] = control("V")
      cc[Int(VDISCARD)] = control("O")
      cc[Int(VMIN)] = 1
      cc[Int(VTIME)] = 0
      cc[Int(VSTATUS)] = control("T")
    }
    cfsetispeed(&t, speed_t(B38400))
    cfsetospeed(&t, speed_t(B38400))
    return t
  }
}

func withCStrings<R>(
  _ strings: [String],
  _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
  let pointers = strings.map { strdup($0) } + [nil]
  defer { for p in pointers { free(p) } }
  return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
