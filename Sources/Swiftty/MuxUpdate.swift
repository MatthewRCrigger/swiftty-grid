import AppKit
import ServiceManagement
import SwiftMuxClient
import SwiftMuxProtocol

/// The bundled agent through SMAppService; each call awaits completion.
struct SMAppServiceRegistration: AgentRegistration {
  func unregister() async throws {
    try await SMAppService.agent(plistName: SMX.agentPlistName).unregister()
  }

  func register() async throws {
    try SMAppService.agent(plistName: SMX.agentPlistName).register()
  }
}

/// Stages and installs Swiftty updates without replacing the bundle under
/// a live service (spec §8).
@MainActor
final class MuxUpdateController {
  private let coordinator = UpdateCoordinator(
    connect: { try await MuxConnection.connect(frontend: .control) },
    registration: SMAppServiceRegistration(),
    replace: { staged in
      let current = Bundle.main.bundleURL
      _ = try FileManager.default.replaceItemAt(
        current,
        withItemAt: staged,
        backupItemName: nil,
        options: [.usingNewMetadataOnly]
      )
    }
  )
  private(set) var staged: URL?

  /// Staging alone changes neither admission nor the installed bundle.
  func stage() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.message = "Choose the updated Swiftty.app"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    staged = url
    Task { await coordinator.stage(url) }
  }

  /// Installs once the service reaches its empty-state barrier.
  func install(detachFirst: @escaping () async -> Void) {
    guard staged != nil else {
      NSAlert.show("No update is staged.", "Choose “Stage Update…” first.")
      return
    }
    let alert = NSAlert()
    alert.messageText = "Install the staged Swiftty update?"
    alert.informativeText =
      "The SwiftMux helper is replaced only when no terminal sessions remain. Ending workspaces terminates their programs."
    alert.addButton(withTitle: "Update When Sessions End")
    alert.addButton(withTitle: "End Workspaces and Update")
    alert.addButton(withTitle: "Cancel")
    let choice = alert.runModal()
    guard choice != .alertThirdButtonReturn else { return }
    let endWorkspaces = choice == .alertSecondButtonReturn
    let coordinator = coordinator
    Task {
      await detachFirst()
      let phase = await coordinator.install(endWorkspaces: endWorkspaces)
      switch phase {
      case .finished:
        NSAlert.show(
          "Swiftty was updated.",
          "Relaunch Swiftty to use the new version."
        )
      case .cancelled:
        NSAlert.show("Update cancelled.", "Sessions continue normally.")
      case let .failed(reason):
        NSAlert.show("The update did not install.", reason)
      default: break
      }
    }
  }

  func cancel() { Task { await coordinator.cancel() } }
}

extension NSAlert {
  static func show(_ message: String, _ information: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = information
    alert.runModal()
  }
}
