import CompanionModel
import Foundation
import MuxNavigation
import Testing

struct WatchApplicationContextTests {
  let publisherID = UUID()
  private let time = Date(timeIntervalSince1970: 1_700_000_000)

  private var status: CompanionStatus {
    CompanionStatus(
      sessionNickname: "session",
      state: .active,
      capturedAt: time
    )
  }

  private func batchData() throws -> Data {
    try AttentionSummaryBatch(
      summaries: [
        AttentionSummary(
          category: .result,
          appName: "sender\u{202E}app",
          counts: .init(),
          updatedAt: time
        )
      ],
      sentAt: time.addingTimeInterval(1)
    )
    .encoded()
  }

  @Test(arguments: [false, true])
  func statusAndOptionalAttentionDecodeAsOneValue(hasBatch: Bool) throws {
    var dictionary: [String: Any] =
      try CompanionApplicationContext.status(status, publisherID: publisherID)
      .dictionary()
    if hasBatch {
      dictionary[AttentionSummaryBatch.dictionaryKey] = try batchData()
    }
    let context = try WatchApplicationContext(dictionary: dictionary)
    #expect(context.companion == .status(status, publisherID: publisherID))
    if hasBatch {
      let batch = try #require(context.attention)
      #expect(batch.sentAt == time.addingTimeInterval(1))
      #expect(batch.summaries.count == 1)
      #expect(batch.summaries[0].appName == "sender app")
      #expect(batch.summaries[0].updatedAt == time)
    } else {
      #expect(context.attention == nil)
    }
  }

  @Test
  func clearedContextHasNoAttention() throws {
    let companion = CompanionApplicationContext.cleared(
      at: time,
      publisherID: publisherID
    )
    let context = try WatchApplicationContext(
      dictionary: companion.dictionary()
    )
    #expect(context.companion == companion)
    #expect(context.attention == nil)
  }

  @Test(arguments: [
    "empty", "extra", "missing", "malformedCompanion", "wrongCompanionType",
    "requestInsteadOfContext", "malformedBatch", "wrongBatchType",
    "mixedClearBatch",
  ])
  func malformedWholeDictionaryIsRejected(_ shape: String) throws {
    let companionKey = CompanionApplicationContext.dictionaryKey
    let attentionKey = AttentionSummaryBatch.dictionaryKey
    var dictionary: [String: Any] =
      try CompanionApplicationContext.status(status, publisherID: publisherID)
      .dictionary()
    dictionary[attentionKey] = try batchData()
    switch shape {
    case "empty": dictionary = [:]
    case "extra": dictionary["unexpected"] = true
    case "missing": dictionary.removeValue(forKey: companionKey)
    case "malformedCompanion": dictionary[companionKey] = Data("{}".utf8)
    case "wrongCompanionType": dictionary[companionKey] = NSNull()
    case "requestInsteadOfContext":
      dictionary[companionKey] = try CompanionCodec.encode(
        CompanionRequest(kind: .refresh)
      )
    case "malformedBatch": dictionary[attentionKey] = Data("{}".utf8)
    case "wrongBatchType": dictionary[attentionKey] = "invalid"
    case "mixedClearBatch":
      dictionary[companionKey] = try CompanionCodec.encode(
        CompanionApplicationContext.cleared(at: time, publisherID: publisherID)
      )
    default:
      Issue.record("Unknown fixture shape");
      return
    }
    #expect(throws: WatchApplicationContext.DecodeError.malformed) {
      try WatchApplicationContext(dictionary: dictionary)
    }
  }

  @Test(arguments: ["companion", "attention"])
  func eachComponentEnforcesItsExactEncodedByteLimit(_ component: String) throws
  {
    var dictionary: [String: Any] =
      try CompanionApplicationContext.status(status, publisherID: publisherID)
      .dictionary()
    dictionary[AttentionSummaryBatch.dictionaryKey] = try batchData()
    let key =
      component == "companion"
      ? CompanionApplicationContext.dictionaryKey
      : AttentionSummaryBatch.dictionaryKey
    let limit =
      component == "companion"
      ? CompanionLimits.maxPayloadBytes : AttentionSummaryBatch.maxEncodedBytes
    var data = try #require(dictionary[key] as? Data)
    try #require(data.count < limit)
    data.append(Data(repeating: UInt8(ascii: " "), count: limit - data.count))
    dictionary[key] = data
    #expect(
      try WatchApplicationContext(dictionary: dictionary).companion
        == .status(status, publisherID: publisherID)
    )
    data.append(UInt8(ascii: " "))
    dictionary[key] = data
    #expect(throws: WatchApplicationContext.DecodeError.malformed) {
      try WatchApplicationContext(dictionary: dictionary)
    }
  }
}
