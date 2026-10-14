import CompanionModel
import Dispatch
import Foundation
import MuxNavigation
import Synchronization
import Testing

struct PhoneWatchPublicationTests {
  let now = Date(timeIntervalSince1970: 1_800_000_000)

  func summary(_ name: String) -> AttentionSummary {
    .init(category: .result, appName: name, counts: .init(), updatedAt: now)
  }

  func snapshot(
    _ owner: PhoneWatchPublication
  ) throws -> WatchApplicationContext {
    let result = Mutex<WatchApplicationContext?>(nil)
    let submitted = owner.publish { dictionary in
      guard let decoded = try? WatchApplicationContext(dictionary: dictionary)
      else { return false }
      result.withLock { $0 = decoded }
      return true
    }
    #expect(submitted)
    return try #require(result.withLock { $0 })
  }

  @Test
  func attentionOnlyUpdatesHaveDistinctWholeContextRevisions() throws {
    let owner = PhoneWatchPublication(
      bridge: .init(now: now),
      saveIdentity: { _ in true }
    )
    owner.setAttention([summary("first")])
    let first = try snapshot(owner)
    owner.setAttention([summary("second")])
    let second = try snapshot(owner)
    #expect(first.companion.revision < second.companion.revision)
    guard case .status(let old, _, _) = first.companion,
      case .status(let new, _, _) = second.companion
    else {
      Issue.record("expected status")
      return
    }
    #expect(old.capturedAt == new.capturedAt)
    #expect(second.attention?.summaries.first?.appName == "second")
    var watch = WatchCompanionStore()
    let accepted = watch.receive(second.companion)
    let rejected = watch.receive(first.companion)
    #expect(accepted && !rejected)
    let duplicate = watch.receive(second.companion)
    #expect(!duplicate)
  }

  @Test
  func delayedPublishReadsLatestOptOutAndDropsAttention() throws {
    let owner = PhoneWatchPublication(
      bridge: .init(now: now),
      saveIdentity: { _ in true }
    )
    owner.setAttention([summary("cached")])
    _ = owner.withBridge { $0.applicationContext }  // A caller's old snapshot.
    _ = owner.withBridge { $0.update(.init(sharingEnabled: false), now: now) }
    let latest = try snapshot(owner)
    guard case .cleared = latest.companion else {
      Issue.record("stale status was submitted")
      return
    }
    #expect(latest.attention == nil)
    let cached = owner.setAttention([summary("off")])
    #expect(!cached)
  }

  @Test
  func transportSubmissionAndOptOutAreSerialized() throws {
    let owner = PhoneWatchPublication(
      bridge: .init(now: now),
      saveIdentity: { _ in true }
    )
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let changing = DispatchSemaphore(value: 0)
    let jobs = DispatchGroup()
    let events = Mutex<[CompanionApplicationContext]>([])
    DispatchQueue.global()
      .async(group: jobs) {
        owner.publish { dictionary in
          entered.signal()
          guard release.wait(timeout: .now() + 5) == .success,
            let context = try? WatchApplicationContext(dictionary: dictionary)
          else { return false }
          events.withLock { $0.append(context.companion) }
          return true
        }
      }
    defer { release.signal() }
    try #require(entered.wait(timeout: .now() + 5) == .success)
    DispatchQueue.global()
      .async(group: jobs) {
        changing.signal()
        _ = owner.withBridge {
          $0.update(.init(sharingEnabled: false), now: now)
        }
        owner.publish { dictionary in
          guard
            let context = try? WatchApplicationContext(dictionary: dictionary)
          else { return false }
          events.withLock { $0.append(context.companion) }
          return true
        }
      }
    try #require(changing.wait(timeout: .now() + 5) == .success)
    release.signal()
    try #require(jobs.wait(timeout: .now() + 5) == .success)
    let delivered = events.withLock { $0 }
    try #require(delivered.count == 2)
    guard case .status = delivered[0], case .cleared = delivered[1] else {
      Issue.record("submission escaped mutation ordering")
      return
    }
    #expect(delivered[0].revision < delivered[1].revision)
  }

