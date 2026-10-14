import Foundation
import MuxNavigation
import SwiftMuxProtocol
import Testing

func sampleDestination(
  tab: Bool = true,
  path: String = "agent/build.1",
  intent: AttentionDestination.Intent = .review
) -> AttentionDestination {
  AttentionDestination(
    localHostProfileID: UUID(),
    serviceEpoch: ServerInstanceID(),
    workspaceID: WorkspaceID(),
    tabID: tab ? TabID() : nil,
    paneID: PaneID(),
    terminalEpoch: TerminalEpochID(),
    recordPath: path,
    recordIncarnation: 0x0102_0304_0506_0708,
    occurrenceID: OccurrenceID(),
    intent: intent
  )
}

@Suite("Attention locator")
struct LocatorTests {
  @Test
  func roundTripsEveryShape() throws {
    let longPath = (0 ..< 4).map { _ in String(repeating: "a", count: 31) }
      .joined(separator: "/")
    for intent in AttentionDestination.Intent.allCases {
      for tab in [true, false] {
        for path in ["", "x", "a.b-c_d+e/f", longPath] {
          let d = sampleDestination(tab: tab, path: path, intent: intent)
          let text = AttentionLocator.encode(d)
          #expect(text.utf8.count <= AttentionLocator.maxLength)
          #expect(try AttentionLocator.decode(text) == d)
        }
      }
    }
  }

  @Test
  func maxLengthMatchesLargestPayload() throws {
    let path = (0 ..< 4).map { _ in String(repeating: "z", count: 31) }
      .joined(separator: "/")
    #expect(path.utf8.count == 127)
    let text = AttentionLocator.encode(sampleDestination(path: path + "z"))
    #expect(text.utf8.count == AttentionLocator.maxLength)
  }

  @Test
  func recordPathGrammarMatchesOSC7501() {
    #expect(RecordPathGrammar.isValid(""))
    #expect(RecordPathGrammar.isValid("a/b/c"))
    #expect(RecordPathGrammar.isValid(String(repeating: "a", count: 32)))
    #expect(!RecordPathGrammar.isValid(String(repeating: "a", count: 33)))
    #expect(
      RecordPathGrammar.isValid(
        Array(repeating: "a", count: 8).joined(separator: "/")
      )
    )
    #expect(
      !RecordPathGrammar.isValid(
        Array(repeating: "a", count: 9).joined(separator: "/")
      )
    )
    for bad in [
      "/", "a/", "/a", "a//b", "a b", "a;b", "é", "a\u{0}", "../x%2F",
    ] { #expect(!RecordPathGrammar.isValid(bad), "\(bad)") }
  }

  @Test
  func rejectsMalformedLocators() {
    let good = AttentionLocator.encode(sampleDestination())
    func rejects(_ text: String) -> AttentionLocator.DecodeError? {
      do {
        _ = try AttentionLocator.decode(text)
        return nil
      } catch { return error }
    }
    #expect(rejects("") == .empty)
    #expect(
      rejects(String(repeating: "A", count: AttentionLocator.maxLength + 1))
        == .tooLong
    )
    #expect(rejects(good + "=") == .invalidCharacters)
    #expect(rejects(good.replacingOccurrences(of: "A", with: "+")) != nil)
    #expect(rejects(String(good.dropLast(4))) != nil)
    #expect(rejects(good + "AAAA") == .trailingBytes)
    #expect(rejects("AAAA") == .truncated)
    // Every single-character corruption is rejected or decodes to a
    // different, still-valid destination; never crashes.
    let alphabet = Array(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_%/?&"
    )
    var rng = SystemRandomNumberGenerator()
    for _ in 0 ..< 2000 {
      var chars = Array(good)
      let i = Int.random(in: 0 ..< chars.count, using: &rng)
      chars[i] = alphabet.randomElement(using: &rng)!
      if let d = try? AttentionLocator.decode(String(chars)) {
        #expect(d.isValid)
      }
    }
    // Random garbage of every length up to the cap.
    for length in 0 ... AttentionLocator.maxLength + 8 {
      let text = String(
        (0 ..< length).map { _ in alphabet.randomElement(using: &rng)! }
      )
      if let d = try? AttentionLocator.decode(text) { #expect(d.isValid) }
    }
  }

  @Test
  func rejectsHeaderFields() throws {
    let good = AttentionLocator.encode(sampleDestination())
    func patched(_ index: Int, _ value: UInt8) -> String {
      var bytes = Array(Data(base64Encoded: base64(good))!)
      bytes[index] = value
      return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
    #expect(throws: AttentionLocator.DecodeError.unsupportedVersion(2)) {
      try AttentionLocator.decode(patched(0, 2))
    }
    #expect(throws: AttentionLocator.DecodeError.unsupportedIntent(9)) {
      try AttentionLocator.decode(patched(1, 9))
    }
    #expect(throws: AttentionLocator.DecodeError.unknownFlags) {
      try AttentionLocator.decode(patched(2, 3))
    }
  }

  @Test
  func encodingIsCanonical() {
    // 125 payload bytes: the last character carries two zero pad bits,
    // so the next alphabet character spells the same bytes differently.
    let good = AttentionLocator.encode(sampleDestination(path: "a"))
    let alphabet = Array(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    let next = alphabet[alphabet.firstIndex(of: good.last!)! + 1]
    #expect(throws: AttentionLocator.DecodeError.nonCanonical) {
      try AttentionLocator.decode(String(good.dropLast()) + String(next))
    }
  }

  @Test
  func handoffCarriesOnlyTheLocator() throws {
    let d = sampleDestination()
    let locator = AttentionLocator.encode(d)
    let request = try #require(
      AttentionHandoffRequest(locator: locator, intent: .reveal)
    )
    #expect(!request.grantsWriterLease)
    #expect(!request.allowsInput)
    #expect(try request.destination().intent == .reveal)
    #expect(try request.destination().reference == d.reference)
    #expect(AttentionHandoffRequest(locator: "rm -rf /") == nil)
    #expect(AttentionHandoffRequest(userInfo: request.userInfo) != nil)
    #expect(
      AttentionHandoffRequest(userInfo: ["ref": locator, "cmd": "x"]) == nil
    )
  }

  @Test
  func summaryIsRedactedByDefault() throws {
    let item = sampleItem(for: sampleDestination(), message: "secret token abc")
    let summary = AttentionSummary(
      item: item,
      counts: InboxCounts(needsYou: 2, results: 1)
    )
    #expect(summary.message == nil)
    #expect(summary.appName == "agent")
    #expect(summary.counts.needsYou == 2)
    let redacted = AttentionSummary(
      item: item,
      counts: InboxCounts(),
      policy: .redacted
    )
    #expect(redacted.appName == nil && redacted.message == nil)
    let opted = AttentionSummary(
      item: item,
      counts: InboxCounts(),
      policy: AttentionSummaryPolicy(showsMessage: true)
    )
    #expect(opted.message == "secret token abc")
    let encoded = String(
      decoding: try JSONEncoder().encode(summary),
      as: UTF8.self
    )
    #expect(!encoded.contains("secret"))
    #expect(!encoded.contains("Build"))
  }
}

