import AppKit
import SwiftMuxProtocol
@testable import Swiftty
import Testing

/// The native attention inbox: toolbar badge, popover rows, seen versus
/// resolved, and review of results (unified spec §8; acceptance 15).
extension MuxNativeTests {
  static func osc(_ body: String) -> String {
    "printf '\\033]7501;\(body)\\007'\r"
  }

  @Test(.enabled(if: hasMetal))
  func `inbox badge, open marks seen and review clears results`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let pane = try #require(c.activePane)
    c.send(
      .text(Self.osc("state=blocked:kind=question:app=tool:msg=T2s/")),
      to: pane
    )
    #expect(await until { c.inbox.counts.needsYou == 1 })
    #expect(c.inboxToolbar.item.badge == .count(1))
    let request = try #require(c.inbox.sorted.first)
    #expect(MuxInboxModel.text(request).heading == "Needs an answer: tool")
    #expect(MuxInboxModel.text(request).detail == "Ok?")

    // Opening marks seen; it stays a request (acceptance 15).
    c.openAttention(request)
    #expect(await until { c.inbox.sorted.first?.seen == true })
    #expect(c.inbox.counts.needsYou == 1)
    #expect(c.activePane == pane)

    // The program moving on resolves it; a result is kept for review.
    c.send(.text(Self.osc("state=working")), to: pane)
    c.send(.text(Self.osc("state=done:msg=ZmluaXNoZWQ=")), to: pane)
    #expect(
      await until { c.inbox.counts == InboxCounts(needsYou: 0, results: 1) }
    )
    #expect(c.inboxToolbar.item.badge == nil)
    c.toggleInbox()
    let result = try #require(c.inbox.sorted.first)
    #expect(result.category == .result)
    c.markReviewed(result)
    #expect(await until { c.inbox.items.isEmpty })
    #expect(c.inbox.counts == InboxCounts())
  }

  @Test
  func `inbox model drops stale deltas and closed items`() {
    let source = AttentionSource(
      serviceEpoch: ServerInstanceID(),
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "",
      recordIncarnation: 1
    )
    let occurrence = OccurrenceID()
    func item(
      _ revision: UInt64,
      _ resolution: AttentionResolution
    ) -> AttentionItem {
      AttentionItem(
        occurrence: occurrence,
        source: source,
        workspace: WorkspaceID(),
        tab: nil,
        category: .needsYou,
        resolution: resolution,
        status: AttentionStatus(
          source: source,
          state: .blocked,
          message: "\u{202E}evil\u{1B}[31m",
          updatedAt: Date()
        ),
        createdAt: Date(),
        updatedAt: Date(),
        revision: revision
      )
    }
    var model = MuxInboxModel()
    let first = model.apply(
      InboxUpdate(
        revision: 2,
        counts: InboxCounts(needsYou: 1),
        changed: [item(2, .open)],
        removed: []
      )
    )
    #expect(!first)
    #expect(model.items.count == 1)
    // Program text is sanitized: no bidi overrides or escapes.
    #expect(MuxInboxModel.text(item(2, .open)).detail == "evil[31m")
    // An older delta never overwrites a newer item.
    _ = model.apply(
      InboxUpdate(
        revision: 1,
        counts: InboxCounts(),
        changed: [item(1, .resolved)],
        removed: []
      )
    )
    #expect(model.items.count == 1)
    #expect(model.counts.needsYou == 1)
    _ = model.apply(
      InboxUpdate(
        revision: 3,
        counts: InboxCounts(),
        changed: [item(3, .resolved)],
        removed: []
      )
    )
    #expect(model.items.isEmpty)
    let resync = model.apply(
      InboxUpdate(
        revision: 4,
        counts: InboxCounts(),
        changed: [],
        removed: [],
        resync: true
      )
    )
    #expect(resync)
  }
}
