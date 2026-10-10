import AppKit
import SwiftMuxClient
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

  @Test(.enabled(if: hasMetal))
  func `snooze hides a request from the badge until unsnoozed`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let pane = try #require(c.activePane)
    c.send(.text(Self.osc("state=blocked:kind=permission:app=tool")), to: pane)
    #expect(await until { c.inbox.counts.needsYou == 1 })
    let request = try #require(c.inbox.sorted.first)
    #expect(MuxInboxModel.canSnooze(request))
    #expect(MuxInboxModel.snoozeText(request, at: Date()) == nil)

    c.snooze(request, until: Date().addingTimeInterval(3600))
    #expect(
      await until {
        c.inbox.counts.needsYou == 0
          && c.inbox.sorted.first?.snoozedUntil != nil
      }
    )
    #expect(c.inboxToolbar.item.badge == nil)
    let snoozed = try #require(c.inbox.sorted.first)
    #expect(
      MuxInboxModel.snoozeText(snoozed, at: Date())?.hasPrefix("Snoozed until ")
        == true
    )

    c.snooze(snoozed, until: nil)
    #expect(
      await until {
        c.inbox.counts.needsYou == 1
          && c.inbox.sorted.first?.snoozedUntil == nil
      }
    )
    #expect(c.inboxMessage == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `stale and missing items are reported and the list reread`() async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    var told: [String] = []
    c.confirmDestructive = { message in
      told.append(message)
      return false
    }
    let pane = try #require(c.activePane)
    c.send(.text(Self.osc("state=blocked:kind=question:app=tool")), to: pane)
    #expect(await until { c.inbox.counts.needsYou == 1 })
    let request = try #require(c.inbox.sorted.first)
    c.send(.text(Self.osc("state=working")), to: pane)
    #expect(await until { c.inbox.items.isEmpty })

    // A request the program already resolved: stale, never snoozed.
    c.snooze(request, until: Date().addingTimeInterval(900))
    #expect(await until { told.count == 1 })
    #expect(told.first == "The program has already moved on from this request.")
    #expect(c.inboxMessage == told.first)

    // An occurrence the service never had: missing.
    var unknown = request
    unknown.occurrence = OccurrenceID()
    unknown.category = .result
    c.markReviewed(unknown)
    #expect(await until { told.count == 2 })
    #expect(told.last == "This item is no longer available.")

    // Opening it reports the same, without touching any pane.
    c.openAttention(unknown)
    #expect(await until { told.count == 3 })
    #expect(told.last == "This item is no longer available.")
    #expect(c.activePane == pane)
  }

  @Test(.enabled(if: hasMetal))
  func `load more reads the pages beyond the first`() async throws {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    c.inboxPageLimit = 2
    let pane = try #require(c.activePane)
    for id in ["a", "b", "c"] {
      c.send(
        .text(Self.osc("id=\(id):state=blocked:kind=question:app=\(id)")),
        to: pane
      )
    }
    #expect(await until { c.inbox.counts.needsYou == 3 })
    #expect(await until { c.inbox.items.count == 3 })
    await c.reloadInbox()
    #expect(c.inbox.items.count == 2)
    #expect(c.inbox.hasMore)
    await c.loadMoreInbox()
    #expect(c.inbox.items.count == 3)
    #expect(!c.inbox.hasMore)
    #expect(c.inboxMessage == nil)
  }

  @Test(.enabled(if: hasMetal))
  func `opening a workspace held elsewhere asks again when control moves`()
    async throws
  {
    let f = try await open()
    defer { f.controller.close() }
    let c = f.controller
    let other = try await MuxConnection.connect(
      endpoint: f.endpoint,
      frontend: .native
    )
    defer { Task { await other.close() } }
    let launch = LaunchSpec(
      command: ["/bin/sh"],
      workingDirectory: "/tmp",
      environment: [
        "PATH": "/usr/bin:/bin", "PS1": "$ ", "HOME": NSTemporaryDirectory(),
      ]
    )
    guard
      case let .created(created) = try await other.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch))
      ),
      case let .attached(_, ws) = try await other.execute(
        .attach(.id(created.id))
      ), let pane = ws.activeTabSnapshot?.activePane
    else {
      Issue.record("no second workspace")
      return
    }
    await other.post(
      .text(Self.osc("state=blocked:kind=question:app=far")),
      to: pane
    )
    #expect(await until { c.inbox.sorted.contains { $0.workspace == ws.id } })
    let item = try #require(c.inbox.sorted.first { $0.workspace == ws.id })

    // The holder reattaches while the user decides: the first takeover
    // is refused as stale and the user is asked again.
    var asked: [String] = []
    c.confirmDestructive = { message in
      asked.append(message)
      if asked.count == 1 {
        _ = try? await other.execute(.detach)
        _ = try? await other.execute(.attach(.id(ws.id)))
      }
      return true
    }
    c.openAttention(item)
    #expect(await until { c.workspace?.id == ws.id })
    #expect(asked.count == 2)
    #expect(asked.first?.hasPrefix("Take control of workspace") == true)
    #expect(asked.last?.contains("changed while you were deciding") == true)
    #expect(await until { c.activePane == pane })
  }

  @Test
  func `snooze choices, wording and paging cursors`() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(
      calendar.date(
        from: DateComponents(
          year: 2026,
          month: 10,
          day: 10,
          hour: 14,
          minute: 30
        )
      )
    )
    let choices = MuxInboxModel.snoozeChoices(at: now, calendar: calendar)
    #expect(
      choices.map(\.title) == ["15 Minutes", "1 Hour", "Tomorrow at 9:00"]
    )
    #expect(choices[0].until == now.addingTimeInterval(900))
    #expect(choices[1].until == now.addingTimeInterval(3600))
    #expect(
      choices[2].until
        == calendar.date(
          from: DateComponents(year: 2026, month: 10, day: 11, hour: 9)
        )
    )

    #expect(
      MuxInboxModel.describe(MuxError(.staleRevision))
        .contains("changed while you were deciding")
    )
    #expect(
      MuxInboxModel.describe(MuxError(.leaseHeld))
        .hasPrefix("Another window or device controls this workspace.")
    )
    #expect(
      MuxInboxModel.describe(MuxError(.invalidRequest, "inbox cursor"))
        == "SwiftMux refused the request: inbox cursor"
    )
    #expect(MuxInboxModel.describe(.available) == nil)
    #expect(MuxInboxModel.describe(.paneExited) == nil)
    #expect(MuxInboxModel.describe(.stale) != nil)

    let source = AttentionSource(
      serviceEpoch: ServerInstanceID(),
      pane: PaneID(),
      terminalEpoch: TerminalEpochID(),
      recordPath: "",
      recordIncarnation: 1
    )
    func item(snoozed: Date?, created: Date) -> AttentionItem {
      AttentionItem(
        occurrence: OccurrenceID(),
        source: source,
        workspace: WorkspaceID(),
        tab: nil,
        category: .needsYou,
        resolution: .open,
        status: AttentionStatus(
          source: source,
          state: .blocked,
          updatedAt: created
        ),
        createdAt: created,
        updatedAt: created,
        snoozedUntil: snoozed,
        revision: 1
      )
    }
    // The snoozed request is the newer one, yet sorts last.
    let later = item(snoozed: now.addingTimeInterval(3600), created: now)
    let waiting = item(snoozed: nil, created: now.addingTimeInterval(-60))
    #expect(MuxInboxModel.snoozeText(waiting, at: now) == nil)
    #expect(
      MuxInboxModel.snoozeText(later, at: now, calendar: calendar)?
        .hasPrefix("Snoozed until ") == true
    )
    #expect(
      MuxInboxModel.snoozeText(later, at: now.addingTimeInterval(7200)) == nil
    )

    var model = MuxInboxModel()
    model.reset([
      .needsYou: InboxPage(
        items: [later],
        counts: InboxCounts(needsYou: 1),
        revision: 1,
        nextCursor: "next"
      ),
      .results: InboxPage(
        items: [],
        counts: InboxCounts(needsYou: 1),
        revision: 1,
        nextCursor: nil
      ),
    ])
    #expect(model.hasMore)
    #expect(model.cursors == [.needsYou: "next"])
    model.append(
      InboxPage(
        items: [waiting],
        counts: InboxCounts(needsYou: 1),
        revision: 1,
        nextCursor: nil
      ),
      section: .needsYou
    )
    #expect(!model.hasMore)
    #expect(
      model.sorted(at: now).map(\.occurrence) == [
        waiting.occurrence, later.occurrence,
      ]
    )
    model.forget(waiting.occurrence)
    #expect(model.items.count == 1)
  }
}
