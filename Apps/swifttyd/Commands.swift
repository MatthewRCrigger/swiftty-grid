#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import SessionCore
import TerminalHost

/// `swifttyd`: the fixed, no-PTY SSH bootstrap helper (unified spec §7).
/// sshd runs it as the authenticated user; it relays one bounded request
/// envelope to the SwiftMux service's control socket and prints the
/// response. It owns no sessions: the SwiftMux service (`swiftmux-agent`,
/// started with a roaming configuration) is the only PTY owner.
/// Diagnostics go to stderr only; stdout carries exactly one envelope.
enum SwifttydCommand {
  static let usage = """
    usage: swifttyd bootstrap --stdio
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
    case "status" where arguments.count == 1: return status()
    default:
      diagnose(usage)
      return 64
    }
  }

  static func diagnose(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }

  private static var socketPath: String {
    let directory =
      (try? HostConfiguration.load(
        from: HostConfiguration.resolvedConfigurationURL()
      ))?.stateDirectoryURL ?? ControlDirectory.defaultURL
    return directory.appendingPathComponent("control.sock").path
  }

  // MARK: bootstrap --stdio

  private static func bootstrap() -> Int32 {
    let response: [UInt8]
    do {
      let request = try BootstrapService.readEnvelope(from: STDIN_FILENO)
      response = BootstrapService.forward(
        envelope: request,
        socketPath: socketPath
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

  // MARK: status

  /// Asks the service for its session list: proves the control socket
  /// answers for this user.
  private static func status() -> Int32 {
    guard
      let request = try? BootstrapEnvelope.encode(
        BootstrapRequest(operation: .list)
      )
    else { return 1 }
    let reply = BootstrapService.forward(envelope: request, socketPath: socketPath)
    guard
      let response = try? BootstrapEnvelope.decode(
        BootstrapResponse.self,
        from: reply
      ), case let .sessions(list) = response
    else {
      diagnose("swifttyd: the SwiftMux service is not serving roaming clients")
      return 3
    }
    diagnose("swifttyd: SwiftMux roaming is available (\(list.count) workspaces)")
    return 0
  }
}
#endif
