import CompanionModel
import Foundation
import Testing

struct CompanionOrderingTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func observation() -> PhoneCompanionBridge.Observation {
    .init(
      sessionToken: UUID(),
      nickname: "cached",
      state: .active,
      observedAt: now
    )
  }

  @Test
  func delayedStatusCannotRestoreAnOptedOutCache() throws {
    var phone = PhoneCompanionBridge(now: now)
    let oldValue = phone.observe(observation())
    let old = try #require(oldValue)
    let clearValue = phone.update(.init(sharingEnabled: false), now: now)
    let clear = try #require(clearValue)
    var watch = WatchCompanionStore()
    watch.receive(old)
    watch.receive(clear)
    watch.receive(old)
    #expect(watch.status == nil)
  }

  @Test
  func delayedClearCannotEraseReenabledUnchangedObservation() throws {
    var phone = PhoneCompanionBridge(now: now)
    let unchanged = observation()
    _ = phone.observe(unchanged)
    let clearValue = phone.update(
      .init(sharingEnabled: false),
      now: now.addingTimeInterval(60)
    )
    let clear = try #require(clearValue)
    _ = phone.update(.default, now: now.addingTimeInterval(120))
    let reenabledValue = phone.observe(unchanged)
    let reenabled = try #require(reenabledValue)
    var watch = WatchCompanionStore()
    watch.receive(clear)
    watch.receive(reenabled)
    watch.receive(clear)
    #expect(watch.status?.state == .active)
    #expect(watch.status?.capturedAt == now)
  }

  @Test
  func delayedCorrelatedDisabledReplyCannotEraseNewPublication() throws {
    var phone = PhoneCompanionBridge(now: now)
    _ = phone.update(.init(sharingEnabled: false), now: now)
    var watch = WatchCompanionStore()
    watch.setActive(true)
    watch.setReachable(true)
    let requestValue = watch.beginRequest(.refresh, now: now)
    let request = try #require(requestValue)
    let disabled = phone.reply(to: request)
    _ = phone.update(.default, now: now.addingTimeInterval(120))
    let newerValue = phone.observe(observation())
    let newer = try #require(newerValue)
    watch.receive(newer)
    let received = watch.receive(disabled)
    #expect(received)
    #expect(!watch.gate.isPending)
    #expect(watch.status?.state == .active)
  }
}
