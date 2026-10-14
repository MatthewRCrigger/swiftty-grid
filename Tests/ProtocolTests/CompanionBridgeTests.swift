import CompanionModel
import Foundation
import Testing

struct CompanionBridgeTests {
  let publisherID = UUID()
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)
  let token = UUID()

  func observation(
    _ state: CompanionConnectionState,
    at date: Date,
    token: UUID? = nil
  ) -> PhoneCompanionBridge.Observation {
    PhoneCompanionBridge.Observation(
      sessionToken: token ?? self.token,
      nickname: "studio",
      state: state,
      observedAt: date,
      lastScreenAt: date
    )
  }

  // MARK: RefreshGate

  @Test
  func `only one refresh may be pending`() throws {
    var gate = RefreshGate(timeout: 10)
    let r1 = gate.begin(.refresh, now: t0)
    let first = try #require(r1)
    let r2 = gate.begin(.refresh, now: t0.addingTimeInterval(1))
    #expect(r2 == nil)
    let r3 = gate.begin(.preview, now: t0.addingTimeInterval(2))
    #expect(r3 == nil)
    // A reply for another request does not release the gate.
    let r4 = gate.complete(CompanionRequestID.random())
    #expect(!r4)
    #expect(gate.isPending)
    let r5 = gate.complete(first.id)
    #expect(r5)
    let r6 = gate.complete(first.id)
    #expect(!r6)
    let r7 = gate.begin(.refresh, now: t0.addingTimeInterval(3))
    let second = try #require(r7)
    // An unanswered request expires so the watch can try again later.
    let r8 = gate.begin(.refresh, now: t0.addingTimeInterval(12))
    #expect(r8 == nil)
    let r9 = gate.begin(.refresh, now: t0.addingTimeInterval(13))
    let third = try #require(r9)
    #expect(third.id != second.id)
    let r10 = gate.complete(second.id)
    #expect(!r10)
  }

  @Test(arguments: [TimeInterval.nan, TimeInterval.infinity])
  func `a nonfinite refresh timeout cannot wedge the gate`(
    timeout: TimeInterval
  ) throws {
    var gate = RefreshGate(timeout: timeout)
    #expect(gate.timeout == CompanionLimits.refreshTimeout)
    let started = gate.begin(.refresh, now: t0)
    let first = try #require(started)
    let blocked = gate.begin(.refresh, now: t0.addingTimeInterval(1))
    #expect(blocked == nil)
    let expired = gate.expireIfNeeded(now: t0.addingTimeInterval(15))
    #expect(expired)
    let restarted = gate.begin(.refresh, now: t0.addingTimeInterval(15))
    let second = try #require(restarted)
    #expect(second.id != first.id)
    let completedOld = gate.complete(first.id)
    #expect(!completedOld)
  }

  @Test
  func `watch store keeps one pending request and ignores stray replies`()
    throws
  {
    var store = WatchCompanionStore()
    let r11 = store.beginRequest(.refresh, now: t0)
    #expect(r11 == nil)  // inactive, unreachable
    store.setActive(true)
    let r12 = store.beginRequest(.refresh, now: t0)
    #expect(r12 == nil)  // unreachable
    store.setReachable(true)
    let r13 = store.beginRequest(.refresh, now: t0)
    let request = try #require(r13)
    let r14 = store.beginRequest(.refresh, now: t0)
    #expect(r14 == nil)
    let status = CompanionStatus(
      sessionNickname: "x",
      state: .active,
      capturedAt: t0
    )
    let r15 = store.receive(
      .status(
        .random(),
        status,
        previewUnavailable: nil,
        publisherID: publisherID
      )
    )
    #expect(!r15)
    #expect(store.status == nil)
    let r16 = store.receive(
      .status(
        request.id,
        status,
        previewUnavailable: nil,
        publisherID: publisherID
      )
    )
    #expect(r16)
    #expect(store.status == status)
    #expect(!store.gate.isPending)
  }

  // MARK: Staleness

  @Test
  func `staleness is evaluated honestly against now`() {
    let policy = CompanionStaleness(
      freshFor: 60,
      unavailableAfter: 600,
      futureSkew: 5
    )
    #expect(policy.evaluate(capturedAt: nil, now: t0) == .unavailable)
    #expect(policy.evaluate(capturedAt: t0, now: t0) == .fresh)
    #expect(
      policy.evaluate(capturedAt: t0, now: t0.addingTimeInterval(60)) == .fresh
    )
    #expect(
      policy.evaluate(capturedAt: t0, now: t0.addingTimeInterval(61)) == .stale
    )
    #expect(
      policy.evaluate(capturedAt: t0, now: t0.addingTimeInterval(601))
        == .unavailable
    )
    // A future timestamp is not trusted as current.
    #expect(
      policy.evaluate(capturedAt: t0.addingTimeInterval(30), now: t0) == .stale
    )

    // The watch's view ages with the clock; nothing refreshes it silently.
    var store = WatchCompanionStore(staleness: policy)
    store.receive(
      .status(
        CompanionStatus(sessionNickname: nil, state: .active, capturedAt: t0),
        publisherID: publisherID
      )
    )
    #expect(store.presentation(now: t0).freshness == .fresh)
    #expect(
      store.presentation(now: t0.addingTimeInterval(120)).freshness == .stale
    )
    #expect(
      store.presentation(now: t0.addingTimeInterval(120)).capturedAt == t0
    )
    #expect(!store.presentation(now: t0).phoneReachable)
  }

  @Test
  func `older status never replaces newer status`() {
    var store = WatchCompanionStore()
    let newer = CompanionStatus(
      sessionNickname: nil,
      state: .reconnecting,
      capturedAt: t0
    )
    let older = CompanionStatus(
      sessionNickname: nil,
      state: .active,
      capturedAt: t0.addingTimeInterval(-30)
    )
    store.receive(.status(newer, revision: 2, publisherID: publisherID))
    store.receive(.status(older, revision: 1, publisherID: publisherID))
    #expect(store.status == newer)
  }

  // MARK: Phone bridge

  @Test
  func `an older preview reply cannot attach text to newer status`() throws {
    var store = WatchCompanionStore()
    store.setActive(true)
    store.setReachable(true)
    let older = CompanionStatus(
      sessionNickname: "old session",
      state: .active,
      capturedAt: t0,
      previewAvailable: true
    )
    store.receive(.status(older, revision: 1, publisherID: publisherID))
    let pending = store.beginRequest(.preview, now: t0)
    let request = try #require(pending)
    let newer = CompanionStatus(
      sessionNickname: "new session",
      state: .active,
      capturedAt: t0.addingTimeInterval(1),
      previewAvailable: true
    )
    store.receive(.status(newer, revision: 2, publisherID: publisherID))
    let accepted = store.receive(
      .preview(
        request.id,
        older,
        CompanionPreview(lines: ["old output"], capturedAt: t0),
        revision: 1,
        publisherID: publisherID
      )
    )
    #expect(accepted)
    #expect(store.status == newer)
    #expect(store.preview == nil)
    #expect(!store.gate.isPending)
  }

  @Test
  func `a session change drops preview even when the nickname matches`() throws
  {
    var bridge = PhoneCompanionBridge(
      settings: CompanionSettings(sharingEnabled: true, previewEnabled: true),
      isForeground: true,
      now: t0,
      publisherID: publisherID
    )
    _ = bridge.observe(observation(.active, at: t0))
    bridge.observePreview(lines: ["first session"], capturedAt: t0)
    let firstOwner = try #require(bridge.status?.previewOwner)
    var watch = WatchCompanionStore()
    watch.setActive(true)
    watch.setReachable(true)
    let installed = watch.receive(bridge.applicationContext)
    #expect(installed)
    let requested = watch.beginRequest(.preview, now: t0)
    let request = try #require(requested)
    let showed = watch.receive(bridge.reply(to: request))
    #expect(showed)
    #expect(watch.preview?.lines == ["first session"])
    #expect(watch.preview?.owner == firstOwner)

    let changed = bridge.observe(
      PhoneCompanionBridge.Observation(
        sessionToken: UUID(),
        nickname: "studio",
        state: .active,
        observedAt: t0.addingTimeInterval(1),
        lastScreenAt: t0.addingTimeInterval(1)
      )
    )
    let context = try #require(changed)
    #expect(!bridge.hasCachedPreview)
    let secondOwner = try #require(bridge.status?.previewOwner)
    #expect(secondOwner != firstOwner)
    guard case .status(_, _, .noScreen, _, _) = bridge.reply(to: request) else {
      Issue.record("expected noScreen for the new session")
      return
    }
    let replaced = watch.receive(context)
    #expect(replaced)
    #expect(watch.status?.sessionNickname == "studio")
    #expect(watch.status?.previewOwner == secondOwner)
    #expect(watch.preview == nil)

    let requestedAgain = watch.beginRequest(
      .preview,
      now: t0.addingTimeInterval(2)
    )
    let pending = try #require(requestedAgain)
    let late = CompanionReply.preview(
      pending.id,
      CompanionStatus(
        sessionNickname: "studio",
        state: .active,
        capturedAt: t0,
        previewAvailable: true,
        previewOwner: firstOwner
      ),
      CompanionPreview(
        lines: ["first session"],
        capturedAt: t0,
        owner: firstOwner
      ),
      revision: 1,
      publisherID: publisherID
    )
    let delayed = watch.receive(late)
    #expect(delayed)
    #expect(watch.status?.previewOwner == secondOwner)
    #expect(watch.preview == nil)

    let refreshRequest = watch.beginRequest(
      .refresh,
      now: t0.addingTimeInterval(3)
    )
    let refresh = try #require(refreshRequest)
    bridge.observePreview(
      lines: ["second session"],
      capturedAt: t0.addingTimeInterval(1)
    )
    let refreshed = watch.receive(bridge.reply(to: refresh))
    #expect(refreshed)
    #expect(watch.preview == nil)
    let previewRequestValue = watch.beginRequest(
      .preview,
      now: t0.addingTimeInterval(4)
    )
    let previewRequest = try #require(previewRequestValue)
    let shown = watch.receive(bridge.reply(to: previewRequest))
    #expect(shown)
    #expect(watch.preview?.lines == ["second session"])
    #expect(watch.preview?.owner == secondOwner)
  }

  @Test(arguments: [
    CompanionPreviewUnavailable.noScreen,
    CompanionPreviewUnavailable.phoneNotForeground,
  ])
  func `an unavailable preview status reply drops the cached text`(
    reason: CompanionPreviewUnavailable
  ) throws {
    let owner: UInt64 = 4
    let status = CompanionStatus(
      sessionNickname: "studio",
      state: .active,
      capturedAt: t0,
      previewAvailable: true,
      previewOwner: owner
    )
    var watch = WatchCompanionStore()
    watch.setActive(true)
    watch.setReachable(true)
    let primed = watch.receive(
      .status(status, revision: 1, publisherID: publisherID)
    )
    #expect(primed)
    let requested = watch.beginRequest(.preview, now: t0)
    let first = try #require(requested)
    let showed = watch.receive(
      .preview(
        first.id,
        status,
        CompanionPreview(lines: ["visible"], capturedAt: t0, owner: owner),
        revision: 1,
        publisherID: publisherID
      )
    )
    #expect(showed)
    #expect(watch.preview?.lines == ["visible"])

    let refreshRequest = watch.beginRequest(
      .refresh,
      now: t0.addingTimeInterval(1)
    )
    let refresh = try #require(refreshRequest)
    let kept = watch.receive(
      .status(
        refresh.id,
        status,
        previewUnavailable: nil,
        revision: 2,
        publisherID: publisherID
      )
    )
    #expect(kept)
    #expect(watch.preview?.lines == ["visible"])

    let unavailableRequest = watch.beginRequest(
      .preview,
      now: t0.addingTimeInterval(2)
    )
    let unavailable = try #require(unavailableRequest)
    let dropped = watch.receive(
      .status(
        unavailable.id,
        status,
        previewUnavailable: reason,
        revision: 3,
        publisherID: publisherID
      )
    )
    #expect(dropped)
    #expect(watch.status == status)
    #expect(watch.preview == nil)

    let mismatchedRequest = watch.beginRequest(
      .preview,
      now: t0.addingTimeInterval(3)
    )
    let mismatched = try #require(mismatchedRequest)
    let rejected = watch.receive(
      .preview(
        mismatched.id,
        status,
        CompanionPreview(lines: ["other"], capturedAt: t0, owner: owner + 1),
        revision: 4,
        publisherID: publisherID
      )
    )
    #expect(rejected)
    #expect(watch.preview == nil)
  }

  @Test
  func `bridge never reports a fresher time than observed`() throws {
    var bridge = PhoneCompanionBridge(isForeground: true, now: t0)
    _ = bridge.observe(observation(.active, at: t0.addingTimeInterval(5)))
    // Out-of-order older observations are ignored.
    let r17 = bridge.observe(observation(.idle, at: t0.addingTimeInterval(1)))
    #expect(r17 == nil)

    // However late the refresh arrives, the reply carries the observation
    // time, never the time of answering.
    let request = CompanionRequest(kind: .refresh)
    let replyData = try #require(
      bridge.reply(toMessageData: CompanionCodec.encode(request))
    )
    guard
      case .status(let id, let status, _, _, _) =
        try CompanionCodec.decodeReply(replyData)
    else {
      Issue.record("expected status reply")
      return
    }
    #expect(id == request.id)
    #expect(status.state == .active)
    #expect(status.capturedAt <= t0.addingTimeInterval(5))
    #expect(status.capturedAt > t0.addingTimeInterval(4.99))
    #expect(status.lastScreenAt.map { $0 <= status.capturedAt } ?? true)

    // A later screen time than observation is clamped, not reported.
    _ = bridge.observe(
      PhoneCompanionBridge.Observation(
        sessionToken: token,
        nickname: nil,
        state: .active,
        observedAt: t0.addingTimeInterval(10),
        lastScreenAt: t0.addingTimeInterval(99)
      )
    )
    #expect(bridge.status?.lastScreenAt == t0.addingTimeInterval(10))
  }

  @Test
  func `preview is off by default and only served in the foreground`() throws {
    var bridge = PhoneCompanionBridge(isForeground: true, now: t0)
    #expect(!CompanionSettings.default.previewEnabled)
    _ = bridge.observe(observation(.active, at: t0))
    bridge.observePreview(lines: ["secret output"], capturedAt: t0)
    #expect(!bridge.hasCachedPreview)
    let preview = CompanionRequest(kind: .preview)
    guard
      case .status(_, let status, .notEnabled, _, _) = bridge.reply(to: preview)
    else {
      Issue.record("expected notEnabled")
      return
    }
    #expect(!status.previewAvailable)

    _ = bridge.update(
      CompanionSettings(sharingEnabled: true, previewEnabled: true),
      now: t0
    )
    bridge.observePreview(lines: ["$ make", "ok"], capturedAt: t0)
    guard case .preview(_, _, let text, _, _) = bridge.reply(to: preview) else {
      Issue.record("expected preview")
      return
    }
    #expect(text.lines == ["$ make", "ok"])
    // A refresh never includes preview text.
    guard case .status = bridge.reply(to: CompanionRequest(kind: .refresh))
    else {
      Issue.record("expected status")
      return
    }

    // Leaving the foreground drops preview text and refuses new previews.
    bridge.setForeground(false)
    #expect(!bridge.hasCachedPreview)
    bridge.observePreview(lines: ["late"], capturedAt: t0.addingTimeInterval(1))
    #expect(!bridge.hasCachedPreview)
    guard
      case .status(_, _, .phoneNotForeground, _, _) = bridge.reply(to: preview)
    else {
      Issue.record("expected phoneNotForeground")
      return
    }

    // Switching sessions discards the previous session's preview.
    bridge.setForeground(true)
    bridge.observePreview(
      lines: ["old session"],
      capturedAt: t0.addingTimeInterval(2)
    )
    _ = bridge.observe(
      observation(.attaching, at: t0.addingTimeInterval(3), token: UUID())
    )
    #expect(!bridge.hasCachedPreview)

    // The application context is status only, whatever is cached.
    bridge.observePreview(
      lines: ["cached"],
      capturedAt: t0.addingTimeInterval(4)
    )
    guard case .status = bridge.applicationContext else {
      Issue.record("expected status context")
      return
    }
  }

  @Test
  func `phone opt out clears cached companion data on both sides`() throws {
    var bridge = PhoneCompanionBridge(
      settings: CompanionSettings(sharingEnabled: true, previewEnabled: true),
      isForeground: true,
      now: t0
    )
    _ = bridge.observe(observation(.active, at: t0))
    bridge.observePreview(lines: ["text"], capturedAt: t0)

    var watch = WatchCompanionStore()
    watch.setActive(true)
    watch.setReachable(true)
    watch.receive(bridge.applicationContext)
    let r18 = watch.beginRequest(.preview, now: t0)
    let request = try #require(r18)
    #expect(request.kind == .preview)
    let r19 = watch.receive(bridge.reply(to: request))
    #expect(r19)
    #expect(watch.preview?.lines == ["text"])

    let off = bridge.update(
      CompanionSettings(sharingEnabled: false, previewEnabled: true),
      now: t0.addingTimeInterval(1)
    )
    #expect(
      off
        == .cleared(
          at: t0.addingTimeInterval(1),
          revision: bridge.publicationRevision,
          publisherID: bridge.publisherID
        )
    )
    #expect(bridge.status == nil)
    #expect(!bridge.hasCachedPreview)
    // Observations while opted out are not retained or published.
    let r20 = bridge.observe(observation(.active, at: t0.addingTimeInterval(2)))
    #expect(r20 == nil)
    #expect(bridge.status == nil)

    watch.receive(try #require(off))
    #expect(watch.status == nil)
    #expect(watch.preview == nil)

    // A request after opt-out is answered with `disabled`, which also clears.
    watch.receive(
      .status(
        CompanionStatus(sessionNickname: nil, state: .idle, capturedAt: t0),
        publisherID: publisherID
      )
    )
    let r22 = watch.beginRequest(.refresh, now: t0.addingTimeInterval(3))
    let again = try #require(r22)
    let reply = bridge.reply(to: again)
    guard case .disabled = reply else {
      Issue.record("expected disabled")
      return
    }
    let r23 = watch.receive(reply)
    #expect(r23)
    #expect(watch.status == nil)
  }

  @Test
  func `re-enabling sharing accepts the active session's observation`() throws {
    var bridge = PhoneCompanionBridge(
      settings: CompanionSettings(sharingEnabled: true, previewEnabled: false),
      now: t0
    )
    let active = observation(.active, at: t0.addingTimeInterval(5))
    _ = bridge.observe(active)
    let off = bridge.update(
      CompanionSettings(sharingEnabled: false, previewEnabled: false),
      now: t0.addingTimeInterval(60)
    )
    #expect(
      off
        == .cleared(
          at: t0.addingTimeInterval(60),
          revision: 2,
          publisherID: bridge.publisherID
        )
    )
    let on = bridge.update(
      CompanionSettings(sharingEnabled: true, previewEnabled: false),
      now: t0.addingTimeInterval(120)
    )
    #expect(bridge.status?.state == .noSession)

    // The session's state has not changed since t0+5; its re-sent
    // observation is still the newest real one and must be accepted.
    let observed = bridge.observe(active)
    let context = try #require(observed)
    #expect(bridge.status?.state == .active)
    #expect(bridge.status?.capturedAt == t0.addingTimeInterval(5))

    // The watch, cleared and then re-enabled, ends up showing it too.
    var watch = WatchCompanionStore()
    watch.receive(try #require(off))
    watch.receive(try #require(on))
    watch.receive(context)
    #expect(watch.status?.state == .active)
  }

  @Test
  func `watch clears preview when inactive`() throws {
    var bridge = PhoneCompanionBridge(
      settings: CompanionSettings(sharingEnabled: true, previewEnabled: true),
      isForeground: true,
      now: t0
    )
    _ = bridge.observe(observation(.active, at: t0))
    bridge.observePreview(lines: ["visible"], capturedAt: t0)
    var watch = WatchCompanionStore()
    watch.setActive(true)
    watch.setReachable(true)
    watch.receive(bridge.applicationContext)
    let r24 = watch.beginRequest(.preview, now: t0)
    let request = try #require(r24)
    watch.receive(bridge.reply(to: request))
    #expect(watch.presentation(now: t0).preview != nil)

    watch.setActive(false)
    #expect(watch.preview == nil)
    #expect(watch.presentation(now: t0).preview == nil)

    // A preview reply that lands while inactive is not retained.
    watch.setActive(true)
    let r25 = watch.beginRequest(.preview, now: t0)
    let next = try #require(r25)
    let late = bridge.reply(to: next)
    watch.setActive(false)
    watch.setActive(true)
    let r26 = watch.receive(late)
    #expect(!r26)  // the pending preview was abandoned
    #expect(watch.preview == nil)

    // Without the phone's opt-in a preview is never requested.
    var plain = WatchCompanionStore()
    plain.setActive(true)
    plain.setReachable(true)
    plain.receive(
      .status(
        CompanionStatus(sessionNickname: nil, state: .active, capturedAt: t0),
        publisherID: publisherID
      )
    )
    let r27 = plain.beginRequest(.preview, now: t0)
    #expect(r27?.kind == .refresh)
  }

  @Test
  func `malformed requests get no reply`() {
    let bridge = PhoneCompanionBridge(now: t0)
    #expect(bridge.reply(toMessageData: Data("nonsense".utf8)) == nil)
    #expect(
      bridge.reply(
        toMessageData: Data(#"{"v":9,"type":"refresh","id":"a"}"#.utf8)
      ) == nil
    )
    var store = WatchCompanionStore()
    let r28 = store.receive(replyData: Data())
    #expect(!r28)
  }
}
