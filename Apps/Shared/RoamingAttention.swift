import Foundation
import MuxNavigation
import Observation
import SSHClient
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import TerminalSurface

/// Attention metadata for roaming hosts over the SSH bootstrap channel
/// (spec.inbox.md §3, §9): host-key check and authentication first, then
/// lease-free `attention` requests to the SwiftMux service. Opening a pane
/// goes through the ordinary roaming attachment, with explicit takeover.
struct RoamingAttentionConnector: AttentionServiceConnector {
  let model: RoamingAppModel

  func connect(
    to host: NavigationHost
  ) async throws(AttentionServiceError) -> any AttentionService {
    let profile = await MainActor.run { model.hosts.first { $0.id == host.id } }
    guard let profile else { throw .notFound }
    let connection: SSHConnection
    do {
      connection = try await model.ssh.connect(profile)
    } catch {
      throw Self.map(error)
    }
    return RoamingAttentionService(model: model, host: profile, connection: connection)
  }

  static func map(_ error: SSHAccessError) -> AttentionServiceError {
    switch error {
    case .cancelled: .other("Sign-in was cancelled.")
    case .hostKeyChanged, .hostKeyRejected, .trustStoreUnavailable, .keyUnavailable,
      .authenticationFailed:
      .unauthorized
    default: .offline("The Mac could not be reached.")
    }
  }
}

/// One authenticated SSH connection; each request is a no-PTY exec of the
/// fixed bootstrap helper.
final class RoamingAttentionService: AttentionService, @unchecked Sendable {
  private let model: RoamingAppModel
  private let host: HostProfile
  private let connection: SSHConnection

  init(model: RoamingAppModel, host: HostProfile, connection: SSHConnection) {
    self.model = model
    self.host = host
    self.connection = connection
  }

  func metadata(
    _ request: AttentionRequest
  ) async throws(AttentionServiceError) -> HostMetadata {
    let response: BootstrapResponse
    do {
      response = try await connection.runBootstrap(
        helperPath: defaultHelperPath,
        request: BootstrapRequest(operation: .attention, attention: request)
      )
    } catch {
      throw .offline("The Mac's SwiftMux service did not answer.")
    }
    switch response {
    case let .metadata(metadata): return metadata
    case .failure(.unknownSession): throw .notFound
    case .failure(.agentUnavailable):
      throw .offline("Roaming is not enabled in SwiftMux on this Mac.")
    case .failure(.unsupportedVersion), .failure(.malformed):
      throw .unsupported("This Mac's SwiftMux does not serve attention metadata.")
    default: throw .other("Unexpected reply from the Mac.")
    }
  }

  func serviceEpoch() async throws(AttentionServiceError) -> SwiftMuxProtocol.ServerInstanceID {
    try await metadata(.workspaces).serviceEpoch
  }

  func locate(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) -> AttentionLocation {
    let metadata = try await metadata(.locate(reference))
    guard metadata.serviceEpoch == reference.source.serviceEpoch else {
      throw .serviceRestarted
    }
    guard var location = metadata.location else { throw .notFound }
    // The service reports any holder; this app's own attachment to the
    // workspace is not "elsewhere".
    if let workspace = location.workspace, await ownsWorkspace(workspace) {
      location.leaseHeldElsewhere = false
    }
    return location
  }

  func leaseState(
    of workspace: WorkspaceID
  ) async throws(AttentionServiceError) -> LeaseState {
    guard
      let summary = try await metadata(.workspaces).workspaces?
        .first(where: { $0.id == workspace })
    else { throw .notFound }
    return LeaseState(generation: summary.leaseGeneration, holder: summary.leaseHolder)
  }

  func open(
    _ target: PaneTarget,
    takeover expectedLease: UInt64?
  ) async throws(AttentionServiceError) {
    guard
      let summary = try await metadata(.workspaces).workspaces?
        .first(where: { $0.id == target.workspace })
    else { throw .notFound }
    var lease = expectedLease
    if summary.isAttached {
      if await ownsWorkspace(target.workspace) {
        // Replacing this app's own attachment is not a takeover prompt.
        lease = summary.leaseGeneration
      } else if let expected = expectedLease {
        guard expected == summary.leaseGeneration else { throw .leaseChanged }
      } else {
        throw .leaseHeld
      }
    } else {
      lease = nil
    }
    let host = host
    await MainActor.run {
      model.reveal(
        host,
        workspace: SessionID(target.workspace),
        target: ResumeTarget(pane: target.pane, expectedLease: lease)
      )
    }
  }

  func markSeen(_ reference: AttentionReference) async throws(AttentionServiceError) {
    _ = try await metadata(.markSeen(reference))
  }

  func close() async { await connection.close() }

