import CompanionModel
import Foundation
import Testing

struct CompanionPublisherRecoveryTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let original = UUID()
  let replacement = UUID()

  func status(_ name: String) -> CompanionStatus {
    .init(
      sessionNickname: name,
      state: .active,
      capturedAt: now,
      previewAvailable: true
    )
  }

  func request(_ store: inout WatchCompanionStore) throws -> CompanionRequest {
    let value = store.beginRequest(.preview, now: now)
    return try #require(value)
  }

  func established() -> WatchCompanionStore {
    var watch = WatchCompanionStore()
    watch.setActive(true)
    watch.setReachable(true)
    watch.receive(
      .status(status("original"), revision: 102, publisherID: original)
    )
    return watch
  }

  @Test(arguments: [false, true])
  func resetRequiresFreshConfirmationAndAcceptsStatusOrOptOut(
    disabled: Bool
  ) throws {
    var watch = established()
    let oldRequest = try request(&watch)
    let incoming: CompanionApplicationContext =
      disabled
      ? .cleared(at: now, revision: 1, publisherID: replacement)
      : .status(status("replacement"), revision: 1, publisherID: replacement)
    let admitted = watch.receive(incoming)
    #expect(!admitted)
    #expect(watch.status?.sessionNickname == "original")
    #expect(watch.needsPublisherConfirmation)
    #expect(watch.freshness(now: now) == .stale)
    #expect(watch.gate.pending == nil)
    let fresh = try request(&watch)
    #expect(fresh.id != oldRequest.id)
    #expect(fresh.kind == .refresh)
    let obsolete = watch.receive(
      .disabled(
        oldRequest.id,
        clearedAt: now,
        revision: UInt64.max,
        publisherID: original
      )
    )
    #expect(!obsolete)
    #expect(watch.gate.pending?.request.id == fresh.id)
    let reply: CompanionReply =
      disabled
      ? .disabled(
        fresh.id,
        clearedAt: now,
        revision: 2,
        publisherID: replacement
      )
      : .status(
        fresh.id,
        status("replacement"),
        previewUnavailable: nil,
        revision: 2,
        publisherID: replacement
      )
    let accepted = watch.receive(reply)
    #expect(accepted)
    #expect(!watch.needsPublisherConfirmation)
    #expect(watch.publisherID == replacement)
    #expect(watch.lastPublicationRevision == 2)
    #expect(watch.status?.sessionNickname == (disabled ? nil : "replacement"))
    #expect(watch.preview == nil)
    let retired = watch.receive(
      .status(
        status("late original"),
        revision: UInt64.max,
        publisherID: original
      )
    )
    #expect(!retired)
    #expect(!watch.needsPublisherConfirmation)
    #expect(watch.lastPublicationRevision == 2)
    #expect(watch.status?.sessionNickname == (disabled ? nil : "replacement"))
  }

  @Test(arguments: [false, true])
  func firstActivationAcceptsContextOrOwnImmediateReply(
    contextFirst: Bool
  ) throws {
    var watch = WatchCompanionStore()
    watch.setActive(true)
    watch.setReachable(true)
    let fresh = try request(&watch)
    if contextFirst {
      watch.receive(
        .status(status("original"), revision: 1, publisherID: original)
      )
    }
    let accepted = watch.receive(
      .status(
        fresh.id,
        status("original"),
        previewUnavailable: nil,
        revision: 2,
        publisherID: original
      )
    )
    #expect(accepted)
    #expect(watch.publisherID == original)
    #expect(watch.status?.sessionNickname == "original")
    #expect(!watch.needsPublisherConfirmation)
    #expect(watch.gate.pending == nil)
  }

  @Test(arguments: [false, true])
  func foreignNormalReplyCannotBypassFreshRequestConfirmation(
    withPreview: Bool
  ) throws {
    var watch = established()
    let ordinary = try request(&watch)
    let reply: CompanionReply =
      withPreview
      ? .preview(
        ordinary.id,
        status("replacement"),
        .init(lines: ["owned replacement"], capturedAt: now),
        revision: 1,
        publisherID: replacement
      )
      : .status(
        ordinary.id,
        status("replacement"),
        previewUnavailable: nil,
        revision: 1,
        publisherID: replacement
      )
    let delivered = watch.receive(reply)
    #expect(delivered)
    #expect(watch.publisherID == original)
    #expect(watch.needsPublisherConfirmation)
    #expect(watch.preview == nil)
    let fresh = try request(&watch)
    #expect(fresh.id != ordinary.id && fresh.kind == .refresh)
    let oldCallback = watch.receive(
      .status(
        ordinary.id,
        status("old callback"),
        previewUnavailable: nil,
        revision: UInt64.max,
        publisherID: original
      )
    )
    #expect(!oldCallback)
    let accepted = watch.receive(
      .status(
        fresh.id,
        status("replacement"),
        previewUnavailable: nil,
        revision: 2,
        publisherID: replacement
      )
    )
    #expect(accepted)
    #expect(watch.status?.sessionNickname == "replacement")
  }

  @Test
  func newerCandidateAbandonsEarlierConfirmationRequest() throws {
    var watch = established()
    watch.receive(
      .status(status("replacement"), revision: 1, publisherID: replacement)
    )
    let first = try request(&watch)
    let newest = UUID()
    watch.receive(.cleared(at: now, revision: 1, publisherID: newest))
    let second = try request(&watch)
    #expect(second.id != first.id)
    let stale = watch.receive(
      .status(
        first.id,
        status("stale confirmation"),
        previewUnavailable: nil,
        revision: 2,
        publisherID: replacement
      )
    )
    #expect(!stale)
    let accepted = watch.receive(
      .disabled(second.id, clearedAt: now, revision: 2, publisherID: newest)
    )
    #expect(accepted)
    #expect(watch.publisherID == newest)
    #expect(watch.status == nil)
  }

  @Test
  func repeatedCandidateDoesNotCancelItsPendingConfirmation() throws {
    var watch = established()
    watch.receive(
      .status(status("replacement"), revision: 1, publisherID: replacement)
    )
    let fresh = try request(&watch)
    watch.receive(.cleared(at: now, revision: 3, publisherID: replacement))
    #expect(watch.gate.pending?.request.id == fresh.id)
    #expect(watch.confirmationPublisherID == replacement)
  }

  @Test
  func unreachableOrInactiveConfirmationWaitsForAvailability() throws {
    var watch = established()
    watch.setReachable(false)
    watch.receive(
      .status(status("replacement"), revision: 1, publisherID: replacement)
    )
    let unreachable = watch.beginRequest(.refresh, now: now)
    #expect(unreachable == nil)
    watch.setReachable(true)
    watch.setActive(false)
    let inactive = watch.beginRequest(.refresh, now: now)
    #expect(inactive == nil)
    watch.setActive(true)
    let fresh = try request(&watch)
    let accepted = watch.receive(
      .status(
        fresh.id,
        status("replacement"),
        previewUnavailable: nil,
        revision: 2,
        publisherID: replacement
      )
    )
    #expect(accepted)
    #expect(watch.publisherID == replacement)
  }

  @Test
  func failedOrExpiredConfirmationCanRetryWithoutAnImmediateLoop() throws {
    var watch = established()
    watch.receive(
      .status(status("replacement"), revision: 1, publisherID: replacement)
    )
    let fresh = try request(&watch)
    let malformed = watch.receive(replyData: Data("{}".utf8))
    #expect(!malformed)
    #expect(watch.gate.pending?.request.id == fresh.id)
    watch.requestFailed(fresh.id, now: now)
    #expect(watch.needsPublisherConfirmation)
    let early = watch.beginRequest(.refresh, now: now.addingTimeInterval(1))
    #expect(early == nil)
    let retryValue = watch.beginRequest(
      .refresh,
      now: now.addingTimeInterval(15)
    )
    let retry = try #require(retryValue)
    watch.tick(now: now.addingTimeInterval(30))
    #expect(watch.gate.pending == nil)
    let laterValue = watch.beginRequest(
      .refresh,
      now: now.addingTimeInterval(45)
    )
    let later = try #require(laterValue)
    let expired = watch.receive(
      .disabled(retry.id, clearedAt: now, revision: 3, publisherID: replacement)
    )
    #expect(!expired)
    let accepted = watch.receive(
      .disabled(later.id, clearedAt: now, revision: 4, publisherID: replacement)
    )
    #expect(accepted)
    #expect(!watch.needsPublisherConfirmation)
    #expect(watch.status == nil)
  }

  @Test
  func olderRetiredSenderNeverReentersThroughAQueuedContext() throws {
    var watch = established()
    for publisher in [replacement, UUID()] {
      watch.receive(
        .status(status("current"), revision: 1, publisherID: publisher)
      )
      let fresh = try request(&watch)
      let accepted = watch.receive(
        .status(
          fresh.id,
          status("current"),
          previewUnavailable: nil,
          revision: 2,
          publisherID: publisher
        )
      )
      #expect(accepted)
    }
    let current = try #require(watch.publisherID)
    let rejected = watch.receive(
      .cleared(at: now, revision: UInt64.max, publisherID: original)
    )
    #expect(!rejected)
    #expect(watch.publisherID == current)
    #expect(watch.status?.sessionNickname == "current")
    let fresh = try request(&watch)
    let confirmed = watch.receive(
      .status(
        fresh.id,
        status("current"),
        previewUnavailable: nil,
        revision: 3,
        publisherID: current
      )
    )
    #expect(confirmed)
    #expect(watch.publisherID == current)
    #expect(!watch.needsPublisherConfirmation)
  }

  @Test
  func reenabledNewPublisherKeepsOriginalCaptureTime() throws {
    var watch = established()
    watch.receive(.cleared(at: now, revision: 1, publisherID: replacement))
    let fresh = try request(&watch)
    let confirmed = watch.receive(
      .disabled(fresh.id, clearedAt: now, revision: 2, publisherID: replacement)
    )
    #expect(confirmed)
    let reenabled = watch.receive(
      .status(status("replacement"), revision: 3, publisherID: replacement)
    )
    #expect(reenabled)
    #expect(watch.status?.capturedAt == now)
    let oldClear = watch.receive(
      .cleared(at: now, revision: 2, publisherID: replacement)
    )
    #expect(!oldClear)
    #expect(watch.status?.sessionNickname == "replacement")
  }
}
