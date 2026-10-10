import Foundation
import MuxAttention
import SwiftMuxProtocol
import Testing

/// The OSC 7501 reducer: every row of the spec.inbox.md §3 transition
/// table, acceptance 12, 13 and 15, exact-occurrence rules and bounds.
struct AttentionInboxTests {
  let server = ServerInstanceID()
  let pane = PaneID()
  let epoch = TerminalEpochID()
  let context = AttentionContext(workspace: WorkspaceID(), tab: TabID())
  let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

  func inbox(_ edit: (inout MuxLimits) -> Void = { _ in }) -> AttentionInbox {
    var limits = MuxLimits.standard
    edit(&limits)
    return AttentionInbox(serviceEpoch: server, limits: limits)
  }

  func feed(
    _ inbox: inout AttentionInbox,
    _ changes: StatusChange...,
    pane: PaneID? = nil,
    epoch: TerminalEpochID? = nil,
    at: TimeInterval = 0
  ) {
    inbox.apply(
      changes,
      pane: pane ?? self.pane,
      epoch: epoch ?? self.epoch,
      context: context,
      at: t0 + at
    )
  }

  func blocked(
    _ path: String = "",
    _ kind: AttentionBlockedKind = .question,
    progress: UInt8? = nil,
    message: String? = nil
  ) -> StatusChange {
    .report(
      StatusRecord(
        path: path,
        state: .blocked,
        kind: kind,
        progress: progress,
        message: message
      )
    )
  }

  func state(
    _ s: AttentionState,
    _ path: String = "",
    message: String? = nil
  ) -> StatusChange {
    .report(StatusRecord(path: path, state: s, message: message))
  }

  func all(_ inbox: AttentionInbox) throws -> [AttentionItem] {
    try inbox.page(InboxQuery(section: .all), at: t0).items
  }

  func ref(_ item: AttentionItem) -> AttentionReference {
    AttentionReference(source: item.source, occurrence: item.occurrence)
  }

  // MARK: Transition table

  @Test(arguments: [AttentionBlockedKind.permission, .question, .auth])
  func `blocked opens a needs-you occurrence`(
    _ kind: AttentionBlockedKind
  ) throws {
    var box = inbox()
    feed(&box, blocked("", kind))
    let items = try all(box)
    #expect(items.count == 1)
    #expect(items[0].category == .needsYou)
    #expect(items[0].resolution == .open)
    #expect(items[0].status.kind == kind)
    #expect(items[0].workspace == context.workspace)
    #expect(items[0].tab == context.tab)
    #expect(box.counts(at: t0) == InboxCounts(needsYou: 1, results: 0))
  }

  @Test
  func `repeated blocked and progress update the same occurrence`() throws {
    var box = inbox()
    feed(&box, blocked(progress: 10))
    _ = box.takeUpdate(at: t0)
    let first = try all(box)[0]
    feed(&box, blocked(progress: 50), at: 1)
    feed(&box, blocked(message: "still?"), at: 2)
    let items = try all(box)
    #expect(items.count == 1)
    #expect(items[0].occurrence == first.occurrence)
    #expect(items[0].status.message == "still?")
    #expect(items[0].revision > first.revision)
    #expect(items[0].createdAt == first.createdAt)
    let taken = box.takeUpdate(at: t0)
    let update = try #require(taken)
    #expect(update.changed.map(\.occurrence) == [first.occurrence])
  }

  @Test
  func `blocked to working resolves`() throws {
    var box = inbox()
    feed(&box, blocked(), state(.working))
    let items = try all(box)
    #expect(items.count == 1)
    #expect(items[0].resolution == .resolved)
    #expect(box.counts(at: t0).needsYou == 0)
    #expect(box.currentStatus(of: pane).map(\.state) == [.working])
  }

  @Test
  func `blocked working blocked is two occurrences (acceptance 12)`() throws {
    var box = inbox()
    // All three before any flush: reduced first, coalesced after.
    feed(&box, blocked(), state(.working), blocked())
    let taken = box.takeUpdate(at: t0)
    let update = try #require(taken)
    #expect(update.changed.count == 2)
    let first = update.changed[0]
    let second = update.changed[1]
    #expect(first.occurrence != second.occurrence)
    #expect(first.source == second.source)
    #expect(first.resolution == .resolved)
    #expect(second.resolution == .open)
    #expect(update.counts.needsYou == 1)
    // A delayed acknowledgement of the first never touches the second.
    #expect(box.markSeen(ref(first), at: t0).availability == .stale)
    #expect(box.item(second.occurrence)?.seen == false)
    #expect(box.lookup(ref(second)).availability == .available)
  }