  @Test
  func persistedSequenceSurvivesRestartAndClockRollback() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = CompanionPublicationSequenceFile(
      url: directory.appending(path: "sequence")
    )
    #expect(try file.load().revision == 0)
    let owner = PhoneWatchPublication(
      bridge: .init(now: now),
      saveIdentity: { (try? file.save($0)) != nil }
    )
    let first = try snapshot(owner)
    #expect(try file.load().revision == first.companion.revision)
    let restarted = PhoneWatchPublication(
      bridge: .init(
        now: now.addingTimeInterval(-120),
        publicationRevision: try file.load().revision,
        publisherID: try file.load().publisherID
      ),
      saveIdentity: { (try? file.save($0)) != nil }
    )
    let second = try snapshot(restarted)
    #expect(second.companion.revision > first.companion.revision)
    #expect(second.companion.publisherID == first.companion.publisherID)
    var watch = WatchCompanionStore()
    watch.receive(first.companion)
    let accepted = watch.receive(second.companion)
    #expect(accepted)
    #expect(watch.status?.capturedAt == now.addingTimeInterval(-120))
    #expect(try file.load().revision == second.companion.revision)
    #expect(
      try String(contentsOf: file.url, encoding: .utf8)
        == "1\n\(second.companion.publisherID.uuidString)\n\(second.companion.revision)"
    )
    #expect(
      try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true
    )
  }

  @Test(arguments: ["0", "18446744073709551615"])
  func legacyCounterUpgradeAndResetHaveDistinctIdentities(value: String) throws
  {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = CompanionPublicationSequenceFile(
      url: directory.appending(path: "sequence")
    )
    try Data(value.utf8).write(to: file.url)
    let migrated = try file.load()
    #expect(migrated.revision == UInt64(value))
    try file.save(migrated)
    #expect(try file.load() == migrated)
    try FileManager.default.removeItem(at: file.url)
    let reset = try file.load()
    #expect(reset.publisherID != migrated.publisherID)
    #expect(reset.revision == 0)
  }

  @Test(arguments: [
    "2\n00000000-0000-0000-0000-000000000000\n1", "1\ninvalid\n1",
    "1\n00000000-0000-0000-0000-000000000000\n-1",
    "1\n00000000-0000-0000-0000-000000000000\n1\n",
    "1\n00000000-0000-0000-0000-000000000000\n18446744073709551616",
  ])
  func corruptVersionedIdentityDoesNotBecomeANewPublisher(value: String) throws
  {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = CompanionPublicationSequenceFile(
      url: directory.appending(path: "sequence")
    )
    try Data(value.utf8).write(to: file.url)
    #expect(throws: CocoaError.self) { try file.load() }
  }

  @Test
  func failedPersistenceAndExhaustionRefuseBothTransports() throws {
    for (revision, canSave) in [(UInt64(0), false), (UInt64.max, true)] {
      let saves = Mutex<[UInt64]>([])
      let owner = PhoneWatchPublication(
        bridge: .init(now: now, publicationRevision: revision),
        saveIdentity: { next in
          saves.withLock { $0.append(next.revision) }
          return canSave
        }
      )
      let submitted = owner.publish { _ in
        Issue.record("unsaved publication");
        return true
      }
      #expect(!submitted)
      let reply = owner.reply(
        toMessageData: try CompanionCodec.encode(
          CompanionRequest(kind: .refresh)
        )
      )
      #expect(reply == nil)
      if revision == UInt64.max {
        #expect(saves.withLock { $0.isEmpty })
        #expect(owner.withBridge { $0.publicationRevision } == UInt64.max)
      }
    }
  }

  @Test
  func persistenceCompletesBeforeEitherTransportAndCanRecover() throws {
    let saved = Mutex<UInt64?>(nil)
    let writable = Mutex(false)
    let owner = PhoneWatchPublication(
      bridge: .init(now: now),
      saveIdentity: { revision in
        guard writable.withLock({ $0 }) else { return false }
        saved.withLock { $0 = revision.revision }
        return true
      }
    )
    let failed = owner.publish { _ in
      Issue.record("failed save submitted")
      return true
    }
    #expect(!failed)
    writable.withLock { $0 = true }
    let recovered = owner.publish { dictionary in
      guard let context = try? WatchApplicationContext(dictionary: dictionary)
      else { return false }
      #expect(saved.withLock { $0 } == context.companion.revision)
      return true
    }
    #expect(recovered)
    let requestData = try CompanionCodec.encode(
      CompanionRequest(kind: .refresh)
    )
    let reply = try #require(owner.reply(toMessageData: requestData))
    let decoded = try CompanionCodec.decodeReply(reply)
    #expect(saved.withLock { $0 } == decoded.revision)
    #expect(decoded.revision == 3)
  }

  @Test(arguments: [
    "", "-1", "1.5", " 1", "18446744073709551616",
    String(repeating: "9", count: 4096),
  ])
  func corruptSequenceDoesNotReset(value: String) throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = CompanionPublicationSequenceFile(
      url: directory.appending(path: "sequence")
    )
    try Data(value.utf8).write(to: file.url)
    #expect(throws: CocoaError.self) { try file.load() }
  }
}
