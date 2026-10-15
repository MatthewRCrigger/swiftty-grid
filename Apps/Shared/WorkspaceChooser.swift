import Foundation
import MuxNavigation
import Observation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftUI

/// The Mac → Workspace step (spec.connection-setup.md D1): after SSH
/// verification and sign-in, list the Mac's workspaces from lease-free
/// authenticated metadata and attach only to the one the user picks.
///
/// Browsing, refreshing and cancelling create no workspace, acquire no
/// writer lease and leave the active terminal alone. Only New Workspace
/// sends a create request; taking control from another client needs
/// explicit confirmation of the lease generation shown.
@MainActor
@Observable
final class WorkspaceChooserModel {
  enum Phase: Equatable {
    case connecting
    case loaded
    case failed(String)
  }

  /// One row: the summary as observed, and whether this app shows it.
  struct Row: Identifiable, Hashable {
    var summary: WorkspaceSummary
    var isShownHere: Bool
    var id: WorkspaceID { summary.id }
    /// Another client holds the writer lease.
    var heldElsewhere: Bool { summary.isAttached && !isShownHere }
  }

  /// Rows shown; the service's own limits bound the reply further.
  static let maxRows = 256

  let host: HostProfile
  private(set) var phase: Phase = .connecting
  private(set) var rows: [Row] = []
  private(set) var serviceEpoch: SwiftMuxProtocol.ServerInstanceID?
  /// Why the list was refreshed instead of opening (lease or epoch race).
  private(set) var notice: String?
  /// A takeover awaiting the user's confirmation.
  var pendingTakeover: Row?
  /// Set once a selection was handed to the terminal; the view dismisses.
  private(set) var finished = false

  @ObservationIgnored
  private let model: RoamingAppModel
  @ObservationIgnored
  private let connector: any AttentionServiceConnector
  @ObservationIgnored
  private var service: (any RoamingAttentionMetadataService)?
  @ObservationIgnored
  private var task: Task<Void, Never>?
  @ObservationIgnored
  private var generation = 0
  @ObservationIgnored
  private var closed = false

  init(
    model: RoamingAppModel,
    host: HostProfile,
    connector: (any AttentionServiceConnector)? = nil
  ) {
    self.model = model
    self.host = host
    self.connector =
      connector ?? RoamingAttentionConnector(model: model, detailedErrors: true)
  }

  /// Signs in if needed and lists workspaces. Superseded loads are
  /// cancelled and their late results ignored.
  func load() {
    guard !closed else { return }
    task?.cancel()
    generation += 1
    let generation = generation
    if rows.isEmpty { phase = .connecting }
    task = Task {
      await self.fetch(generation)
    }
  }

  private func fetch(_ generation: Int) async {
    do throws(AttentionServiceError) {
      let service = try await connected()
      let metadata = try await service.metadata(.workspaces)
      guard self.generation == generation, !closed, !Task.isCancelled else {
        return
      }
      publish(metadata)
    } catch {
      guard self.generation == generation, !closed else { return }
      await dropService()
      phase = .failed(Self.describe(error))
    }
  }

  private func connected() async throws(AttentionServiceError)
    -> any RoamingAttentionMetadataService
  {
    if let service { return service }
    let navigationHost = NavigationHost(id: host.id, name: host.nickname)
    let opened = try await connector.connect(to: navigationHost)
    guard let metadata = opened as? any RoamingAttentionMetadataService else {
      await opened.close()
      throw .unsupported("This Mac cannot list its workspaces.")
    }
    guard !closed, !Task.isCancelled else {
      await metadata.close()
      throw .other("Cancelled.")
    }
    service = metadata
    return metadata
  }

  private func publish(_ metadata: HostMetadata) {
    serviceEpoch = metadata.serviceEpoch
    rows = (metadata.workspaces ?? []).prefix(Self.maxRows)
      .map { Row(summary: $0, isShownHere: isShownHere($0.id)) }
      .sorted { $0.summary.createdAt > $1.summary.createdAt }
    phase = .loaded
  }

  /// Whether this app's roaming terminal shows `workspace` on this host.
  private func isShownHere(_ workspace: WorkspaceID) -> Bool {
    guard let session = model.activeSession, session.host.id == host.id,
      session.kind == .roaming
    else { return false }
    return session.sessionID == SessionID(workspace)
  }

  // MARK: Choosing

  /// Opens an existing workspace by identity. One held by another client
  /// asks for confirmation first.
  func choose(_ row: Row) {
    guard !closed, !finished else { return }
    if row.heldElsewhere {
      pendingTakeover = row
      return
    }
    open(row, confirmedTakeover: false)
  }

