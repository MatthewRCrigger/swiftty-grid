import Foundation
import MuxNavigation
import SwiftMuxProtocol
import SwiftUI

/// The recipient's saved hosts as navigation hosts: IDs and nicknames
/// only. A link can name a host profile ID but never adds a host,
/// endpoint or credential (swiftty-unified-spec.md §9).
struct RoamingHostDirectory: AttentionHostDirectory {
  let model: RoamingAppModel

  func configuredHosts() async -> [NavigationHost] {
    await MainActor.run {
      if model.hosts.isEmpty { model.load() }
      return model.hosts.map { NavigationHost(id: $0.id, name: $0.nickname) }
    }
  }
}


/// One followed link: a navigator bound to this app's hosts.
@MainActor
final class AttentionLinkSession: Identifiable {
  let id = UUID()
  let navigator: AttentionNavigator

  init(model: RoamingAppModel, connector: any AttentionServiceConnector) {
    navigator = AttentionNavigator(
      configuration: AttentionLinkConfiguration(infoDictionary: Bundle.main.infoDictionary),
      hosts: RoamingHostDirectory(model: model),
      connector: connector
    )
  }
}

extension View {
  /// Routes `swiftty://attention/…`, configured Universal Links and
  /// attention Handoff into a destination sheet.
  func attentionLinks(_ model: RoamingAppModel) -> some View {
    modifier(AttentionLinkRouting(model: model))
  }
}

/// Opens an attention destination in the current scene's navigator.
struct OpenAttentionAction {
  var handler: @MainActor (AttentionDestination) -> Void = { _ in }
  @MainActor func callAsFunction(_ destination: AttentionDestination) {
    handler(destination)
  }
}

extension EnvironmentValues {
  @Entry var openAttention = OpenAttentionAction()
}

struct AttentionLinkRouting: ViewModifier {
  let model: RoamingAppModel
  @State private var session: AttentionLinkSession?

  func body(content: Content) -> some View {
    content
      .onOpenURL { url in open { await $0.open(url) } }
      .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
        guard let url = activity.webpageURL else { return }
        open { await $0.open(url) }
      }
      .onContinueUserActivity(AttentionHandoffRequest.activityType) { activity in
        // A watch handoff carries only a locator; it is resolved through
        // this device's hosts like any link and never grants a lease.
        guard let request = AttentionHandoffRequest(userInfo: activity.userInfo),
          let destination = try? request.destination()
        else { return }
        open { await $0.open(destination) }
      }
      // Inbox entries open through the same navigator, in this scene.
      .environment(
        \.openAttention,
        OpenAttentionAction { destination in open { await $0.open(destination) } }
      )
      // iPadOS/visionOS/Catalyst: an attention link goes to an existing
      // window (this one, when it is frontmost) instead of a new scene;
      // every scene shares the one app model and its single terminal.
      .handlesExternalEvents(preferring: ["attention", "/a/"], allowing: ["*"])
      .sheet(item: $session) { session in
        AttentionDestinationView(navigator: session.navigator) { self.session = nil }
          .macSheetFrame(width: 440, height: 320)
      }
  }

  /// A newer link replaces the current one; the old navigator's late
  /// results are dropped with it.
  private func open(_ start: @escaping @MainActor (AttentionNavigator) async -> Void) {
    session?.navigator.cancel()
    let next = AttentionLinkSession(model: model, connector: RoamingAttentionConnector(model: model))
    session = next
    Task { await start(next.navigator) }
  }
}

/// Renders every navigator state. Program text is untrusted and shown
/// verbatim as plain text, never as markup or a link.
struct AttentionDestinationView: View {
  let navigator: AttentionNavigator
  let dismiss: () -> Void

  var body: some View {
    NavigationStack {
      content
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Attention")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
              navigator.cancel()
              dismiss()
            }
          }
        }
    }
  }

  @ViewBuilder private var content: some View {
    switch navigator.state {
    case .idle:
      ProgressView()
    case .rejected:
      message(
        "This link can't be opened",
        "It is not a valid Swiftty attention link. Nothing was contacted.",
        symbol: "link.badge.plus"
      )
    case let .needsHostSelection(hosts):
      VStack(alignment: .leading, spacing: 12) {
        Text("Choose a host").font(.headline)
        if hosts.isEmpty {
          Text("Add the Mac this link came from to your hosts first. Links never add hosts.")
            .foregroundStyle(.secondary)
        } else {
          Text("This link names a host this device doesn't know. Pick one of your own hosts.")
            .foregroundStyle(.secondary)
          ForEach(hosts) { host in
            Button(host.name) { Task { await navigator.selectHost(host) } }
          }
        }
      }
    case let .connecting(host):
      ProgressView("Connecting to \(host.name)…")
    case let .unavailable(reason):
      VStack(alignment: .leading, spacing: 12) {
        message("Unavailable", reason, symbol: "wifi.exclamationmark")
        Button("Try Again") { Task { await navigator.retry() } }
      }
    case let .ready(preview):
      VStack(alignment: .leading, spacing: 12) {
        item(preview)
        Button("Open in Pane") { Task { await navigator.openInPane() } }
          .buttonStyle(.borderedProminent)
      }
      .task { await navigator.didView() }
    case let .stale(preview):
      VStack(alignment: .leading, spacing: 12) {
        message(
          "No longer current",
          "This request was resolved, reviewed or replaced. A newer request is not shown in its place.",
          symbol: "clock.arrow.circlepath"
        )
        item(preview)
      }
      .task { await navigator.didView() }
    case let .missing(reason):
      message(
        "Item not found",
        reason == .serviceRestarted
          ? "The host's service restarted since this link was made."
          : "The request, pane or terminal this link named is gone.",
        symbol: "questionmark.square.dashed"
      )
    case let .paneExited(preview):
      VStack(alignment: .leading, spacing: 12) {
        message("The pane exited", "Its final output may still be retained.", symbol: "stop.circle")
        item(preview)
        Button("Show Final Output") { Task { await navigator.openInPane() } }
      }
      .task { await navigator.didView() }
    case let .confirmTakeover(offer):
      VStack(alignment: .leading, spacing: 12) {
        message(
          offer.controllerChanged
            ? "Another client took control first" : "Another client controls this workspace",
          "Taking over disconnects it. Its shells keep running.",
          symbol: "person.2.badge.gearshape"
        )
        Button("Take Over", role: .destructive) { Task { await navigator.confirmTakeover() } }
        Button("Not Now") { navigator.declineTakeover() }
      }
    case .opening:
      ProgressView("Opening…")
    case .opened:
      message("Opened", "The pane is active.", symbol: "checkmark.circle")
    }
  }

  private func message(_ title: String, _ detail: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: symbol).font(.headline)
      Text(verbatim: detail).foregroundStyle(.secondary)
    }
  }

  private func item(_ preview: AttentionPreview) -> some View {
    let status = preview.item.status
    return VStack(alignment: .leading, spacing: 4) {
      Text(category(preview.item.category)).font(.subheadline.bold())
      if let app = status.app { Text(verbatim: app).font(.caption) }
      if let title = status.title { Text(verbatim: title) }
      if let message = status.message {
        Text(verbatim: message).font(.callout).foregroundStyle(.secondary).lineLimit(6)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func category(_ category: AttentionCategory) -> String {
    switch category {
    case .needsYou: "Needs you"
    case .failure: "Failed"
    case .result: "Result"
    }
  }
}
