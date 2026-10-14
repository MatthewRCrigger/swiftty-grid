import Foundation
import MuxAttention
import SwiftMuxProtocol
import Testing

struct AttentionInboxCapacityTests {
  private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

  private func inbox(capacity: Int, populated: Bool) -> AttentionInbox {
    var limits = MuxLimits.standard
    limits.inboxPageSize = capacity
    var inbox = AttentionInbox(serviceEpoch: ServerInstanceID(), limits: limits)
    if populated {
      inbox.apply(
        [
          .report(StatusRecord(path: "question", state: .blocked)),
          .report(StatusRecord(path: "result", state: .done)),
        ],
        pane: PaneID(),
        epoch: TerminalEpochID(),
        context: AttentionContext(workspace: WorkspaceID(), tab: nil),
        at: now
      )
    }
    return inbox
  }

  @Test
  func zeroCapacityWithMatchingItems() throws {
    let inbox = inbox(capacity: 0, populated: true)
    do {
      _ = try inbox.page(InboxQuery(section: .all), at: now)
      Issue.record("Disabled paging succeeded with retained items")
    } catch { #expect(error.code == .resourceLimit) }
  }

  @Test(
    arguments: [false, true],
    [InboxQuery.Section.needsYou, .results, .all]
  )
  func disabledPagingReportsCapacityWithoutChangingState(
    populated: Bool,
    section: InboxQuery.Section
  ) throws {
    var inbox = inbox(capacity: 0, populated: populated)
    let revision = inbox.revision
    let counts = inbox.counts(at: now)
    do {
      _ = try inbox.page(InboxQuery(section: section), at: now)
      Issue.record("Disabled paging returned a misleading successful page")
    } catch { #expect(error.code == .resourceLimit) }
    #expect(inbox.revision == revision)
    #expect(inbox.counts(at: now) == counts)
    if populated {
      let taken = inbox.takeUpdate(at: now)
      let update = try #require(taken)
      let item = try #require(update.changed.first { $0.category == .needsYou })
      let reference = AttentionReference(
        source: item.source,
        occurrence: item.occurrence
      )
      #expect(inbox.lookup(reference).item == item)
      let seen = inbox.markSeen(reference, at: now)
      #expect(seen.item?.seen == true)
      #expect(inbox.counts(at: now) == counts)
    }
  }

  @Test
  func invalidRequestsRemainInvalidWithDisabledPaging() {
    let inbox = inbox(capacity: 0, populated: true)
    for query in [
      InboxQuery(limit: 0), InboxQuery(limit: -1),
      InboxQuery(cursor: "not a cursor"),
    ] {
      do {
        _ = try inbox.page(query, at: now)
        Issue.record("Invalid query succeeded")
      } catch { #expect(error.code == .invalidRequest) }
    }
  }

  @Test
  func capacityOneMakesProgressAndEndsOnlyAfterAllItems() throws {
    let inbox = inbox(capacity: 1, populated: true)
    let first = try inbox.page(InboxQuery(section: .all), at: now)
    let cursor = try #require(first.nextCursor)
    let second = try inbox.page(
      InboxQuery(section: .all, cursor: cursor),
      at: now
    )
    #expect(first.items.count == 1 && second.items.count == 1)
    #expect(first.items.first?.occurrence != second.items.first?.occurrence)
    #expect(second.nextCursor == nil)
    #expect(first.counts == InboxCounts(needsYou: 1, results: 1))
    #expect(second.counts == first.counts)
    #expect(second.revision == first.revision)
  }
}