  /// The user confirmed taking control of exactly the generation shown.
  func confirmTakeover() {
    guard let row = pendingTakeover else { return }
    pendingTakeover = nil
    open(row, confirmedTakeover: true)
  }

  /// New Workspace: the one explicit create.
  func createNew() {
    guard !closed, !finished else { return }
    finish()
    model.openWorkspace(host, intent: .create)
  }

  private func open(_ row: Row, confirmedTakeover: Bool) {
    guard let epoch = serviceEpoch else { return }
    task?.cancel()
    generation += 1
    let generation = generation
    notice = nil
    task = Task {
      do throws(AttentionServiceError) {
        let service = try await self.connected()
        // Re-read before attaching: the lease or service may have changed
        // since the list was shown. A change refreshes, never retries.
        let metadata = try await service.metadata(.workspaces)
        guard self.generation == generation, !self.closed, !Task.isCancelled
        else { return }
        let lease = try self.lease(
          for: row,
          in: metadata,
          observedEpoch: epoch,
          confirmedTakeover: confirmedTakeover
        )
        guard self.model.hosts.contains(self.host) else { throw .notFound }
        self.finish()
        self.model.openWorkspace(
          self.host,
          intent: .resume(
            SessionID(row.id),
            lease.map { ResumeTarget(expectedLease: $0) }
          )
        )
      } catch {
        // Lease or epoch races and vanished workspaces show the current
        // list; nothing is retried on the user's behalf.
        guard self.generation == generation, !self.closed else { return }
        self.notice = Self.describe(error)
        self.load()
      }
    }
  }

  /// The lease generation to take over, `nil` for a free workspace or
  /// this app's own. Fails when what the user saw is no longer true.
  private func lease(
    for row: Row,
    in metadata: HostMetadata,
    observedEpoch: SwiftMuxProtocol.ServerInstanceID,
    confirmedTakeover: Bool
  ) throws(AttentionServiceError) -> UInt64? {
    guard metadata.serviceEpoch == observedEpoch else {
      throw .serviceRestarted
    }
    guard
      let current = metadata.workspaces?.first(where: { $0.id == row.id })
    else { throw .notFound }
    guard current.isAttached, !isShownHere(current.id) else { return nil }
    guard confirmedTakeover else { throw .leaseHeld }
    guard row.summary.isAttached,
      current.leaseGeneration == row.summary.leaseGeneration
    else { throw .leaseChanged }
    return current.leaseGeneration
  }

  // MARK: Lifetime

  private func finish() {
    finished = true
    close()
  }

  /// Cancel or dismissal: closes the metadata connection only.
  func close() {
    guard !closed else { return }
    closed = true
    task?.cancel()
    task = nil
    pendingTakeover = nil
    let service = service
    self.service = nil
    if let service { Task { await service.close() } }
  }

  private func dropService() async {
    let service = service
    self.service = nil
    await service?.close()
  }

  static func describe(_ error: AttentionServiceError) -> String {
    switch error {
    case .leaseHeld:
      "Another device took control of this workspace. Review it and confirm again."
    case .leaseChanged:
      "This workspace's controller changed. Review it and confirm again."
    case .serviceRestarted:
      "SwiftMux restarted on the Mac. The list was refreshed; choose again."
    case .notFound: "That workspace no longer exists on the Mac."
    default: RoamingInboxModel.describe(error)
    }
  }
}

// MARK: - View

/// Lists a Mac's workspaces after sign-in. Presented as a sheet; it hosts
/// the connection prompts while it is up.
struct WorkspaceChooserView: View {
  @State
  private var chooser: WorkspaceChooserModel
  let app: RoamingAppModel
  let dismiss: () -> Void
  @Environment(\.scenePhase)
  private var scenePhase

  init(
    host: HostProfile,
    app: RoamingAppModel,
    dismiss: @escaping () -> Void
  ) {
    _chooser = State(
      initialValue: WorkspaceChooserModel(model: app, host: host)
    )
    self.app = app
    self.dismiss = dismiss
  }

