import Foundation

/// One installation's opaque publisher and its publication sequence.
/// The UUID carries no host, session, credential or attachment authority.
public struct CompanionPublicationIdentity: Hashable, Sendable {
  public let publisherID: UUID
  public let revision: UInt64

  public init(publisherID: UUID = UUID(), revision: UInt64 = 0) {
    self.publisherID = publisherID
    self.revision = revision
  }
}
