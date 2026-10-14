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
  private let coordinator: UpdateCoordinator
  private let selectBundle: @MainActor () -> URL?
  private let confirmInstall: @MainActor () -> Bool?
  private let report: @MainActor (String, String) -> Void
  private let validateBundle: @MainActor (URL) throws -> Void

  init(
    coordinator: UpdateCoordinator? = nil,
    selectBundle: @escaping @MainActor () -> URL? = MuxUpdateController
      .chooseBundle,
    confirmInstall: @escaping @MainActor () -> Bool? = MuxUpdateController
      .chooseInstall,
    report: @escaping @MainActor (String, String) -> Void = NSAlert.show,
    currentBundle: URL = Bundle.main.bundleURL,
    validateBundle: (@MainActor (URL) throws -> Void)? = nil
  ) {
    self.selectBundle = selectBundle
    self.confirmInstall = confirmInstall
    self.report = report
    self.validateBundle =
      validateBundle ?? {
        try MuxUpdateBundle.validate($0, replacing: currentBundle)
      }
    self.coordinator =
      coordinator
      ?? UpdateCoordinator(
        connect: { try await MuxConnection.connect(frontend: .control) },
        registration: SMAppServiceRegistration(),
        replace: { staged in
          let current = currentBundle
          try MuxUpdateBundle.validate(staged, replacing: current)
          _ = try FileManager.default.replaceItemAt(
            current,
            withItemAt: staged,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
          )
        },
        validate: { try MuxUpdateBundle.validate($0, replacing: currentBundle) }
      )
  }
  private(set) var staged: URL?
  private(set) var installing = false
  private var installTask: Task<Void, Never>?
  private var cancelTask: Task<Void, Never>?
  private var cancelRequested = false

  /// Staging alone changes neither admission nor the installed bundle.
  func stage() {
    guard !installing, let url = selectBundle(), !installing else { return }
    do { try validateBundle(url) } catch {
      report("Cannot stage this update.", String(describing: error))
      return
    }
    staged = url
  }

  /// Installs once the service reaches its empty-state barrier.
  func install(detachFirst: @escaping @MainActor () async -> Void) {
    guard !installing else { return }
    guard let bundle = staged else {
      report("No update is staged.", "Choose “Stage Update…” first.")
      return
    }
    do { try validateBundle(bundle) } catch {
      report("The staged update is not ready.", String(describing: error))
      return
    }
    // Modal confirmation runs a nested event loop. Reserve the operation
    // before presenting it so reentrant actions cannot stage or detach.
    installing = true
    cancelRequested = false
    guard let endWorkspaces = confirmInstall(), !cancelRequested else {
      installing = false
      return
    }
    let coordinator = coordinator
    installTask = Task {
      defer {
        installTask = nil
        cancelTask = nil
        installing = false
      }
      let phase: UpdateCoordinator.Phase
      if cancelRequested {
        phase = .cancelled
      } else {
        await coordinator.stage(bundle)
        if !cancelRequested { await detachFirst() }
        phase =
          cancelRequested
          ? .cancelled : await coordinator.install(endWorkspaces: endWorkspaces)
      }
      // Finish this operation's cancellation before allowing a retry.
      // Result dialogs must not enqueue cancellation for a future install.
      installTask = nil
      await cancelTask?.value
      switch phase {
      case .finished:
        report(
          "Swiftty was updated.",
          "Relaunch Swiftty to use the new version."
        )
      case .cancelled:
        report("Update cancelled.", "The staged update was not installed.")
      case let .failed(reason): report("The update did not install.", reason)
      default: break
      }
    }
  }

  func cancel() {
    guard installing else { return }
    cancelRequested = true
    // Detaching precedes the coordinator's install call. Cancel that
    // owned wait too; the coordinator protects its committed transaction.
    installTask?.cancel()
    guard installTask != nil, cancelTask == nil else { return }
    cancelTask = Task { await coordinator.cancel() }
  }

  private static func chooseBundle() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.message = "Choose the updated Swiftty.app"
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  private static func chooseInstall() -> Bool? {
    let alert = NSAlert()
    alert.messageText = "Install the staged Swiftty update?"
    alert.informativeText =
      "The SwiftMux helper is replaced only when no terminal sessions remain. Ending workspaces terminates their programs."
    alert.addButton(withTitle: "Update When Sessions End")
    alert.addButton(withTitle: "End Workspaces and Update")
    alert.addButton(withTitle: "Cancel")
    let choice = alert.runModal()
    guard choice != .alertThirdButtonReturn else { return nil }
    return choice == .alertSecondButtonReturn
  }
}

extension NSAlert {
  static func show(_ message: String, _ information: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = information
    alert.runModal()
  }
}
