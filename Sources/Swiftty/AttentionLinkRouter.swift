import AppKit
import MuxNavigation
import MuxNavigationSMX
import SwiftMuxProtocol
import SwifttyCore

/// Routes `swiftty://attention/open?ref=…` (and configured Universal
/// Links) into the attention navigator and renders its states as alerts
/// (swiftty-unified-spec.md §9). The native app has one host: this Mac's
/// SwiftMux service over local XPC.
@MainActor
final class AttentionLinkRouter {
  /// This Mac as a navigation host. Its ID is per-install, so links made
  /// here map back to it; links made elsewhere ask the user to choose.
  static let thisMac = NavigationHost(id: localHostID(), name: "This Mac")

  private let navigator: AttentionNavigator
  /// Whether this app's own window already holds `workspace`'s lease.
  private let ownsWorkspace: @MainActor (WorkspaceID) -> Bool
  /// The last state rendered, so one state never shows two alerts.
  private var shown: AttentionNavigationState?

  /// `reveal` opens the workspace window (explicitly taking over when
  /// given a lease generation) and activates the pane.
  init(
    ownsWorkspace: @escaping @MainActor (WorkspaceID) -> Bool,
    reveal: @escaping @MainActor @Sendable (PaneTarget, UInt64?) async throws -> Void
  ) {
    self.ownsWorkspace = ownsWorkspace
    let opener = Opener(reveal: reveal)
    navigator = AttentionNavigator(
      configuration: AttentionLinkConfiguration(
        infoDictionary: Bundle.main.infoDictionary
      ),
      hosts: StaticHostDirectory([Self.thisMac]),
      connector: SMXAttentionConnector(opener: opener) {
        try await MuxWorkspaceController.connect()
      }
    )
    navigator.onStateChange = { [weak self] state in
      self?.schedule(state)
    }
  }

  func handle(_ url: URL) {
    Task { await navigator.open(url) }
  }

  /// Alerts run modally; present them after the state change returns.
  private func schedule(_ state: AttentionNavigationState) {
    Task { @MainActor in await self.render(state) }
  }

  private func render(_ state: AttentionNavigationState) async {
    guard state == navigator.state, state != shown else { return }
    shown = state
    switch state {
    case .idle, .connecting, .opening, .opened: break
    case .rejected:
      inform(
        "This link can't be opened",
        "It is not a valid Swiftty attention link. Nothing was contacted."
      )
      navigator.cancel()
    case let .needsHostSelection(hosts):
      guard let host = chooseHost(hosts) else { return navigator.cancel() }
      await navigator.selectHost(host)
    case let .unavailable(reason):
      let alert = NSAlert()
      alert.messageText = "Attention item unavailable"
      alert.informativeText = DisplayText.sanitize(reason)
      alert.addButton(withTitle: "Try Again")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() == .alertFirstButtonReturn {
        shown = nil
        await navigator.retry()
      } else {
        navigator.cancel()
      }
    case let .ready(preview):
      if navigator.destination?.intent == .reveal {
        await navigator.didView()
        await navigator.openInPane()
        return
      }
      let alert = itemAlert(preview, headline: headline(preview.item))
      if preview.leaseHeldElsewhere, !ownsWorkspace(preview.target.workspace) {
        alert.informativeText += "\n\nAnother client controls this workspace."
      }
      alert.addButton(withTitle: "Open in Pane")
      alert.addButton(withTitle: "Close")
      let open = alert.runModal() == .alertFirstButtonReturn
      await navigator.didView()
      if open { await navigator.openInPane() } else { navigator.cancel() }
    case let .stale(preview):
      let alert = itemAlert(preview, headline: staleHeadline(preview.item.resolution))
      alert.addButton(withTitle: "OK")
      alert.runModal()
      await navigator.didView()
      navigator.cancel()
    case let .missing(reason):
      inform(
        "Attention item no longer exists",
        reason == .serviceRestarted
          ? "SwiftMux restarted since this link was made, so the pane it named is gone."
          : "The request, pane or terminal this link named was replaced or removed."
      )
      navigator.cancel()
    case let .paneExited(preview):
      let alert = itemAlert(preview, headline: "The program's pane has exited")
      alert.informativeText += "\n\nIts final output may still be retained."
      alert.addButton(withTitle: "Show Final Output")
      alert.addButton(withTitle: "Close")
      let open = alert.runModal() == .alertFirstButtonReturn
      await navigator.didView()
      if open { await navigator.openInPane() } else { navigator.cancel() }
    case let .confirmTakeover(offer):
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText =
        offer.controllerChanged
        ? "Another client took control first" : "Another client controls this workspace"
      var detail = "Taking over disconnects it from the workspace. Its shells keep running."
      if let holder = offer.holder {
        let place = holder.transport == .remote ? "a remote device" : "this Mac"
        detail =
          "Controlled from \(place) since "
          + holder.since.formatted(date: .omitted, time: .shortened) + ". " + detail
      }
      alert.informativeText = detail
      alert.addButton(withTitle: "Take Over")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() == .alertFirstButtonReturn {
        await navigator.confirmTakeover()
      } else {
        navigator.declineTakeover()
        navigator.cancel()
      }
    }
  }

  private func headline(_ item: AttentionItem) -> String {
    switch item.category {
    case .needsYou: "A program needs you"
    case .failure: "A program failed"
    case .result: "A program finished"
    }
  }

  private func staleHeadline(_ resolution: AttentionResolution) -> String {
    switch resolution {
    case .superseded: "This request was replaced by a newer one"
    case .resolved: "This request was already resolved"
    case .reviewed: "This item was already reviewed"
    case .paneExited: "The program's pane has exited"
    case .open: "This item is no longer current"
    }
  }

  /// Program text is untrusted: sanitized plain text only.
  private func itemAlert(_ preview: AttentionPreview, headline: String) -> NSAlert {
    let alert = NSAlert()
    alert.messageText = headline
    let status = preview.item.status
    alert.informativeText = [status.app, status.title, status.message]
      .compactMap { $0.map { DisplayText.sanitize($0) } }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    return alert
  }

  private func inform(_ title: String, _ text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.runModal()
  }

  private func chooseHost(_ hosts: [NavigationHost]) -> NavigationHost? {
    let alert = NSAlert()
    alert.messageText = "Which Mac should open this link?"
    alert.informativeText =
      "The link names a host this Mac doesn't know. Choose one of your own; "
      + "the link is checked against it before anything is shown."
    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
    for host in hosts { popup.addItem(withTitle: host.name) }
    alert.accessoryView = popup
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    guard !hosts.isEmpty, alert.runModal() == .alertFirstButtonReturn else {
      return nil
    }
    return hosts[popup.indexOfSelectedItem]
  }

  private static func localHostID() -> UUID {
    let key = "SwifttyLocalHostProfileID"
    if let text = UserDefaults.standard.string(forKey: key),
      let id = UUID(uuidString: text)
    {
      return id
    }
    let id = UUID()
    UserDefaults.standard.set(id.uuidString, forKey: key)
    return id
  }

  private struct Opener: AttentionPaneOpener {
    let reveal: @MainActor @Sendable (PaneTarget, UInt64?) async throws -> Void

    func open(
      _ target: PaneTarget,
      takeover expectedLease: UInt64?
    ) async throws(AttentionServiceError) {
      do {
        try await reveal(target, expectedLease)
      } catch let error as MuxError {
        throw SMXAttentionService.map(error)
      } catch {
        throw .offline(error.localizedDescription)
      }
    }
  }
}
