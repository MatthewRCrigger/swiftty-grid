#if os(macOS)
import Darwin
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import TerminalHost

/// `swifttyd` subcommands. Diagnostics go to stderr only; in bootstrap
/// mode stdout carries exactly one response envelope.
enum SwifttydCommand {
  static let usage = """
    usage: swifttyd bootstrap --stdio
           swifttyd serve [--config <path>]
           swifttyd install [--config <path>]
           swifttyd uninstall
           swifttyd status
    """

  static func run(_ arguments: [String]) -> Int32 {
    guard getuid() != 0 else {
      diagnose("swifttyd must not run as root")
      return 1
    }
    switch arguments.first {
    case "bootstrap" where arguments.dropFirst() == ["--stdio"]:
      return bootstrap()
    case "serve":
      guard let config = configurationPath(arguments.dropFirst()) else {
        return usageError()
      }
      return serve(configurationPath: config)
    case "install":
      guard let config = configurationPath(arguments.dropFirst()) else {
        return usageError()
      }
      return install(configurationPath: config)
    case "uninstall" where arguments.count == 1: return uninstall()
    case "status" where arguments.count == 1: return status()
    default: return usageError()
    }
  }

  private static func usageError() -> Int32 {
    diagnose(usage)
    return 64
  }

  /// `[--config <path>]`; nil when the arguments are malformed.
  private static func configurationPath(
    _ arguments: ArraySlice<String>
  ) -> String?? {
    if arguments.isEmpty { return .some(nil) }
    guard arguments.count == 2, arguments.first == "--config",
      let path = arguments.last, !path.isEmpty
    else { return nil }
    return .some(path)
  }

  static func diagnose(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }

  // MARK: bootstrap --stdio

  private static func bootstrap() -> Int32 {
    let response: [UInt8]
    do {
      let request = try BootstrapService.readEnvelope(from: STDIN_FILENO)
      let directory =
        (try? HostConfiguration.load(
          from: LaunchAgent.resolvedConfigurationURL()
        ))?.stateDirectoryURL ?? ControlDirectory.defaultURL
      response = BootstrapService.forward(
        envelope: request,
        socketPath: directory.appendingPathComponent("control.sock").path
      )
    } catch {
      response =
        (try? BootstrapEnvelope.encode(
          BootstrapResponse.failure(.malformed)
        )) ?? []
    }
    FileHandle.standardOutput.write(Data(response))
    return 0
  }

  // MARK: serve

  private static func serve(configurationPath: String?) -> Int32 {
    let url =
      configurationPath.map { URL(fileURLWithPath: $0) }
      ?? HostConfiguration.defaultConfigurationURL
    let config: HostConfiguration
    do {
      config = try HostConfiguration.load(from: url)
    } catch {
      diagnose(
        "swifttyd: cannot read configuration at \(url.path); "
          + "bindAddress and advertisedHost must be set explicitly"
      )
      return 78
    }
    do {
      try ControlDirectory.prepare(config.stateDirectoryURL)
      let bootstrapConfig = LaunchAgent.resolvedConfigurationURL()
      if bootstrapConfig.standardizedFileURL != url.standardizedFileURL,
        (try? HostConfiguration.load(from: bootstrapConfig))?.stateDirectoryURL
          .standardizedFileURL != config.stateDirectoryURL.standardizedFileURL
      {
        // Still serves (tests, manual runs) but says why SSH bootstrap
        // will not reach this agent.
        diagnose(
          "swifttyd: warning: bootstrap --stdio uses \(bootstrapConfig.path); "
            + "install with this --config to make it reachable over SSH"
        )
      }
      let (listener, certificate) = try makeTransport(config: config)
      // Bind first: the grant advertises the listener's actual port.
      let accepted = AcceptTarget()
      try blockingWait {
        try await listener.start { connection in
          accepted.registry.withLock { $0 }?.accept(connection)
        }
      }
      let registry = SessionRegistry(
        identity: TerminalHost.HostIdentity(
          endpoint: BootstrapEndpoint(
            host: config.advertisedHost,
            port: listener.port
          ),
          certificate: certificate
        )
      )
      accepted.registry.withLock { $0 = registry }
      let service = BootstrapService(registry: registry)
      let control = try ControlSocketServer(
        directory: config.stateDirectoryURL
      ) { request in await service.respond(toEnvelope: request) }
      try control.start()
      registry.startSweeping()
      // Keep the agent objects alive for the process lifetime.
      Agent.retained = (registry, control, listener)
      dispatchMain()
    } catch {
      diagnose("swifttyd: \(error)")
      return 1
    }
  }

  private enum Agent {
    nonisolated(unsafe) static var retained: Any?
  }

  // MARK: install / uninstall / status

  private static func install(configurationPath: String?) -> Int32 {
    guard let executable = Bundle.main.executablePath else {
      diagnose("swifttyd: cannot determine executable path")
      return 1
    }
    let agent = LaunchAgent(
      executable: URL(fileURLWithPath: executable).resolvingSymlinksInPath()
        .path,
      configurationPath: configurationPath.map {
        URL(fileURLWithPath: $0).standardizedFileURL.path
      }
    )
    do {
      try FileManager.default.createDirectory(
        at: LaunchAgent.agentsDirectory,
        withIntermediateDirectories: true
      )
      try agent.propertyList().write(to: agent.plistURL, options: .atomic)
      chmod(agent.plistURL.path, 0o644)
    } catch {
      diagnose("swifttyd: cannot write \(agent.plistURL.path)")
      return 1
    }
    _ = launchctl(["bootout", agent.serviceTarget()])
    guard
      launchctl(["bootstrap", "gui/\(getuid())", agent.plistURL.path]) == 0
    else {
      diagnose("swifttyd: launchctl bootstrap failed")
      return 1
    }
    return status()
  }

  private static func uninstall() -> Int32 {
    let agent = LaunchAgent(executable: "")
    _ = launchctl(["bootout", agent.serviceTarget()])
    try? FileManager.default.removeItem(at: agent.plistURL)
    return 0
  }

  /// Validates that the per-user agent is loaded.
  private static func status() -> Int32 {
    let agent = LaunchAgent(executable: "")
    if launchctl(["print", agent.serviceTarget()]) == 0 {
      diagnose("swifttyd: \(agent.label) is loaded")
      return 0
    }
    diagnose("swifttyd: \(agent.label) is not loaded")
    return 3
  }

  private static func launchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
  }
}

/// Routes accepted connections to the registry once it exists.
final class AcceptTarget: Sendable {
  let registry = Mutex<SessionRegistry?>(nil)
}

/// Runs async setup from the synchronous command entry point.
func blockingWait(_ body: @escaping @Sendable () async throws -> Void) throws {
  let result = Mutex<Result<Void, any Error>?>(nil)
  let done = DispatchSemaphore(value: 0)
  Task {
    do { try await body(); result.withLock { $0 = .success(()) } } catch {
      result.withLock { $0 = .failure(error) }
    }
    done.signal()
  }
  done.wait()
  try result.withLock { $0 }!.get()
}
#endif
