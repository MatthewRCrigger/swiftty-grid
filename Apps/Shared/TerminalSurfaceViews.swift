import SessionCore
import SwiftUI
import SwifttyCore
import TerminalSurface

#if canImport(UIKit)
  import SwifttyMobile
  import UIKit
#elseif os(macOS)
  import AppKit
  import SwifttyMac
#endif

/// Chooses the controller for a screen (created once, owned by the
/// model) and shows its surface.
struct LiveTerminalSurface: View {
  let model: TerminalScreenModel
  let app: RoamingAppModel

  var body: some View {
    switch Self.controller(for: model, app: app) {
    case let roaming as RoamingTerminalController:
      RoamingSurfaceView(controller: roaming, app: app)
    case let ssh as SSHShellController:
      SSHSurfaceView(controller: ssh, app: app)
    default:
      EmptyView()
    }
  }

  /// `model`'s controller, created on first display. A closed screen
  /// still on its way out gets none.
  static func controller(
    for model: TerminalScreenModel,
    app: RoamingAppModel
  ) -> (any TerminalSurfaceController)? {
    if let existing = model.controller { return existing }
    guard !model.isClosed else { return nil }
    let created: any TerminalSurfaceController
    switch model.kind {
    case .roaming:
      created = RoamingTerminalController(model: model, app: app)
    case .ordinarySSH:
      created = SSHShellController(model: model, app: app)
    }
    model.controller = created
    return created
  }
}

// MARK: - Roaming

struct RoamingSurfaceView: View {
  let controller: RoamingTerminalController
  let app: RoamingAppModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var confirmTerminate = false
  @State private var showsFiles = false

  var body: some View {
      TerminalDisplayView(session: controller.display, capabilities: controller.model.capabilities)
        .uiTestingScreenProbe(controller.model)
        .glassSurface()
      .overlay { overlay }
      .safeAreaInset(edge: .bottom) {
        if controller.offersOrdinarySSH {
          FallbackBanner(
            host: controller.model.host,
            app: app,
            notice: controller.endpointNotice
          )
        }
      }
      .task { controller.startIfNeeded() }
      .onChange(of: scenePhase) { _, phase in controller.scenePhaseChanged(phase) }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Menu {
            #if !os(tvOS)
              if controller.model.profile.sftp {
                Button("Files…", systemImage: "folder") { showsFiles = true }
                  .accessibilityIdentifier("session.files")
              }
            #endif
            Button("Detach", systemImage: "eject") { app.close(.detach) }
              .accessibilityIdentifier("session.detach")
            if controller.model.sessionID != nil {
              Button("Terminate Session…", systemImage: "xmark.octagon", role: .destructive) {
                confirmTerminate = true
              }
            }
          } label: {
            Label("Session", systemImage: "ellipsis.circle")
          }
          .accessibilityIdentifier("session.menu")
        }
      }
      .confirmationDialog(
        "Terminate the session on \(controller.model.host.nickname)?",
        isPresented: $confirmTerminate,
        titleVisibility: .visible
      ) {
        Button("Terminate Session", role: .destructive) { app.close(.terminate) }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("The shell on the Mac and every program running in it will be ended.")
      }
      #if !os(tvOS)
        .adaptiveSheet(isPresented: $showsFiles) {
          SFTPBrowserView(host: controller.model.host, app: app)
            .macSheetFrame(width: 560, height: 480)
        }
      #endif
  }

  @ViewBuilder private var overlay: some View {
    switch controller.phase {
    case .preparing(let message):
      ProgressCard(message: message)
    case .running:
      EmptyView()
    case .failed(let problem):
      ProblemCard(problem: problem) { action in
        switch action {
        case .retry: controller.start(.selected)
        case .startNewSession: controller.start(.newSession)
        case .openOrdinarySSH: app.open(controller.model.host, kind: .ordinarySSH)
        }
      }
    }
  }
}

/// Offered while the roaming attachment keeps failing (UDP blocked,
/// helper unreachable). Clearly a different shell (spec §9).
struct FallbackBanner: View {
  let host: HostProfile
  let app: RoamingAppModel
  var notice: EndpointStageNotice?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let notice {
        Text(EndpointStageNotice.title).font(.subheadline.bold())
          .accessibilityIdentifier("session.endpointStage")
        Text(notice.detail).font(.caption).foregroundStyle(.secondary)
          .selectableIfSupported()
      } else {
        Text("The roaming connection can't be reached.")
          .font(.subheadline.bold())
      }
      Text(
        "An ordinary SSH shell is a different shell. The roaming session stays "
          + "on the Mac and can be resumed later."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button("Open Ordinary SSH Shell", systemImage: "terminal") {
        app.open(host, kind: .ordinarySSH)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .glassPanel(cornerRadius: 0)
    .glassButtonStyle()
  }
}

// MARK: - Ordinary SSH

struct SSHSurfaceView: View {
  let controller: SSHShellController
  let app: RoamingAppModel
  @State private var showsFiles = false

