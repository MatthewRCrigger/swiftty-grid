import Foundation
import SwiftMuxProtocol
@testable import Swiftty
import Testing

struct MuxInboxOrderingTests {
  private func item(
    _ occurrence: OccurrenceID,
    revision: UInt64
  ) -> AttentionItem {
    let source = AttentionSource(
      serviceEpoch: ServerInstanceID(),
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "",
      recordIncarnation: 1
    )
    return AttentionItem(
      occurrence: occurrence,
      source: source,
      workspace: WorkspaceID(),
      tab: nil,
      category: .needsYou,
      resolution: .open,
      status: .init(source: source, state: .blocked, updatedAt: Date()),
      createdAt: Date(),
      updatedAt: Date(),
      revision: revision
    )
  }

  private func page(
    _ items: [AttentionItem],
    revision: UInt64,
    cursor: String? = nil
  ) -> InboxPage {
    .init(
      items: items,
      counts: .init(needsYou: items.count),
      revision: revision,
      nextCursor: cursor
    )
  }

  @Test
  func anOlderRemovalCannotDeleteANewerItem() {
    let id = OccurrenceID()
    var model = MuxInboxModel()
    _ = model.apply(
      .init(
        revision: 9,
        counts: .init(needsYou: 1),
        changed: [item(id, revision: 9)],
        removed: []
      )
    )
    _ = model.apply(
      .init(revision: 8, counts: .init(), changed: [], removed: [id])
    )
    #expect(model.items[id]?.revision == 9)
    #expect(model.counts.needsYou == 1)
  }

  @Test(arguments: [false, true])
  func aRemovalWinsOverChangesAtTheSameRevision(pageReply: Bool) {
    let id = OccurrenceID()
    var model = MuxInboxModel()
    _ = model.apply(
      .init(revision: 8, counts: .init(), changed: [], removed: [id])
    )
    if pageReply {
      model.append(
        page([item(id, revision: 8)], revision: 8),
        section: .needsYou
      )
    } else {
      _ = model.apply(
        .init(
          revision: 8,
          counts: .init(),
          changed: [item(id, revision: 8)],
          removed: []
        )
      )
    }
    #expect(model.items.isEmpty)
  }

  @Test(arguments: [false, true])
  func oldPagesCannotEraseLoadedRowsOrRewindCursors(reset: Bool) {
    let id = OccurrenceID()
    var model = MuxInboxModel()
    model.reset([
      .needsYou: page([item(id, revision: 1)], revision: 10, cursor: "current")
    ])
    let old = page([], revision: 9, cursor: "old")
    if reset {
      model.reset([.needsYou: old])
    } else {
      model.append(old, section: .needsYou)
    }
    #expect(model.items[id] != nil)
    #expect(model.cursors[.needsYou] == "current")
    #expect(model.revision == 10)
  }
}
