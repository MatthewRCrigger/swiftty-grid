import SessionCore
import SwiftUI
import SwifttyCore

/// Builds the terminal surface for a session. Each direct-client app
/// installs `.live(model)` through `.environment(\.terminalSurfaceFactory, …)`;
/// without one (previews, tests) `TerminalScreen` shows a status card.
public struct TerminalSurfaceFactory: Sendable {
  public let make: @MainActor @Sendable (TerminalScreenModel) -> AnyView

  public init(make: @escaping @MainActor @Sendable (TerminalScreenModel) -> AnyView) {
    self.make = make
  }
}

extension EnvironmentValues {
  @Entry public var terminalSurfaceFactory: TerminalSurfaceFactory?
}

/// The terminal screen for one session: connection state, pending input
/// and capability chrome around the surface from `TerminalSurfaceFactory`
/// (a Swiftty renderer fed by a roaming, ordinary-SSH or local backend).
public struct TerminalScreen: View {
  @Bindable var model: TerminalScreenModel
  @Environment(\.terminalSurfaceFactory) private var factory
  let onClose: () -> Void

  public init(model: TerminalScreenModel, onClose: @escaping () -> Void) {
    self.model = model
    self.onClose = onClose
  }

  public var body: some View {
    VStack(spacing: 0) {
      statusBar
      Divider()
      if let factory {
        factory.make(model)
          // Native renderers and surface tasks belong to this model's
          // session; a replacement must start with a fresh hierarchy.
          .id(model.id)
      } else {
        TerminalSurfacePlaceholder(model: model)
      }
    }
    .navigationTitle(model.host.nickname)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Close", action: onClose)
          .accessibilityIdentifier("terminal.close")
      }
    }
  }

  private var statusBar: some View {
    HStack(spacing: 12) {
      Label(stateText, systemImage: model.connectionState.symbol)
        .foregroundStyle(model.connectionState.acceptsInput ? .primary : .secondary)
      if model.kind != .roaming {
        Text(model.kind.displayName)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if model.pendingInputCount > 0 {
        // Previously submitted input may still apply later (spec §8).
        Label("\(model.pendingInputCount) pending", systemImage: "hourglass")
          .foregroundStyle(.orange)
      }
      if !model.acceptsInput {
        Label("Input paused", systemImage: "keyboard.badge.ellipsis")
          .foregroundStyle(.secondary)
      }
    }
    .font(.footnote)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .glassPanel(cornerRadius: 0)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("terminal.status")
  }

  /// Honest state text: a reconnect attempt is not a lost session, and an
  /// exited shell is not a lost one.
  private var stateText: String {
    switch model.connectionState {
    case .reconnecting where model.reconnectAttempt > 0:
      "Reconnecting (attempt \(model.reconnectAttempt))"
    case .sessionExited:
      model.exitStatus.map { "Session exited (status \($0))" } ?? "Session exited"
    default:
      model.connectionState.displayName
    }
  }
}

/// Shown only when no `TerminalSurfaceFactory` is installed.
struct TerminalSurfacePlaceholder: View {
  let model: TerminalScreenModel

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "apple.terminal")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text("Terminal unavailable")
        .font(.headline)
      Text(model.host.endpointSummary)
        .font(.subheadline.monospaced())
        .foregroundStyle(.secondary)
      capabilityList
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .glassSurface()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Terminal unavailable")
  }

  private var capabilityList: some View {
    let caps = model.capabilities
    let entries: [(String, Bool)] = [
      ("Text input", caps.textInput),
      ("Local copy", caps.localCopy),
      ("Paste", caps.paste),
      ("Scrollback", caps.scrollback),
      ("Search", caps.search),
      ("SFTP", model.profile.sftp),
    ]
    return VStack(alignment: .leading, spacing: 4) {
      ForEach(entries, id: \.0) { name, enabled in
        Label(name, systemImage: enabled ? "checkmark.circle" : "minus.circle")
          .foregroundStyle(enabled ? .primary : .secondary)
      }
    }
    .font(.caption)
  }
}

extension ClientConnectionState {
  /// User-facing state name.
  public var displayName: String {
    switch self {
    case .idle: "Not connected"
    case .sshBootstrap: "Signing in"
    case .attaching: "Attaching"
    case .active: "Connected"
    case .suspect: "Connection uncertain"
    case .reconnecting: "Reconnecting"
    case .backgroundDetached: "Detached"
    case .sessionExited: "Session exited"
    case .sessionLost: "Session lost"
    case .userClosed: "Closed"
    }
  }

  var symbol: String {
    switch self {
    case .active: "bolt.horizontal.circle"
    case .suspect, .reconnecting, .attaching, .sshBootstrap: "arrow.triangle.2.circlepath"
    case .sessionLost, .sessionExited: "exclamationmark.triangle"
    default: "circle.dashed"
    }
  }
}
