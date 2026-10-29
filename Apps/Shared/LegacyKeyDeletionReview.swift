import Foundation

/// A prepared, non-secret review of a matching key in the current account.
/// Confirmation rejects changes to either the account context or the journal.
struct LegacyKeyDeletionReview: Identifiable, Hashable, Sendable {
  let intent: IdentityIntent
  let account: String
  let generation: Int
  let metadataAccount: String?
  let fingerprint: String

  var id: UUID { intent.id }
  var name: String { intent.name }
}