  @Test
  func `error retains an unreviewed failure`() throws {
    var box = inbox()
    feed(&box, state(.working), state(.error, message: "boom"))
    feed(&box, state(.working), at: 1)
    let failures = try box.page(InboxQuery(section: .needsYou), at: t0).items
    #expect(failures.count == 1)
    #expect(failures[0].category == .failure)
    #expect(failures[0].status.message == "boom")
    #expect(box.counts(at: t0).needsYou == 1)
    _ = try box.markReviewed(ref(failures[0]), at: t0 + 2)
    #expect(box.counts(at: t0).needsYou == 0)
    #expect(box.item(failures[0].occurrence)?.resolution == .reviewed)
  }

  @Test
  func `done then working keeps the result (acceptance 13)`() throws {
    var box = inbox()
    feed(&box, state(.working), state(.done), state(.working))
    #expect(box.currentStatus(of: pane).map(\.state) == [.working])
    let results = try box.page(InboxQuery(section: .results), at: t0).items
    #expect(results.count == 1)
    #expect(results[0].resolution == .open)
    #expect(box.counts(at: t0) == InboxCounts(needsYou: 0, results: 1))
    // A later result replaces it: one latest result per source.
    feed(&box, state(.done, message: "second"), at: 1)
    let latest = try box.page(InboxQuery(section: .results), at: t0).items
    #expect(latest.count == 1)
    #expect(latest[0].status.message == "second")
    #expect(box.item(results[0].occurrence)?.resolution == .superseded)
    // Repeating the same state updates it in place.
    feed(&box, state(.done, message: "third"), at: 2)
    let same = try box.page(InboxQuery(section: .results), at: t0).items
    #expect(same.map(\.occurrence) == latest.map(\.occurrence))
  }