func base64(_ url: String) -> String {
  var s = url.replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  while s.count % 4 != 0 { s += "=" }
  return s
}

func sampleItem(
  for d: AttentionDestination,
  occurrence: OccurrenceID? = nil,
  resolution: AttentionResolution = .open,
  message: String? = nil
) -> AttentionItem {
  let source = d.source
  return AttentionItem(
    occurrence: occurrence ?? d.occurrenceID,
    source: source,
    workspace: d.workspaceID,
    tab: d.tabID,
    category: .needsYou,
    resolution: resolution,
    status: AttentionStatus(
      source: source,
      state: .blocked,
      kind: .permission,
      app: "agent",
      title: "Build",
      message: message,
      updatedAt: Date(timeIntervalSince1970: 1_000)
    ),
    createdAt: Date(timeIntervalSince1970: 1_000),
    updatedAt: Date(timeIntervalSince1970: 1_000),
    revision: 1
  )
}

@Suite("Watch summary batches")
struct SummaryBatchTests {
  @Test
  func batchesAreBoundedAndReRedacted() throws {
    let long = String(repeating: "x", count: 500)
    var summaries = (0 ..< 30)
      .map { i in
        AttentionSummary(
          category: .needsYou,
          appName: "app\u{202E}\(i)",
          counts: InboxCounts(needsYou: 1),
          updatedAt: .now,
          message: long,
          locator: "not-a-locator"
        )
      }
    let batch = AttentionSummaryBatch(summaries: summaries)
    #expect(batch.summaries.count == AttentionSummaryBatch.maxSummaries)
    let decoded = try AttentionSummaryBatch.decode(try batch.encoded())
    for summary in decoded.summaries {
      #expect(summary.appName?.unicodeScalars.contains("\u{202E}") == false)
      #expect(
        (summary.message?.count ?? 0) <= AttentionSummary.maxMessageLength
      )
      // An invalid locator is dropped rather than handed off.
      #expect(summary.locator == nil)
    }
    summaries = []
    let oversized = Data(
      repeating: 0x20,
      count: AttentionSummaryBatch.maxEncodedBytes + 1
    )
    #expect(throws: AttentionSummaryBatch.CodecError.tooLarge) {
      try AttentionSummaryBatch.decode(oversized)
    }
  }
}
