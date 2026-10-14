import AppKit
import SwiftMuxProtocol
@testable import Swiftty
import Testing

@MainActor
struct MuxSnoozeActivationTests {
  private func menus(in view: NSView) -> [NSPopUpButton] {
    (view as? NSPopUpButton).map { [$0] }
      ?? view.subviews.flatMap { menus(in: $0) }
  }

  @Test
  func oldMenuUsesActivationTimeAndRetainsExactOccurrence() throws {
    let source = AttentionSource(
      serviceEpoch: ServerInstanceID(),
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "ask",
      recordIncarnation: 1
    )
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let item = AttentionItem(
      occurrence: OccurrenceID(),
      source: source,
      workspace: WorkspaceID(),
      tab: nil,
      category: .needsYou,
      resolution: .open,
      status: AttentionStatus(source: source, state: .blocked, updatedAt: now),
      createdAt: now,
      updatedAt: now,
      snoozedUntil: now.addingTimeInterval(3600),
      revision: 1
    )
    var model = MuxInboxModel()
    model.reset([
      .needsYou: InboxPage(
        items: [item],
        counts: InboxCounts(),
        revision: 1,
        nextCursor: nil
      )
    ])
    let controller = MuxInboxViewController()
    controller.snoozeNow = { now }
    var received: [(AttentionItem, Date?)] = []
    controller.onSnooze = { received.append(($0, $1)) }
    controller.update(model)
    let menu = try #require(menus(in: controller.view).first?.menu)
    // Keep the already-created menu open across midnight and past its old snooze.
    now = now.addingTimeInterval(2 * 86400)
    for choice in MuxInboxModel.snoozeChoices(at: now) {
      let action = try #require(menu.items.first { $0.title == choice.title })
      #expect(
        NSApplication.shared.sendAction(
          try #require(action.action),
          to: action.target,
          from: action
        )
      )
      #expect(received.last?.0.source == item.source)
      #expect(received.last?.0.occurrence == item.occurrence)
      #expect(received.last?.1 == choice.until)
    }
    let unsnooze = try #require(menu.items.first { $0.title == "Unsnooze" })
    #expect(
      NSApplication.shared.sendAction(
        try #require(unsnooze.action),
        to: unsnooze.target,
        from: unsnooze
      )
    )
    #expect(received.count == 4)
    #expect(received.last?.0.occurrence == item.occurrence)
    #expect(received.last?.1 == nil)
  }
}