  var body: some View {
    NavigationStack {
      List {
        if let notice = chooser.notice {
          Label(notice, systemImage: "arrow.triangle.2.circlepath")
            .foregroundStyle(.orange).listRowBackground(Color.clear)
            .accessibilityIdentifier("workspace.notice")
        }
        content
      }
      .glassListBackground()
      .navigationTitle(chooser.host.nickname)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: cancel)
            .accessibilityIdentifier("workspace.cancel")
        }
        ToolbarItem(placement: .automatic) {
          Button {
            chooser.load()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .disabled(chooser.phase == .connecting)
        }
      }
      .confirmationDialog(
        takeoverTitle,
        isPresented: takeoverBinding,
        titleVisibility: .visible
      ) {
        Button("Take Control") { chooser.confirmTakeover() }
          .accessibilityIdentifier("workspace.takeover")
        Button("Cancel", role: .cancel) { chooser.pendingTakeover = nil }
      } message: {
        Text(
          "Another client controls this workspace. Taking control detaches it "
            + "there; nothing running in the workspace is ended."
        )
      }
    }
    .modalConnectionPrompts(app)
    .task { chooser.load() }
    .onChange(of: chooser.finished) { _, finished in if finished { dismiss() } }
    .onDisappear { chooser.close() }
  }

  @ViewBuilder
  private var content: some View {
    switch chooser.phase {
    case .connecting:
      HStack {
        ProgressView()
        Text("Signing in to list workspaces…").foregroundStyle(.secondary)
      }
      .listRowBackground(Color.clear)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange).listRowBackground(Color.clear)
        .accessibilityIdentifier("workspace.error")
      Button("Try Again") { chooser.load() }.listRowBackground(Color.clear)
    case .loaded:
      if chooser.rows.isEmpty {
        ContentUnavailableView(
          "No Workspaces",
          systemImage: "rectangle.stack",
          description: Text("This Mac has no workspaces yet.")
        )
        .listRowBackground(Color.clear)
      }
      Section {
        ForEach(chooser.rows) { row in
          Button {
            chooser.choose(row)
          } label: {
            WorkspaceRowLabel(row: row)
          }
          .accessibilityIdentifier("workspace.open")
        }
      }
      .listRowBackground(Color.clear)
      Section {
        Button {
          chooser.createNew()
        } label: {
          Label("New Workspace", systemImage: "plus.rectangle.on.rectangle")
        }
        .accessibilityIdentifier("workspace.new")
      } footer: {
        Text("Starts a new shell on the Mac. Existing workspaces keep running.")
      }
      .listRowBackground(Color.clear)
    }
  }

  private var takeoverTitle: String {
    "Take control of \u{201C}\(chooser.pendingTakeover?.summary.name ?? "")\u{201D}?"
  }

  private var takeoverBinding: Binding<Bool> {
    Binding(
      get: { chooser.pendingTakeover != nil },
      set: { if !$0 { chooser.pendingTakeover = nil } }
    )
  }

  private func cancel() {
    chooser.close()
    dismiss()
  }
}

/// Name, counts and control state of one workspace.
struct WorkspaceRowLabel: View {
  let row: WorkspaceChooserModel.Row

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(row.summary.name.isEmpty ? "Untitled Workspace" : row.summary.name)
        .font(.headline)
      Text(counts).font(.caption).foregroundStyle(.secondary)
      Label(control, systemImage: controlImage).font(.caption)
        .foregroundStyle(row.heldElsewhere ? .orange : .secondary)
    }
  }

  private var counts: String {
    let s = row.summary
    var parts = [
      "\(s.tabCount) tab\(s.tabCount == 1 ? "" : "s")",
      "\(s.paneCount) pane\(s.paneCount == 1 ? "" : "s")",
    ]
    if let live = s.livePaneCount, live != s.paneCount {
      parts.append("\(live) running")
    }
    return parts.joined(separator: " · ")
  }

  private var control: String {
    if row.isShownHere { return "Shown on this device" }
    guard row.summary.isAttached else { return "Not attached" }
    switch row.summary.leaseHolder?.transport {
    case .local?: return "Controlled on the Mac"
    case .remote?: return "Controlled by another device"
    case nil: return "Controlled by another client"
    }
  }

  private var controlImage: String {
    if row.isShownHere { return "checkmark.circle" }
    return row.summary.isAttached ? "lock" : "circle"
  }
}

// MARK: - Modal prompt routing

/// While a sheet is up it presents the connection prompts itself (the
/// root defers to it through `modalDepth`), balanced across appear and
/// disappear.
private struct ModalConnectionPrompts: ViewModifier {
  let model: RoamingAppModel
  @State
  private var counted = false

  func body(content: Content) -> some View {
    content.connectionPrompts(model)
      .onAppear {
        guard !counted else { return }
        counted = true
        model.modalDepth += 1
      }
      .onDisappear {
        guard counted else { return }
        counted = false
        model.modalDepth -= 1
      }
  }
}

extension View {
  func modalConnectionPrompts(_ model: RoamingAppModel) -> some View {
    modifier(ModalConnectionPrompts(model: model))
  }
}