  @MainActor
  private func ownsWorkspace(_ workspace: WorkspaceID) -> Bool {
    guard let session = model.activeSession, session.host.id == host.id,
      session.kind == .roaming
    else { return false }
    return session.sessionID == SessionID(workspace)
  }
}

// MARK: Inbox across configured hosts

/// The attention inbox of every configured Mac, keyed by
/// `(host, service epoch, occurrence)` (spec.inbox.md §4 multi-host
/// aggregation). Fetched on demand over SSH; there is no push delivery.
@MainActor
@Observable
final class RoamingInboxModel {
  struct Entry: Identifiable, Hashable {
    var host: NavigationHost
    var item: AttentionItem
    var id: String {
      "\(host.id)/\(item.source.serviceEpoch)/\(item.occurrence)"
    }
  }

  enum HostState: Equatable {
    case loading
    case loaded(InboxCounts)
    case failed(String)
  }

  private(set) var entries: [Entry] = []
  private(set) var hostStates: [UUID: HostState] = [:]
  private(set) var refreshedAt: Date?
  @ObservationIgnored private let model: RoamingAppModel
  @ObservationIgnored private var refreshing: Task<Void, Never>?

  init(model: RoamingAppModel) { self.model = model }

  var needsYouCount: Int {
    hostStates.values.reduce(0) { total, state in
      if case let .loaded(counts) = state { total + counts.needsYou } else { total }
    }
  }

  /// Fetches the needs-you and results sections from every host. Hosts
  /// that fail keep their own error; others still load. A background
  /// (non-interactive) refresh skips password hosts so it never prompts.
  func refresh(interactive: Bool = true) {
    refreshing?.cancel()
    if model.hosts.isEmpty { model.load() }
    let hosts = model.hosts
      .filter { interactive || $0.auth != .password }
      .map { NavigationHost(id: $0.id, name: $0.nickname) }
    for host in hosts { hostStates[host.id] = .loading }
    let connector = RoamingAttentionConnector(model: model)
    refreshing = Task {
      var collected: [Entry] = []
      for host in hosts {
        guard !Task.isCancelled else { return }
        do throws(AttentionServiceError) {
          let service = try await connector.connect(to: host)
          defer { Task { await service.close() } }
          guard let roaming = service as? RoamingAttentionService else { continue }
          var counts = InboxCounts()
          for section in [InboxQuery.Section.needsYou, .results] {
            let page = try await roaming.metadata(.inbox(InboxQuery(section: section)))
              .inbox
            counts = page?.counts ?? counts
            collected += (page?.items ?? []).map { Entry(host: host, item: $0) }
          }
          hostStates[host.id] = .loaded(counts)
        } catch {
          hostStates[host.id] = .failed(Self.describe(error))
        }
      }
      var seen = Set<String>()
      entries = collected.filter { seen.insert($0.id).inserted }
        .sorted { $0.item.updatedAt > $1.item.updatedAt }
      refreshedAt = .now
      model.onAttentionSummaries?(summaries)
    }
  }

  /// Redacted summaries for the watch: no message text.
  var summaries: [AttentionSummary] {
    entries.prefix(20).map { entry in
      let counts: InboxCounts =
        if case let .loaded(counts) = hostStates[entry.host.id] { counts } else {
          InboxCounts()
        }
      // The locator lets the watch hand off to this device; it carries
      // identifiers only.
      return AttentionSummary(
        item: entry.item,
        counts: counts,
        policy: .redacted,
        destination: destination(for: entry)
      )
    }
  }

  /// The typed destination for an entry, for the link navigator.
  func destination(for entry: Entry) -> AttentionDestination {
    AttentionDestination(hostProfileID: entry.host.id, item: entry.item)
  }

  /// Snoozes or reviews exactly this occurrence, then refreshes.
  func perform(_ request: AttentionRequest, on entry: Entry) {
    let connector = RoamingAttentionConnector(model: model)
    Task {
      do throws(AttentionServiceError) {
        let service = try await connector.connect(to: entry.host)
        defer { Task { await service.close() } }
        _ = try await (service as? RoamingAttentionService)?.metadata(request)
      } catch {
        hostStates[entry.host.id] = .failed(Self.describe(error))
      }
      refresh()
    }
  }

  static func describe(_ error: AttentionServiceError) -> String {
    switch error {
    case let .offline(reason), let .unsupported(reason), let .other(reason): reason
    case .unauthorized: "Sign-in to the Mac failed."
    case .notFound: "The item is no longer available."
    case .serviceRestarted: "SwiftMux restarted on the Mac."
    case .leaseHeld: "Another device controls this workspace."
    case .leaseChanged: "The workspace's controller changed."
    case .paneExited: "The pane exited."
    }
  }
}
