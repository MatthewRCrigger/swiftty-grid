import Foundation
import MuxAttention
import SwiftMuxProtocol

/// The service's attention inbox and its subscribers. Owned by
/// `MuxService` and used only on its queue.
///
/// Status is reduced as it arrives (whether or not any pane is shown,
/// leased or subscribed); subscribers then get coalesced updates. Each
/// subscriber has at most `inboxPendingUpdates` unacknowledged updates;
/// past that its updates are dropped and, once it catches up, it is sent
/// one `resync` update telling it to refetch.
struct InboxHub {
  struct Subscriber {
    var unacknowledged = 0
    var needsResync = false
  }

  private(set) var inbox: AttentionInbox
  private(set) var subscribers: [UUID: Subscriber] = [:]
  var flushScheduled = false
  /// Pending snooze-expiry timer deadline.
  var snoozeDeadline: Date?

  /// Coalescing window between a reduction and its update.
  static let flushDelay: DispatchTimeInterval = .milliseconds(16)

  init(serviceEpoch: ServerInstanceID, limits: MuxLimits) {
    inbox = AttentionInbox(serviceEpoch: serviceEpoch, limits: limits)
  }

  var limits: MuxLimits { inbox.limits }

  mutating func apply(
    _ changes: [StatusChange],
    pane: PaneID,
    epoch: TerminalEpochID,
    context: AttentionContext
  ) {
    inbox.apply(changes, pane: pane, epoch: epoch, context: context, at: Date())
  }

  mutating func paneExited(_ pane: PaneID) {
    inbox.paneExited(pane, at: Date())
  }

  mutating func markSeen(_ ref: AttentionReference) -> AttentionLookup {
    inbox.markSeen(ref, at: Date())
  }

  mutating func snooze(
    _ ref: AttentionReference,
    until: Date?
  ) -> AttentionLookup { inbox.snooze(ref, until: until, at: Date()) }

  mutating func markReviewed(
    _ ref: AttentionReference
  ) throws(MuxError) -> AttentionLookup {
    try inbox.markReviewed(ref, at: Date())
  }

  mutating func expireSnoozes() { inbox.expireSnoozes(at: Date()) }

  func page(_ query: InboxQuery) throws(MuxError) -> InboxPage {
    try inbox.page(query, at: Date())
  }

  // MARK: Subscribers

  /// Adds or removes a subscriber; false when the subscriber bound is
  /// reached.
  mutating func subscribe(_ client: UUID, _ on: Bool) -> Bool {
    guard on else {
      subscribers[client] = nil
      return true
    }
    guard
      subscribers[client] != nil || subscribers.count < limits.inboxSubscribers
    else { return false }
    subscribers[client] = subscribers[client] ?? Subscriber()
    return true
  }

  /// Takes the coalesced update and returns what each subscriber gets.
  mutating func flush() -> [(UUID, InboxUpdate)] {
    flushScheduled = false
    guard let update = inbox.takeUpdate(at: Date()) else { return [] }
    var out: [(UUID, InboxUpdate)] = []
    for (id, var s) in subscribers {
      if s.needsResync || s.unacknowledged >= limits.inboxPendingUpdates {
        s.needsResync = true
      } else {
        s.unacknowledged += 1
        out.append((id, update))
      }
      subscribers[id] = s
    }
    return out
  }

  /// A subscriber took one update; returns a resync update to send when
  /// it had fallen behind and has now caught up.
  mutating func acknowledge(_ client: UUID) -> InboxUpdate? {
    guard var s = subscribers[client] else { return nil }
    s.unacknowledged = max(0, s.unacknowledged - 1)
    var resync: InboxUpdate?
    if s.needsResync, s.unacknowledged < limits.inboxPendingUpdates {
      s.needsResync = false
      s.unacknowledged += 1
      resync = InboxUpdate(
        revision: inbox.revision,
        counts: inbox.counts(at: Date()),
        changed: [],
        removed: [],
        resync: true
      )
    }
    subscribers[client] = s
    return resync
  }
}
