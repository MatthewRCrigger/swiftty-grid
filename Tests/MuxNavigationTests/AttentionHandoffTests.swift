import Foundation
import MuxNavigation
import Testing

struct AttentionHandoffTests {
  @Test(
    arguments: AttentionDestination.Intent.allCases.flatMap { intent in
      [false, true].map { (intent: intent, tab: $0) }
    },
    [AttentionHandoffRequest.Intent.review, .reveal]
  )
  func continuationPreservesEffectiveDestination(
    shape: (intent: AttentionDestination.Intent, tab: Bool),
    requestIntent: AttentionHandoffRequest.Intent
  ) throws {
    let original = sampleDestination(tab: shape.tab, intent: shape.intent)
    let request = try #require(
      AttentionHandoffRequest(
        locator: AttentionLocator.encode(original),
        intent: requestIntent
      )
    )
    var expected = original
    if requestIntent == .reveal { expected.intent = .reveal }
    #expect(try request.destination() == expected)
    let payload = request.userInfo
    #expect(payload.keys.sorted() == [AttentionHandoffRequest.locatorKey])
    #expect(
      try #require(payload[AttentionHandoffRequest.locatorKey]).utf8.count
        <= AttentionLocator.maxLength
    )
    let continued = try #require(AttentionHandoffRequest(userInfo: payload))
    #expect(try continued.destination() == expected)
    #expect(!request.grantsWriterLease && !continued.grantsWriterLease)
    #expect(!request.allowsInput && !continued.allowsInput)
  }

  @Test(arguments: [AttentionHandoffRequest.Intent.review, .reveal])
  func continuationUsesCurrentRequestFields(
    intent: AttentionHandoffRequest.Intent
  ) throws {
    var request = try #require(
      AttentionHandoffRequest(
        locator: AttentionLocator.encode(sampleDestination())
      )
    )
    var replacement = sampleDestination(tab: false, path: "", intent: .result)
    request.locator = AttentionLocator.encode(replacement)
    request.intent = intent
    if intent == .reveal { replacement.intent = .reveal }
    let continued = try #require(
      AttentionHandoffRequest(userInfo: request.userInfo)
    )
    #expect(try continued.destination() == replacement)
  }

  @Test(arguments: [
    "", "!", String(repeating: "a", count: AttentionLocator.maxLength + 1),
  ])
  func invalidMutatedLocatorCannotContinue(_ locator: String) throws {
    var request = try #require(
      AttentionHandoffRequest(
        locator: AttentionLocator.encode(sampleDestination()),
        intent: .reveal
      )
    )
    request.locator = locator
    #expect(AttentionHandoffRequest(userInfo: request.userInfo) == nil)
  }

  @Test
  func malformedActivityPayloadsAreRejected() {
    let locator = AttentionLocator.encode(sampleDestination())
    let invalid: [[AnyHashable: Any]?] = [
      nil, [:], ["ref": "!"], ["ref": 42], ["ref": NSNull()],
      ["locator": locator], [0: locator], ["ref": locator, "intent": "reveal"],
      ["ref": locator, "cmd": "input"], ["ref": locator, "lease": true],
    ]
    for payload in invalid {
      #expect(AttentionHandoffRequest(userInfo: payload) == nil)
    }
  }
}
