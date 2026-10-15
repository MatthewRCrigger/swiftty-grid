import Foundation
import SwiftMuxProtocol
import SwifttyCore

/// Configuration to `LaunchSpec` for a new workspace's first shell, with
/// the direct-window rules (`Configuration.sessionConfiguration`):
///
/// - `command`: Ghostty syntax (`shell:` expansion or `direct:` arguments);
///   unset runs the login shell.
/// - `working-directory`: an explicit path, `home`, or `inherit`. `inherit`
///   (and the unset default for a command-line launch) resolves here, to
///   this frontend's current directory: the agent runs elsewhere.
/// - Environment: this frontend's, snapshotted; the service still sets the
///   terminal variables it requires (`TERM`, `COLORTERM`, …) over it.
///
/// New tabs reuse the workspace's spec and splits keep the split pane's
/// directory and environment with a login shell (service-side rules).
/// `scrollback-limit` is not carried: the service applies its own history
/// limits to every pane, whichever frontend created it.
enum WorkspaceLaunch {
  static let columns = 100
  static let rows = 30

  static func spec(
    _ configuration: Configuration,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectory: String = FileManager.default.currentDirectoryPath
  ) -> LaunchSpec {
    let session = configuration.sessionConfiguration()
    return LaunchSpec(
      command: session.command,
      workingDirectory: session.workingDirectory ?? currentDirectory,
      environment: environment
    )
  }

  static func request(
    _ configuration: Configuration,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    currentDirectory: String = FileManager.default.currentDirectoryPath
  ) -> NewWorkspaceRequest {
    NewWorkspaceRequest(
      columns: columns,
      rows: rows,
      launch: spec(
        configuration,
        environment: environment,
        currentDirectory: currentDirectory
      )
    )
  }
}
