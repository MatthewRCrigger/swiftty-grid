import AppKit
import ServiceManagement
import SwiftMuxClient
import SwiftMuxProtocol
import SwifttyCore

extension MuxWorkspaceController {
  static func makeWorkspaceWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "SwiftMux"
    window.tabbingMode = .disallowed
    window.center()
    return window
  }

  /// Attaches to `selector` (creating a workspace when nil) in a new window.
  static func open(
    _ selector: WorkspaceSelector?,
    configuration: Configuration,
    createConnection: @MainActor () async throws -> MuxConnection = {
      try await connect()
    },
    beforeReturnForTesting: (
      @MainActor (MuxWorkspaceController) async -> Void
    )? = nil,
  ) async throws -> MuxWorkspaceController {
    try Task.checkCancellation()
    let connection = try await createConnection()
    do {
      return try await open(
        selector,
        configuration: configuration,
        connection: connection,
        beforeReturnForTesting: beforeReturnForTesting,
      )
    } catch {
      await connection.close()
      throw error
    }
  }

  // MARK: Service connection

  enum ServiceState: Equatable {
    case available
    case requiresApproval
    case unavailable(String)
  }

  /// Registers the bundled agent when running from an app bundle and
  /// reports its state; never starts a second service on its own.
  static func ensureAgent() -> ServiceState {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      return .available
    }
    let service = SMAppService.agent(plistName: SMX.agentPlistName)
    switch service.status {
    case .enabled: return .available
    case .requiresApproval: return .requiresApproval
    case .notFound:
      return .unavailable(
        "The SwiftMux helper is missing from this app bundle."
      )
    case .notRegistered:
      do {
        try service.register()
        return service.status == .requiresApproval
          ? .requiresApproval : .available
      } catch {
        return .unavailable(
          "Registering the SwiftMux helper failed: \(error.localizedDescription)"
        )
      }
    @unknown default: return .unavailable("Unknown SwiftMux helper state.")
    }
  }

  static func connect(
    createConnection: @MainActor () async throws -> MuxConnection = {
      try await MuxConnection.connect(frontend: .native)
    }
  ) async throws -> MuxConnection {
    try Task.checkCancellation()
    switch ensureAgent() {
    case .available: break
    case .requiresApproval:
      SMAppService.openSystemSettingsLoginItems()
      throw MuxUnavailable(
        message:
          "Allow the SwiftMux helper in System Settings › Login Items. It keeps terminals running after Swiftty closes.",
      )
    case let .unavailable(reason): throw MuxUnavailable(message: reason)
    }
    do { return try await createConnection() } catch is CancellationError {
      throw CancellationError()
    } catch let error as MuxError where error.code == .incompatibleVersion {
      // Preserve the running service and its sessions.
      throw MuxUnavailable(
        message: "The running SwiftMux service is a different version "
          + "(\(error.message)). Reopen the Swiftty version that started "
          + "it, or end its sessions with `swmux end-all` before updating.",
      )
    } catch {
      // A bundled agent registered under another signing team is killed
      // at launch (launch constraint) until it is registered again.
      let remedy =
        Bundle.main.bundleURL.pathExtension == "app"
        ? "If Swiftty was re-signed, reinstall it with Scripts/install.sh "
          + "or run `swiftty --swiftmux-agent unregister`, then reopen Swiftty."
        : "Install it with `swmux agent install`."
      throw MuxUnavailable(
        message: "SwiftMux service unavailable (\(error)). \(remedy)",
      )
    }
  }

  /// Workspaces known to the service (no lease needed).
  static func listWorkspaces(
    createConnection: @MainActor () async throws -> MuxConnection = {
      try await connect()
    }
  ) async throws -> [WorkspaceSummary] {
    let connection = try await createConnection()
    do {
      // An interactive chooser must return control if the service stops replying.
      let reply = try await connection.execute(
        .listWorkspaces,
        timeout: .seconds(5)
      )
      guard case let .workspaces(list) = reply else {
        throw MuxError(.invalidRequest, "unexpected workspace-list reply")
      }
      await connection.close()
      return list
    } catch {
      await connection.close()
      throw error
    }
  }

  /// Opens `selector` on the new `connection` and only then leaves
  /// `current` (one SwiftMux window and lease at a time). A failed attach
  /// (`leaseHeld` before a confirmed takeover, `staleRevision`, …)
  /// closes `connection` and leaves `current` with its window and lease.
  static func replace(
    _ current: MuxWorkspaceController?,
    with selector: WorkspaceSelector,
    configuration: Configuration,
    connection: MuxConnection,
    takeover expectedLease: UInt64? = nil,
  ) async throws -> MuxWorkspaceController {
    let controller: MuxWorkspaceController
    do {
      guard current?.isClosed != true else { throw CancellationError() }
      controller = try await open(
        selector,
        configuration: configuration,
        connection: connection,
        takeover: expectedLease,
      )
    } catch {
      await connection.close()
      throw error
    }
    do {
      try Task.checkCancellation()
      if let current {
        guard !current.isClosed else { throw CancellationError() }
        await current.detach()
        try Task.checkCancellation()
        current.close()
      }
    } catch {
      await controller.detach()
      controller.close()
      throw error
    }
    return controller
  }

  func notice(_ message: String) {
    if let hook = confirmDestructive {
      Task { _ = await hook(message) }
      return
    }
    let alert = NSAlert()
    alert.messageText = message
    if let window {
      alert.beginSheetModal(for: window)
    } else {
      alert.runModal()
    }
  }

}