  var body: some View {
    VStack(spacing: 0) {
      // Never presented as the resumed roaming session.
      Label(
        "Ordinary SSH shell — not the roaming session. It ends if the connection drops.",
        systemImage: "exclamationmark.triangle"
      )
      .font(.caption)
      .padding(.horizontal)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .glassPanel(cornerRadius: 0, tint: .yellow.opacity(0.2))
      if let notice = controller.inputNotice {
        HStack {
          Label(notice, systemImage: "exclamationmark.triangle")
          Spacer()
          Button("Dismiss", systemImage: "xmark") { controller.dismissInputNotice() }
        }
        .font(.caption)
        .padding(8)
        .glassPanel(cornerRadius: 0, tint: .yellow.opacity(0.2))
      }
      TerminalDisplayView(session: controller.session, capabilities: controller.model.capabilities)
        .uiTestingScreenProbe(controller.model)
        .glassSurface()
        .overlay { overlay }
    }
    .task { controller.start() }
    #if !os(tvOS)
      .toolbar {
        if controller.model.profile.sftp {
          ToolbarItem(placement: .primaryAction) {
            Button("Files…", systemImage: "folder") { showsFiles = true }
          }
        }
      }
      .adaptiveSheet(isPresented: $showsFiles) {
        SFTPBrowserView(host: controller.model.host, app: app)
            .macSheetFrame(width: 560, height: 480)
      }
    #endif
  }

  @ViewBuilder private var overlay: some View {
    switch controller.phase {
    case .preparing(let message):
      ProgressCard(message: message)
    case .running:
      EmptyView()
    case .failed(let problem):
      ProblemCard(problem: problem, retryTitle: "Open New SSH Shell") { _ in
        // A new, different shell; the old one is gone.
        let host = controller.model.host
        app.close()
        app.open(host, kind: .ordinarySSH)
      }
    }
  }
}

// MARK: - Shared pieces

struct ProgressCard: View {
  let message: String

  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text(message).font(.headline)
    }
    .padding(24)
    .glassPanel()
    .accessibilityElement(children: .combine)
  }
}

struct ProblemCard: View {
  let problem: SurfaceProblem
  var retryTitle = "Try Again"
  let perform: (SurfaceAction) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(problem.title, systemImage: "exclamationmark.triangle")
        .font(.headline)
      Text(problem.detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .selectableIfSupported()
      ForEach(problem.actions, id: \.self) { action in
        switch action {
        case .retry:
          Button(retryTitle) { perform(.retry) }
            .glassButtonStyle(prominent: true)
        case .startNewSession:
          Button("Start New Session") { perform(.startNewSession) }
            .glassButtonStyle(prominent: true)
        case .openOrdinarySSH:
          VStack(alignment: .leading, spacing: 4) {
            Button("Open Ordinary SSH Shell") { perform(.openOrdinarySSH) }
            Text("A different shell; it is not the roaming session.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(24)
    .frame(maxWidth: 480)
    .glassPanel()
    .glassButtonStyle()
    .padding()
  }
}

// MARK: - Platform display

#if canImport(UIKit)
  /// Hosts `TerminalUIView` (iOS, iPadOS, Mac Catalyst, visionOS, tvOS).
  struct TerminalDisplayView: UIViewRepresentable {
    let session: TerminalSession
    let capabilities: SurfaceCapabilities

    func makeUIView(context: Context) -> UIView {
      do {
        let view = try TerminalUIView(session: session)
        view.capabilities = capabilities
        // App-switcher snapshots omit terminal content (spec §12).
        view.hidesContentWhenInactive = true
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
      } catch {
        let label = UILabel()
        label.text = "Terminal rendering is unavailable on this device."
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
      }
    }

    func updateUIView(_ view: UIView, context: Context) {
      guard let view = view as? TerminalUIView, view.capabilities != capabilities else { return }
      view.capabilities = capabilities
    }
  }
#elseif os(macOS)
  /// Hosts the AppKit `TerminalView` (native macOS: the SwiftPM test host).
  struct TerminalDisplayView: NSViewRepresentable {
    let session: TerminalSession
    let capabilities: SurfaceCapabilities
    var prepare: ((TerminalView) -> Void)?

    func makeNSView(context: Context) -> NSView {
      do {
        let view = try TerminalView(configuration: Configuration(), session: session)
        view.capabilities = capabilities
        prepare?(view)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
      } catch {
        return NSTextField(labelWithString: "Terminal rendering is unavailable on this Mac.")
      }
    }

    func updateNSView(_ view: NSView, context: Context) {
      guard let view = view as? TerminalView, view.capabilities != capabilities else { return }
      view.capabilities = capabilities
    }
  }
#endif
