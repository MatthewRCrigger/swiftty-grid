import Foundation
import SwiftMuxProtocol

/// The typed internal destination of an attention link
/// (spec.inbox.md §4). Kept separate from URL handling: links
/// decode into this value, and navigation only ever works from it.
///
/// Every field is an opaque identifier. There is no endpoint, hostname,
/// username, credential, capability, message text or command here, so a
/// destination is safe to put in a URL, but it is **not** an
/// authentication credential: holding one grants nothing.
public struct AttentionDestination: Sendable, Hashable, Codable {
  /// What the user asked for when following the link.
  public enum Intent: UInt8, Sendable, Hashable, Codable, CaseIterable {
    /// Review a current request (`Needs you`).
    case review = 1
    /// Look at a retained result or failure.
    case result = 2
    /// Reveal the pane without opening any particular item.
    case reveal = 3
  }

  /// The *recipient's* configured host profile. Mapped locally; a link
  /// never names a network endpoint, and an unknown ID asks the user to
  /// pick one of their own configured hosts.
  public var localHostProfileID: UUID
  public var serviceEpoch: ServerInstanceID
  public var workspaceID: WorkspaceID
  public var tabID: TabID?
  public var paneID: PaneID
  public var terminalEpoch: TerminalEpochID
  /// OSC 7501 record id; `""` is the root record.
  public var recordPath: String
  public var recordIncarnation: UInt64
  public var occurrenceID: OccurrenceID
  public var intent: Intent

  public init(
    localHostProfileID: UUID,
    serviceEpoch: ServerInstanceID,
    workspaceID: WorkspaceID,
    tabID: TabID?,
    paneID: PaneID,
    terminalEpoch: TerminalEpochID,
    recordPath: String,
    recordIncarnation: UInt64,
    occurrenceID: OccurrenceID,
    intent: Intent
  ) {
    self.localHostProfileID = localHostProfileID
    self.serviceEpoch = serviceEpoch
    self.workspaceID = workspaceID
    self.tabID = tabID
    self.paneID = paneID
    self.terminalEpoch = terminalEpoch
    self.recordPath = recordPath
    self.recordIncarnation = recordIncarnation
    self.occurrenceID = occurrenceID
    self.intent = intent
  }

  /// A destination for `item` on the host the sender knows as
  /// `hostProfileID`. Program text in the item is not carried over.
  public init(hostProfileID: UUID, item: AttentionItem, intent: Intent? = nil) {
    self.init(
      localHostProfileID: hostProfileID,
      serviceEpoch: item.source.serviceEpoch,
      workspaceID: item.workspace,
      tabID: item.tab,
      paneID: item.source.pane,
      terminalEpoch: item.source.terminalEpoch,
      recordPath: item.source.recordPath,
      recordIncarnation: item.source.recordIncarnation,
      occurrenceID: item.occurrence,
      intent: intent ?? (item.category == .needsYou ? .review : .result)
    )
  }

  public var source: AttentionSource {
    AttentionSource(
      serviceEpoch: serviceEpoch,
      pane: paneID,
      terminalEpoch: terminalEpoch,
      recordPath: recordPath,
      recordIncarnation: recordIncarnation
    )
  }

  /// Exactly this occurrence; every component must still match.
  public var reference: AttentionReference {
    AttentionReference(source: source, occurrence: occurrenceID)
  }

  /// Whether `item` is this exact occurrence of this exact source.
  public func matches(_ item: AttentionItem) -> Bool {
    item.occurrence == occurrenceID && item.source == source
  }

  /// Whether every field satisfies the locator grammar.
  public var isValid: Bool { RecordPathGrammar.isValid(recordPath) }
}

/// OSC 7501 record ids as `ProgramStatusCommand.validID` accepts them
/// (SwifttyEngine), plus `""` for the root record: `segment(/segment)*`
/// with segments of `[A-Za-z0-9_.+-]{1,32}`, at most 8 segments and 128
/// bytes.
public enum RecordPathGrammar {
  public static let maxBytes = 128
  public static let maxSegmentBytes = 32
  public static let maxDepth = 8

  public static func isValid(_ path: String) -> Bool {
    let bytes = path.utf8
    if bytes.isEmpty { return true }
    guard bytes.count <= maxBytes else { return false }
    var depth = 1
    var segment = 0
    for b in bytes {
      if b == 0x2F {  // /
        guard segment > 0 else { return false }
        depth += 1
        segment = 0
        continue
      }
      guard isNameByte(b) else { return false }
      segment += 1
      guard segment <= maxSegmentBytes else { return false }
    }
    return segment > 0 && depth <= maxDepth
  }

  static func isNameByte(_ b: UInt8) -> Bool {
    (0x30 ... 0x39).contains(b) || (0x41 ... 0x5A).contains(b)
      || (0x61 ... 0x7A).contains(b) || b == 0x2E || b == 0x2D || b == 0x5F
      || b == 0x2B
  }
}
