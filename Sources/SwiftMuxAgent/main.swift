// swiftmux-agent: the per-user SwiftMux LaunchAgent.
//
// Runs directly under launchd (no self-forking or daemonization) and
// serves one Mach/XPC endpoint. With a roaming configuration it also
// serves remote clients (SSH bootstrap + QUIC RST/1) from the same
// process, so local and remote attachments share one set of panes
// (unified spec §1). It exits only at the ordered empty-state barrier,
// after an idle delay that respects launchd's launch throttling, and
// never while serving roaming clients.
import Darwin
import Foundation
import Security
import SwiftMuxProtocol
import SwiftMuxService
import TerminalHost

func usage() -> Never {
  FileHandle.standardError.write(
    Data(
      """
      usage: swiftmux-agent [--mach-service NAME] [--launcher PATH] [--idle-exit SECONDS|never]
                            [--roaming-config PATH | --no-roaming]

      """
      .utf8
    )
  )
  exit(64)
}

var machService =
  ProcessInfo.processInfo.environment["SWMUX_SERVICE"] ?? SMX.defaultMachService
var launcherPath: String?
var idleExit: TimeInterval? = 30
/// Explicit path, or the default location when that file exists.
var roamingConfig: URL? = {
  let url = HostConfiguration.resolvedConfigurationURL()
  return FileManager.default.fileExists(atPath: url.path) ? url : nil
}()
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
  switch arg {
  case "--mach-service":
    guard let value = args.popFirst() else { usage() }
    machService = value
  case "--launcher":
    guard let value = args.popFirst() else { usage() }
    launcherPath = value
  case "--idle-exit":
    guard let value = args.popFirst() else { usage() }
    if value == "never" {
      idleExit = nil
    } else {
      guard let seconds = TimeInterval(value) else { usage() }
      idleExit = seconds
    }
  case "--roaming-config":
    guard let value = args.popFirst() else { usage() }
    roamingConfig = URL(fileURLWithPath: value)
  case "--no-roaming": roamingConfig = nil
  default: usage()
  }
}

/// The launcher ships beside the agent (Contents/MacOS in the app bundle).
func siblingLauncher() -> String {
  let exe =
    Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
  return exe.resolvingSymlinksInPath().deletingLastPathComponent()
    .appending(path: "swmux-launcher").path
}

/// Peers must share this agent's signing team when it has one. Ad-hoc
/// development builds fall back to the same-user check alone.
func peerRequirement() -> String? {
  var code: SecCode?
  guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
    return nil
  }
  var staticCode: SecStaticCode?
  guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
    let staticCode
  else { return nil }
  var info: CFDictionary?
  guard
    SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &info
    ) == errSecSuccess, let dict = info as? [String: Any],
    let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
    !team.isEmpty
  else { return nil }
  return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
}

let launcher = launcherPath ?? siblingLauncher()
guard FileManager.default.isExecutableFile(atPath: launcher) else {
  FileHandle.standardError.write(
    Data("swiftmux-agent: launcher not found at \(launcher)\n".utf8)
  )
  exit(69)
}

var configuration = MuxServiceConfiguration(launcherPath: launcher)
let terminfo = InnerTerminfo.defaultDirectory
if InnerTerminfo.install(into: terminfo) {
  configuration.innerTerm = SMX.innerTerm
  configuration.terminfoDirectory = terminfo.path
}
configuration.peerRequirement = peerRequirement()
// Remote clients need the listener up while no local client is around.
configuration.idleExitDelay = roamingConfig == nil ? idleExit : nil

// Never let SIGPIPE from a closed peer or PTY kill the service.
signal(SIGPIPE, SIG_IGN)
let service = MuxService(configuration: configuration)
service.listen(machService: machService)
service.setIdleHandler { exit(0) }

enum Roaming {
  nonisolated(unsafe) static var host: RoamingHost?
}

if let roamingConfig {
  let config: HostConfiguration
  do {
    config = try HostConfiguration.load(from: roamingConfig)
  } catch {
    FileHandle.standardError.write(
      Data(
        "swiftmux-agent: cannot read roaming configuration at \(roamingConfig.path); bindAddress and advertisedHost must be set explicitly\n"
          .utf8
      )
    )
    exit(78)
  }
  Task {
    do {
      Roaming.host = try await RoamingHost.start(
        service: service,
        configuration: config
      )
    } catch {
      FileHandle.standardError.write(
        Data("swiftmux-agent: roaming unavailable: \(error)\n".utf8)
      )
      exit(1)
    }
  }
}
dispatchMain()
