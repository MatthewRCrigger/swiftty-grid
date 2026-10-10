// swmux: the SwiftMux terminal client for Swiftty.
import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxTerminal

let usage = """
  usage: swmux [command] [options]

    (no command)                 attach to the newest workspace, or create one
    new [-s NAME] [-c DIR] [-d] [-- COMMAND...]
                                 create a workspace (and attach unless -d)
    attach [-t NAME]             attach to a workspace
    list | ls                    list workspaces
    detach                       release the active attachment
    end -t NAME                  end a workspace and its processes
    end-all                      end every workspace
    status                       show service status
    agent install|uninstall|status
                                 manage a development LaunchAgent (the app
                                 bundle registers its own with SMAppService)

  options: --allow-host  run outside the supported Swiftty host profile

  """

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("swmux: \(message)\n".utf8))
  exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let allowHost = arguments.contains("--allow-host")
arguments.removeAll { $0 == "--allow-host" }
let command = arguments.first.map { $0.hasPrefix("-") ? "" : $0 } ?? ""
var rest = command.isEmpty ? arguments : Array(arguments.dropFirst())

@MainActor
func option(_ flag: String) -> String? {
  guard let i = rest.firstIndex(of: flag), i + 1 < rest.count else {
    return nil
  }
  let value = rest[i + 1]
  rest.removeSubrange(i ... i + 1)
  return value
}

@MainActor
func flag(_ name: String) -> Bool {
  guard let i = rest.firstIndex(of: name) else { return false }
  rest.remove(at: i)
  return true
}

func connect(_ kind: FrontendKind) async -> MuxConnection {
  do {
    return try await MuxConnection.connect(
      frontend: kind,
      terminalProfile: kind == .terminal ? SMX.terminalProfile : nil
    )
  } catch let error as MuxError where error.code == .connectionLost {
    fail(
      """
      the SwiftMux service is unavailable (\(error.message)).
      Open Swiftty to enable its background item, or for a development build run:
        swmux agent install
      """,
      code: 69
    )
  } catch { fail("\(error)", code: 69) }
}

/// The terminal frontend supports one pinned host profile.
@MainActor
func checkHost() {
  guard !allowHost else { return }
  let env = ProcessInfo.processInfo.environment
  guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
    fail("attach needs a terminal")
  }
  guard env["TERM_PROGRAM"] == "swiftty" else {
    fail(
      "swmux supports only the Swiftty terminal (\(SMX.terminalProfile)); TERM_PROGRAM is \(env["TERM_PROGRAM"] ?? "unset"). Use --allow-host to try anyway."
    )
  }
  if env["SWMUX"] != nil { fail("already inside a swmux pane") }
}

func attach(
  _ selector: WorkspaceSelector,
  connection: MuxConnection
) async -> Never {
  let settings: Settings
  do { settings = try Settings.load() } catch { fail("settings: \(error)") }
  let reply: MuxReply
  do { reply = try await connection.execute(.attach(selector)) } catch {
    fail("\(error)")
  }
  guard case let .attached(attachment, workspace) = reply else {
    fail("unexpected reply")
  }
  let limits = await connection.welcome?.limits ?? .standard
  let outcome =
    await MainActor.run {
      TerminalClient(
        connection: connection,
        attachment: attachment,
        workspace: workspace,
        limits: limits,
        settings: settings
      )
    }
    .run()
  switch outcome {
  case let .detached(reason):
    print("[\(reason)]")
    exit(0)
  case let .lost(reason): fail("connection to the service was lost: \(reason)")
  case let .failed(reason): fail(reason)
  }
}

func environmentSnapshot() -> [String: String] {
  var env = ProcessInfo.processInfo.environment
  for key in [
    "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM", "SWMUX",
    "SWMUX_PANE",
  ] { env.removeValue(forKey: key) }
  return env
}

func newWorkspace(
  _ connection: MuxConnection,
  name: String?,
  directory: String?,
  command: [String]?
) async -> WorkspaceSnapshot {
  let settings = (try? Settings.load()) ?? Settings()
  var ws = winsize()
  let size =
    ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0
    ? (Int(ws.ws_col), max(1, Int(ws.ws_row) - 1)) : (80, 23)
  let request = NewWorkspaceRequest(
    name: name,
    columns: size.0,
    rows: size.1,
    launch: LaunchSpec(
      command: command,
      workingDirectory: directory ?? FileManager.default.currentDirectoryPath,
      environment: environmentSnapshot()
    ),
    remainOnExit: settings.remainOnExit
  )
  do {
    guard
      case let .created(snapshot) = try await connection.execute(
        .newWorkspace(request)
      )
    else { fail("unexpected reply") }
    return snapshot
  } catch { fail("\(error)") }
}