  @Test
  func `prompt exit and clear resolve requests but keep results`() throws {
    var box = inbox()
    feed(&box, blocked("a"), state(.done, "b"), state(.error, "c"))
    feed(&box, .removed(["a"]), at: 1)
    let items = try all(box)
    #expect(
      items.first { $0.status.source.recordPath == "a" }?.resolution
        == .resolved
    )
    #expect(box.counts(at: t0) == InboxCounts(needsYou: 1, results: 1))
    // Records recreated after removal are a new incarnation.
    feed(&box, blocked("a"), at: 2)
    let again = try box.page(InboxQuery(section: .needsYou), at: t0).items
      .first { $0.category == .needsYou }
    let old = items.first { $0.status.source.recordPath == "a" }
    #expect(again?.source.recordIncarnation != old?.source.recordIncarnation)
  }

  @Test
  func `silence alone never resolves`() throws {
    var box = inbox()
    feed(&box, blocked())
    box.expireSnoozes(at: t0 + 86_400 * 30)
    #expect(box.counts(at: t0 + 86_400 * 30).needsYou == 1)
  }

  @Test
  func `pane exit after the final drain`() throws {
    var box = inbox()
    feed(&box, state(.error, "e"), state(.done, "d"), blocked("q"))
    // The engine's exit lifecycle drops the transient record first.
    feed(&box, .removed(["q"]), at: 1)
    box.paneExited(pane, at: t0 + 2)
    let items = try all(box)
    let request = try #require(items.first { $0.category == .needsYou })
    #expect(request.resolution == .resolved)
    for item in items where item.category != .needsYou {
      #expect(item.resolution == .paneExited)
      #expect(box.lookup(ref(item)).availability == .paneExited)
    }
    // Final failures and results stay unreviewed until reviewed.
    #expect(box.counts(at: t0) == InboxCounts(needsYou: 1, results: 1))
    #expect(box.currentStatus(of: pane).isEmpty)
    let failure = try #require(items.first { $0.category == .failure })
    _ = try box.markReviewed(ref(failure), at: t0 + 3)
    #expect(box.counts(at: t0).needsYou == 0)
  }

  @Test
  func `open request at exit closes as pane exited`() throws {
    var box = inbox()
    feed(&box, blocked())
    box.paneExited(pane, at: t0 + 1)
    let item = try all(box)[0]
    #expect(item.resolution == .paneExited)
    #expect(box.lookup(ref(item)).availability == .paneExited)
    #expect(box.counts(at: t0).needsYou == 0)
  }

  // MARK: Acknowledgement

  @Test
  func `opening marks seen, not resolved (acceptance 15)`() throws {
    var box = inbox()
    feed(&box, blocked())
    let item = try all(box)[0]
    #expect(box.markSeen(ref(item), at: t0 + 1).availability == .available)
    let seen = try all(box)[0]
    #expect(seen.seen)
    #expect(seen.resolution == .open)
    #expect(seen.category == .needsYou)
    #expect(box.counts(at: t0).needsYou == 1)
  }

  @Test
  func `a request cannot be reviewed`() throws {
    var box = inbox()
    feed(&box, blocked())
    let item = try all(box)[0]
    #expect(throws: MuxError.self) { try box.markReviewed(ref(item), at: t0) }
    #expect(box.item(item.occurrence)?.resolution == .open)
  }

  @Test
  func `references must match every field`() throws {
    var box = inbox()
    feed(&box, blocked())
    let item = try all(box)[0]
    var variants: [AttentionReference] = []
    var r = ref(item)
    r.source.serviceEpoch = ServerInstanceID()
    variants.append(r)
    r = ref(item)
    r.source.pane = PaneID()
    variants.append(r)
    r = ref(item)
    r.source.terminalEpoch = TerminalEpochID()
    variants.append(r)
    r = ref(item)
    r.source.recordPath = "other"
    variants.append(r)
    r = ref(item)
    r.source.recordIncarnation += 1
    variants.append(r)
    r = ref(item)
    r.occurrence = OccurrenceID()
    variants.append(r)
    for wrong in variants {
      #expect(box.lookup(wrong) == .missing)
      #expect(box.markSeen(wrong, at: t0) == .missing)
      #expect(box.snooze(wrong, until: t0 + 60, at: t0) == .missing)
      #expect(try box.markReviewed(wrong, at: t0) == .missing)
    }
    #expect(try all(box)[0] == item)
  }

  @Test
  func `snooze hides from counts until it expires`() throws {
    var box = inbox()
    feed(&box, blocked(), state(.done, "r"))
    let items = try all(box)
    for item in items { box.snooze(ref(item), until: t0 + 60, at: t0) }
    #expect(box.counts(at: t0 + 1) == InboxCounts())
    #expect(box.nextSnoozeExpiry == t0 + 60)
    _ = box.takeUpdate(at: t0)
    #expect(box.counts(at: t0 + 61) == InboxCounts(needsYou: 1, results: 1))
    box.expireSnoozes(at: t0 + 61)
    let taken = box.takeUpdate(at: t0 + 61)
    let update = try #require(taken)
    #expect(update.changed.count == 2)
    #expect(update.changed.allSatisfy { $0.snoozedUntil == nil })
    #expect(box.nextSnoozeExpiry == nil)
    // A past date clears instead of snoozing.
    box.snooze(ref(items[0]), until: t0, at: t0 + 62)
    #expect(box.item(items[0].occurrence)?.snoozedUntil == nil)
  }

  @Test
  func `closed items cannot be snoozed`() throws {
    var box = inbox()
    feed(&box, blocked(), state(.working))
    let item = try all(box)[0]
    #expect(box.snooze(ref(item), until: t0 + 60, at: t0) == .stale(item))
    #expect(box.item(item.occurrence)?.snoozedUntil == nil)
  }

  // MARK: Counts and identity

  @Test
  func `needs-you counts distinct sources`() throws {
    var box = inbox()
    // One source with both a failure and a request counts once.
    feed(&box, state(.error, "a"), blocked("a"), blocked("b"))
    #expect(box.counts(at: t0).needsYou == 2)
    let other = PaneID()
    feed(&box, blocked(), pane: other)
    #expect(box.counts(at: t0).needsYou == 3)
  }

  @Test
  func `a terminal reset is a new epoch`() throws {
    var box = inbox()
    feed(&box, blocked("x"), state(.done, "d"))
    let fresh = TerminalEpochID()
    feed(&box, blocked("x"), epoch: fresh, at: 1)
    let requests = try all(box).filter { $0.category == .needsYou }
    #expect(requests.count == 2)
    let old = try #require(requests.first { $0.source.terminalEpoch == epoch })
    let new = try #require(requests.first { $0.source.terminalEpoch == fresh })
    #expect(old.resolution == .resolved)
    #expect(new.resolution == .open)
    #expect(box.currentStatus(of: pane).map(\.source.terminalEpoch) == [fresh])
    // The retained result survives the reset.
    #expect(box.counts(at: t0).results == 1)
  }

  @Test
  func `app is inherited from the nearest ancestor`() throws {
    var box = inbox()
    feed(
      &box,
      .report(StatusRecord(path: "build", state: .working, app: "make")),
      blocked("build/test")
    )
    let item = try box.page(InboxQuery(), at: t0).items[0]
    #expect(item.status.app == "make")
  }

  @Test
  func `sync replays the records after a lost journal`() throws {
    var box = inbox()
    feed(&box, blocked("a"), state(.working, "b"))
    feed(
      &box,
      .sync([StatusRecord(path: "b", state: .blocked, kind: .auth)]),
      at: 1
    )
    let items = try all(box)
    #expect(
      items.first { $0.source.recordPath == "a" }?.resolution == .resolved
    )
    #expect(items.first { $0.source.recordPath == "b" }?.resolution == .open)
    #expect(box.currentStatus(of: pane).map(\.source.recordPath) == ["b"])
  }

  // MARK: Pages

  @Test
  func `pages are bounded and the cursor is stable`() throws {
    var box = inbox { $0.inboxPageSize = 10 }
    for i in 0 ..< 25 { feed(&box, blocked("p\(i)"), at: Double(i)) }
    var seen: [OccurrenceID] = []
    var cursor: String?
    repeat {
      let page = try box.page(
        InboxQuery(section: .needsYou, cursor: cursor, limit: 100),
        at: t0
      )
      #expect(page.items.count <= 10)
      seen += page.items.map(\.occurrence)
      cursor = page.nextCursor
      // Changes between pages neither repeat nor skip existing items.
      feed(&box, blocked("late\(seen.count)"), at: 100)
    } while cursor != nil
    #expect(seen.count == 25)
    #expect(Set(seen).count == 25)
    #expect(throws: MuxError.self) {
      try box.page(InboxQuery(cursor: "garbage"), at: t0)
    }
    #expect(throws: MuxError.self) {
      try box.page(InboxQuery(limit: 0), at: t0)
    }
  }

  // MARK: Bounds

  @Test
  func `records per pane are capped`() throws {
    var box = inbox()
    for i in 0 ... 64 { feed(&box, blocked("r\(i)"), at: Double(i)) }
    #expect(box.currentStatus(of: pane).count == 64)
    #expect(box.counts(at: t0).needsYou == 64)
    let evicted = try all(box).first { $0.source.recordPath == "r0" }
    #expect(evicted?.resolution == .resolved)
  }

  @Test
  func `resolved history is bounded`() throws {
    var box = inbox { $0.resolvedHistory = 4 }
    var refs: [AttentionReference] = []
    for i in 0 ..< 10 {
      feed(&box, blocked(), at: Double(i))
      refs.append(ref(try box.page(InboxQuery(), at: t0).items[0]))
      feed(&box, state(.working), at: Double(i))
    }
    #expect(box.itemCount == 4)
    #expect(box.lookup(refs[0]) == .missing)
    #expect(box.lookup(refs[9]).availability == .stale)
    let taken = box.takeUpdate(at: t0)
    let update = try #require(taken)
    #expect(update.removed.count == 6)
    #expect(update.changed.count == 4)
  }

  @Test
  func `text budget evicts history, then the oldest results`() throws {
    let text = String(repeating: "x", count: 1000)
    var box = inbox { $0.statusTextBytes = 7000 }
    feed(&box, state(.error, "f", message: text), blocked("r", message: text))
    feed(&box, state(.working, "r"), at: 1)  // history: one request
    feed(&box, state(.done, "a", message: text), at: 2)
    feed(&box, .removed(["f"]), at: 3)
    #expect(box.itemCount == 3)
    feed(&box, state(.done, "b", message: text), at: 4)
    // History went first.
    #expect(try all(box).allSatisfy { $0.category != .needsYou })
    feed(&box, state(.done, "c", message: text), at: 5)
    let left = try all(box).map(\.source.recordPath).sorted()
    #expect(left == ["b", "c", "f"])
    #expect(box.textBytes <= box.limits.statusTextBytes)
  }

  @Test
  func `updates coalesce and report removals`() throws {
    var box = inbox()
    #expect(box.takeUpdate(at: t0) == nil)
    feed(&box, blocked(progress: 1), blocked(progress: 2), blocked(progress: 3))
    let taken = box.takeUpdate(at: t0)
    let update = try #require(taken)
    #expect(update.changed.count == 1)
    #expect(update.changed[0].status.progress == 3)
    #expect(update.revision == box.revision)
    #expect(!update.resync)
    #expect(box.takeUpdate(at: t0) == nil)
  }
}
