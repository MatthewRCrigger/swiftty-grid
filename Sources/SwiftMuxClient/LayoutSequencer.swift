import SwiftMuxProtocol

/// Orders one connection's workspace snapshots: attach, switch and
/// takeover replies against layout events and command replies, which a
/// frontend may receive in either order.
///
/// - Only the workspace named by the last attach/switch/takeover reply
///   (the one this connection holds) is shown.
/// - Layout revisions only move forward per workspace.
/// - A snapshot for a workspace not (yet) attached is kept as the early
///   snapshot: its layout event can overtake the switch reply, which then
///   shows it if newer.
/// - Every attach/switch/takeover reply resyncs, even to the workspace
///   already shown: the service drops the connection's subscriptions on
///   each one, so geometry and subscriptions must be sent again.
public struct LayoutSequencer: Sendable {
  public enum Update: Equatable, Sendable {
    /// Show this snapshot. With `resync`, resend geometry and
    /// subscriptions even when unchanged.
    case show(WorkspaceSnapshot, resync: Bool)
    /// Keep the layout shown (newer than the reply) but resend geometry
    /// and subscriptions.
    case resync
  }

  /// The workspace this connection holds the lease for.
  public private(set) var attachedWorkspace: WorkspaceID?
  /// Layout revisions still retained. Only the shown workspace is kept.
  package var rememberedWorkspaceCount: Int { revisions.count }
  private var shownWorkspace: WorkspaceID?
  /// Highest layout revision shown per workspace.
  private var revisions: [WorkspaceID: UInt64] = [:]
  private var early: WorkspaceSnapshot?

  public init() {}

  /// The reply to an attach, switch or takeover naming `ws`.
  public mutating func attached(_ ws: WorkspaceSnapshot) -> Update {
    attachedWorkspace = ws.id
    var newest = ws
    if let early, early.id == ws.id, early.layoutRevision > ws.layoutRevision {
      newest = early
    }
    early = nil
    if shownWorkspace == ws.id,
      newest.layoutRevision < revisions[ws.id, default: 0]
    {
      return .resync
    }
    record(newest)
    return .show(newest, resync: true)
  }

  /// A layout event or a command's layout reply; nil when not shown
  /// (another workspace, or older than the layout already shown).
  public mutating func layout(_ ws: WorkspaceSnapshot) -> Update? {
    guard ws.id == attachedWorkspace else {
      if early?.id != ws.id || ws.layoutRevision >= early?.layoutRevision ?? 0 {
        early = ws
      }
      return nil
    }
    guard ws.layoutRevision >= revisions[ws.id, default: 0] else { return nil }
    record(ws)
    return .show(ws, resync: false)
  }

  private mutating func record(_ ws: WorkspaceSnapshot) {
    shownWorkspace = ws.id
    // Only this workspace's revision is read. Switching records the reply,
    // or a newer early snapshot, and does not consult the previous entry.
    // Retaining every visit would grow for the life of the connection.
    revisions = [ws.id: ws.layoutRevision]
  }
}