func formatList(_ list: [WorkspaceSummary]) -> String {
  guard !list.isEmpty else { return "no workspaces" }
  let formatter = DateFormatter()
  formatter.dateStyle = .short
  formatter.timeStyle = .short
  return
    list.map { ws in
      let tabs = "\(ws.tabCount) tab\(ws.tabCount == 1 ? "" : "s")"
      let panes = "\(ws.paneCount) pane\(ws.paneCount == 1 ? "" : "s")"
      let created = formatter.string(from: ws.createdAt)
      return "\(ws.name): \(tabs), \(panes) (created \(created))"
        + (ws.isAttached ? " (attached)" : "")
    }
    .joined(separator: "\n")
}

// MARK: Development LaunchAgent

func agentCommand(_ sub: String) -> Never {
  let label = SMX.defaultMachService
  let plist = FileManager.default.homeDirectoryForCurrentUser.appending(
    path: "Library/LaunchAgents/\(label).plist"
  )
  let domain = "gui/\(getuid())"
  func launchctl(_ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }
  switch sub {
  case "install":
    let exe = URL(fileURLWithPath: CommandLine.arguments[0])
      .resolvingSymlinksInPath()
    let agent = exe.deletingLastPathComponent()
      .appending(path: "swiftmux-agent").path
    guard FileManager.default.isExecutableFile(atPath: agent) else {
      fail("swiftmux-agent not found next to swmux (\(agent))")
    }
    let contents = AgentPlist.contents(label: label, program: agent)
    do {
      try FileManager.default.createDirectory(
        at: plist.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try contents.write(to: plist, atomically: true, encoding: .utf8)
    } catch { fail("writing \(plist.path): \(error)") }
    _ = launchctl(["bootout", "\(domain)/\(label)"])
    guard launchctl(["bootstrap", domain, plist.path]) == 0 else {
      fail("launchctl bootstrap failed")
    }
    print("installed \(plist.path) -> \(agent)")
    exit(0)
  case "uninstall":
    _ = launchctl(["bootout", "\(domain)/\(label)"])
    try? FileManager.default.removeItem(at: plist)
    print("removed \(label); running sessions ended with the agent")
    exit(0)
  case "status":
    let loaded = launchctl(["print", "\(domain)/\(label)"]) == 0
    print(
      "\(label): \(loaded ? "loaded" : "not loaded")\(FileManager.default.fileExists(atPath: plist.path) ? " (\(plist.path))" : "")"
    )
    exit(0)
  default: fail("usage: swmux agent install|uninstall|status")
  }
}

// MARK: Dispatch

signal(SIGPIPE, SIG_IGN)
switch command {
case "help", "-h", "--help": print(usage, terminator: "")
case "--version", "version":
  print("swmux \(SMX.build) (SMX/\(SMX.protocolVersion))")
case "agent": agentCommand(rest.first ?? "")
case "list", "ls":
  let c = await connect(.control)
  guard case let .workspaces(list) = try await c.execute(.listWorkspaces) else {
    exit(1)
  }
  print(formatList(list))
case "status":
  let c = await connect(.control)
  guard case let .status(s) = try await c.execute(.status) else { exit(1) }
  print(
    """
    service \(s.server.short) (\(s.build), pid \(s.pid)) since \(s.startedAt)
    \(s.workspaces) workspace(s), \(s.panes) pane(s), \(s.attached ? "attached" : "detached")\(s.quiescing ? ", quiescing" : "")
    inner TERM \(s.innerTerm)
    """
  )
case "detach":
  let c = await connect(.control)
  _ = try await c.execute(.detachActive)
case "end", "kill":
  guard let name = option("-t") else { fail("end requires -t NAME") }
  let c = await connect(.control)
  do { _ = try await c.execute(.endWorkspace(.name(name))) } catch {
    fail("\(error)")
  }
case "end-all":
  let c = await connect(.control)
  _ = try await c.execute(.endAllWorkspaces)
  _ = try await c.execute(.quiesce(false))
case "new":
  let detached = flag("-d")
  let name = option("-s")
  let dir = option("-c")
  var cmd: [String]?
  if let i = rest.firstIndex(of: "--") { cmd = Array(rest[(i + 1)...]) }
  if !detached { checkHost() }
  let c = await connect(detached ? .control : .terminal)
  let ws = await newWorkspace(
    c,
    name: name,
    directory: dir,
    command: cmd?.isEmpty == true ? nil : cmd
  )
  if detached {
    print("created \(ws.name)")
    exit(0)
  }
  await attach(.id(ws.id), connection: c)
case "attach", "a":
  checkHost()
  let target = option("-t")
  let c = await connect(.terminal)
  await attach(target.map { .name($0) } ?? .latest, connection: c)
case "":
  checkHost()
  let c = await connect(.terminal)
  guard case let .workspaces(list) = try await c.execute(.listWorkspaces) else {
    exit(1)
  }
  if let latest = list.last { await attach(.id(latest.id), connection: c) }
  let ws = await newWorkspace(c, name: nil, directory: nil, command: nil)
  await attach(.id(ws.id), connection: c)
default:
  FileHandle.standardError.write(Data(usage.utf8))
  exit(64)
}
