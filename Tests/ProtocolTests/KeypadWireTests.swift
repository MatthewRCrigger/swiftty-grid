import Foundation
@testable import ScreenProtocol
import SessionCore
import Testing

/// RST/1 keypad key names and the `Attached` feature list that gates them.
struct KeypadWireTests {
  @Test
  func `keypad key names round-trip and unknown ones are rejected`() {
    for key in SemanticKeypadKey.allCases {
      let name = SemanticKeyName.keypad(key)
      #expect(name.wireName == "kp:" + key.rawValue)
      #expect(SemanticKeyName(wireName: name.wireName) == name)
    }
    #expect(SemanticKeyName(wireName: "kp:") == nil)
    #expect(SemanticKeyName(wireName: "kp:eleven") == nil)
    #expect(SemanticKeyName(wireName: "kp:One") == nil)
  }

  @Test
  func `keypad input round-trips through a control record`() throws {
    let message = ControlMessage.input(
      .init(
        attachmentEpoch: 1,
        sequence: 2,
        operation: .key(SemanticKey(.keypad(.one), modifiers: .control))
      )
    )
    let record = try ControlRecord.encode(message)
    #expect(try ControlRecord.decodeBody(record.dropFirst(4)) == message)
  }

  private func attached(_ features: RSTFeatures) -> ControlMessage {
    .attached(
      .init(
        attachmentEpoch: 3,
        writerID: .random(),
        lastFullyAppliedInputSequence: 0,
        resizeRevision: 1,
        features: features
      )
    )
  }

  @Test
  func `attached carries features and omits an empty list`() throws {
    let with = attached(.keypadKeys)
    let record = try ControlRecord.encode(with)
    #expect(String(decoding: record.dropFirst(4), as: UTF8.self).contains(#""features":["keypadKeys"]"#))
    #expect(try ControlRecord.decodeBody(record.dropFirst(4)) == with)
    let without = try ControlRecord.encode(attached([]))
    #expect(!String(decoding: without.dropFirst(4), as: UTF8.self).contains("features"))
  }

  @Test
  func `older and newer feature lists decode safely`() throws {
    let base = try ControlRecord.encode(attached([]))
    var json = try #require(
      try JSONSerialization.jsonObject(with: Data(base.dropFirst(4)))
        as? [String: Any]
    )
    json["features"] = ["keypadKeys", "somethingNewer"]
    let body = try JSONSerialization.data(withJSONObject: json)
    guard case let .attached(decoded) = try ControlRecord.decodeBody(Array(body))
    else {
      Issue.record("not attached")
      return
    }
    #expect(decoded.features == .keypadKeys)
    guard case let .attached(old) = try ControlRecord.decodeBody(base.dropFirst(4))
    else {
      Issue.record("not attached")
      return
    }
    #expect(old.features == [])
  }
}
