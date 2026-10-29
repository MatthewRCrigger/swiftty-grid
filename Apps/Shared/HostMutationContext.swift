import Foundation
import SSHIdentity

/// The account and saved revision reviewed before a host action.
/// A new host also reserves its UUID, so an arriving record cannot be overwritten.
struct HostMutationContext: Hashable, Identifiable, Sendable {
  let id: UUID
  let original: HostProfile?
  let revision: LogicalRevision?
  let conflict: HostConflict?
  let scope: String?
  let accountGeneration: Int
}

extension RoamingAppModel {
  static var hostChangedMessage: String {
    String(
      localized:
        "The host or account changed. Reopen the host and review it before making changes.",
      bundle: #bundle
    )
  }

  func hostMutationContext(
    for original: HostProfile?,
    id: UUID? = nil
  ) -> HostMutationContext {
    let id = original?.id ?? id ?? UUID()
    return HostMutationContext(
      id: id,
      original: original,
      revision: connections.hostRevisions[id],
      conflict: connections.hostConflicts[id],
      scope: connections.scopes[ConnectionSnapshot.hostRecord(id)],
      accountGeneration: accountGeneration
    )
  }

  func canMutateHost(_ id: UUID) -> Bool {
    connections.isVisible(ConnectionSnapshot.hostRecord(id))
      && connections.hostTombstones[id] == nil
      && (connections.hosts.contains { $0.id == id }
        || !connections.cachedHosts.contains { $0.id == id })
  }

  func hostMutationIsCurrent(_ context: HostMutationContext) -> Bool {
    context.accountGeneration == accountGeneration && canMutateHost(context.id)
      && connections.hosts.first { $0.id == context.id } == context.original
      && connections.hostRevisions[context.id] == context.revision
      && connections.hostConflicts[context.id] == context.conflict
      && connections.scopes[ConnectionSnapshot.hostRecord(context.id)]
        == context.scope
  }

  /// Legacy recovery may change only this selection's authentication to its
  /// verified label mapping. Other host/account changes still require review.
  func hostAfterLegacyMigration(_ context: HostMutationContext) -> HostProfile?
  {
    guard let original = context.original,
      case .legacyKey(let label) = original.auth,
      context.accountGeneration == accountGeneration, canMutateHost(context.id),
      context.scope
        == connections.scopes[ConnectionSnapshot.hostRecord(context.id)],
      context.conflict == connections.hostConflicts[context.id],
      let current = hosts.first(where: { $0.id == context.id })
    else { return nil }
    var originalFields = current
    originalFields.auth = original.auth
    guard originalFields == original else { return nil }
    if current.auth != original.auth {
      guard case .key(let id) = current.auth,
        connections.migration.labelMap[label] == id
      else { return nil }
    }
    return current
  }
}
