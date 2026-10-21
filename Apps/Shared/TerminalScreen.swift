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
  /// Pending input that outlived a normal round trip; a keystroke awaiting
  /// its ack is not worth showing.
  @State private var pendingVisible = false
  let onClose: () -> Void

  public init(model: TerminalScreenModel, onClose: @escaping () -> Void) {
    self.model = model
    self.onClose = onClose
  }

  public var body: some View {
    VStack(spacing: 0) {
      if showsStatusBar {
        statusBar
        Divider()
      }
      if let factory {
        factory.make(model)
          // Native renderers and surface tasks belong to this model's
          // session; a replacement must start with a fresh hierarchy.
          .id(model.id)
      } else {
        TerminalSurfacePlaceholder(model: model)
      }
    }
    // Transient state floats over the terminal: inserting a row would
    // resize the grid, and redraw it, on every keystroke.
    .overlay(alignment: .top) {
      if showsStatusOverlay { statusBar }
    }
    .task(id: model.pendingInputCount > 0) {
      guard model.pendingInputCount > 0 else {
        pendingVisible = false
        return
      }
      try? await Task.sleep(for: .milliseconds(750))
      if !Task.isCancelled { pendingVisible = true }
    }
    .navigationTitle(model.host.nickname)
    #if os(iOS) && !targetEnvironment(macCatalyst)
    // iPhone and iPad: the host name sits in the top row beside Back, and
    // Close joins the session actions, so the terminal starts higher.
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) { titleWithStatus }
      ToolbarItem(placement: .primaryAction) {
        Button("Close", systemImage: "xmark", action: onClose)
          .accessibilityIdentifier("terminal.close")
      }
    }
    #else
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Close", action: onClose)
          .accessibilityIdentifier("terminal.close")
      }
    }
    #endif
  }

  /// iPhone and iPad show the connection state as a dot beside the title
  /// (`titleWithStatus`); the bar then remains only for what the dot
  /// cannot say.
  private static let statusInTitle: Bool = {
    #if os(iOS) && !targetEnvironment(macCatalyst)
    true
    #else
    false
    #endif
  }()

  /// The bar as a layout row, only where it stays put.
  private var showsStatusBar: Bool {
    !Self.statusInTitle || model.kind != .roaming
  }

  private var showsStatusOverlay: Bool {
    !showsStatusBar && (pendingVisible || !model.acceptsInput)
  }

  /// The host name with a state dot: green connected, orange on the way,
  /// red failed. The dot carries the state text for VoiceOver and tests.
  private var titleWithStatus: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(model.connectionState.indicatorColor)
        .frame(width: 8, height: 8)
        .accessibilityElement()
        .accessibilityLabel(stateText)
        .accessibilityIdentifier("terminal.status")
      Text(model.host.nickname).font(.headline).lineLimit(1)
    }
  }

  private var statusBar: some View {
    HStack(spacing: 12) {
      if !Self.statusInTitle {
        Label(stateText, systemImage: model.connectionState.symbol)
          .foregroundStyle(
            model.connectionState.acceptsInput ? .primary : .secondary
          )
      }
      if model.kind != .roaming {
        Text(model.kind.displayName)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if pendingVisible, model.pendingInputCount > 0 {
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
    .accessibilityIdentifier(Self.statusInTitle ? "terminal.details" : "terminal.status")
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

  /// The title dot: green connected, orange connecting, red failed, grey
  /// when not connected by choice.
  var indicatorColor: Color {
    switch self {
    case .active: .green
    case .sshBootstrap, .attaching, .reconnecting, .suspect: .orange
    case .sessionLost, .sessionExited: .red
    case .idle, .backgroundDetached, .userClosed: .secondary
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
