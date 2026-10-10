import Foundation
import SessionCore
import SwiftMuxProtocol

/// Lease-free host metadata over the SSH bootstrap channel (spec.inbox.md
/// §3, §4): the attention inbox and workspace lease state, read and
/// acknowledged without attaching. Every request is authenticated by SSH;
/// nothing here grants a writer lease or carries input.
public enum AttentionRequest: Hashable, Sendable, Codable {
  /// Workspaces with their lease generations and holders.
  case workspaces
  case inbox(InboxQuery)
  case locate(AttentionReference)
  /// Marks exactly this occurrence seen; never resolves it.
  case markSeen(AttentionReference)
  /// Nil `until` clears the snooze.
  case snooze(AttentionReference, until: Date?)
  case markReviewed(AttentionReference)
}

/// The answer to an `AttentionRequest`. `serviceEpoch` always comes
/// first so a client can detect a restarted service before trusting any
/// other field.
public struct HostMetadata: Hashable, Sendable, Codable {
  public var serviceEpoch: SwiftMuxProtocol.ServerInstanceID
  public var workspaces: [WorkspaceSummary]?
  public var inbox: InboxPage?
  public var location: AttentionLocation?

  public init(
    serviceEpoch: SwiftMuxProtocol.ServerInstanceID,
    workspaces: [WorkspaceSummary]? = nil,
    inbox: InboxPage? = nil,
    location: AttentionLocation? = nil
  ) {
    self.serviceEpoch = serviceEpoch
    self.workspaces = workspaces
    self.inbox = inbox
    self.location = location
  }
}

/// For `resume`: what the new attachment should show and whose lease it
/// may displace.
public struct ResumeTarget: Hashable, Sendable, Codable {
  /// Focused once the lease is held (the pane an attention link names).
  public var pane: PaneID?
  /// Take over only a lease of exactly this generation, the one the user
  /// was shown; a newer holder makes the attachment fail `writerBusy`.
  public var expectedLease: UInt64?

  public init(pane: PaneID? = nil, expectedLease: UInt64? = nil) {
    self.pane = pane
    self.expectedLease = expectedLease
  }
}

// MARK: Identity mapping (spec.inbox.md §1.3)

extension SessionID {
  /// RST/1 session IDs are SwiftMux workspace IDs: the same 16 bytes.
  public init(_ workspace: WorkspaceID) {
    self.init(bytes: workspace.rawValue.uuidBytes)!
  }

  public var workspace: WorkspaceID { WorkspaceID(rawValue: UUID(uuidBytes: bytes)) }
}

extension SessionCore.ServerInstanceID {
  /// The one service epoch: the SwiftMux service instance.
  public init(_ instance: SwiftMuxProtocol.ServerInstanceID) {
    self.init(bytes: instance.rawValue.uuidBytes)!
  }
}

extension UUID {
  var uuidBytes: [UInt8] { withUnsafeBytes(of: uuid) { Array($0) } }

  init(uuidBytes bytes: [UInt8]) {
    precondition(bytes.count == 16)
    var value = UUID().uuid
    withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes) }
    self.init(uuid: value)
  }
}
