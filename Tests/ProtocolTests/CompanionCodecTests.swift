import CompanionModel
import Foundation
import Testing

struct CompanionCodecTests {
  let t0 = Date(timeIntervalSince1970: 1_800_000_000)

  func status(_ state: CompanionConnectionState = .active) -> CompanionStatus {
    CompanionStatus(
      sessionNickname: "work mac",
      state: state,
      capturedAt: t0,
      lastScreenAt: t0.addingTimeInterval(-3),
      pendingInputCount: 2,
      previewAvailable: true
    )
  }

  @Test
  func `requests replies and contexts round trip`() throws {
    let request = CompanionRequest(kind: .preview)
    #expect(try CompanionCodec.decodeRequest(CompanionCodec.encode(request)) == request)

    let preview = CompanionPreview(lines: ["$ ls", "a  b  c"], capturedAt: t0)
    let replies: [CompanionReply] = [
      .status(request.id, status(), previewUnavailable: nil),
      .status(request.id, status(.reconnecting), previewUnavailable: .phoneNotForeground),
      .preview(request.id, status(), preview),
      .disabled(request.id, clearedAt: t0),
    ]
    for reply in replies {
      #expect(try CompanionCodec.decodeReply(CompanionCodec.encode(reply)) == reply)
    }
    for context in [CompanionApplicationContext.status(status()), .cleared(at: t0)] {
      let dictionary = try context.dictionary()
      #expect(try CompanionApplicationContext(dictionary: dictionary) == context)
    }
  }

  @Test
  func `payloads over 16 KiB are rejected before parsing`() throws {
    var data = Data(#"{"v":1,"type":"refresh","id":"a","pad":""#.utf8)
    data.append(Data(repeating: UInt8(ascii: "x"), count: CompanionLimits.maxPayloadBytes))
    data.append(Data(#""}"#.utf8))
    #expect(throws: CompanionCodecError.tooLarge(data.count)) {
      try CompanionCodec.decodeRequest(data)
    }
    // The largest preview the model can build still encodes within bounds.
    let wide = String(repeating: "\u{1F600}", count: 200)
    let preview = CompanionPreview(
      lines: Array(repeating: wide, count: 100),
      capturedAt: t0
    )
    #expect(preview.lines.count <= CompanionLimits.maxPreviewLines)
    let reply = CompanionReply.preview(.random(), status(), preview)
    #expect(try CompanionCodec.encode(reply).count <= CompanionLimits.maxPayloadBytes)
  }

  @Test
  func `unknown versions and unexpected fields are rejected`() {
    let future = Data(#"{"v":2,"type":"refresh","id":"abc"}"#.utf8)
    #expect(throws: CompanionCodecError.unsupportedVersion(2)) {
      try CompanionCodec.decodeRequest(future)
    }
    let extra = Data(#"{"v":1,"type":"refresh","id":"abc","command":"ls"}"#.utf8)
    #expect(throws: CompanionCodecError.self) { try CompanionCodec.decodeRequest(extra) }
    // A reply type is not a request.
    let wrongKind = Data(#"{"v":1,"type":"disabled","id":"abc","clearedAt":1800000000}"#.utf8)
    #expect(throws: CompanionCodecError.self) { try CompanionCodec.decodeRequest(wrongKind) }
  }

  @Test
  func `preview bounds are enforced on decode`() throws {
    let tooMany = (0...CompanionLimits.maxPreviewLines).map { "\"\($0)\"" }
      .joined(separator: ",")
    let json = #"{"v":1,"type":"preview","id":"r","status":\#(try statusJSON()),"preview":{"lines":[\#(tooMany)],"capturedAt":1800000000}}"#
    #expect(throws: CompanionCodecError.self) {
      try CompanionCodec.decodeReply(Data(json.utf8))
    }
    let wideLine = String(repeating: "w", count: CompanionLimits.maxPreviewColumns + 1)
    let wide = #"{"v":1,"type":"preview","id":"r","status":\#(try statusJSON()),"preview":{"lines":["\#(wideLine)"],"capturedAt":1800000000}}"#
    #expect(throws: CompanionCodecError.self) {
      try CompanionCodec.decodeReply(Data(wide.utf8))
    }
  }

  @Test
  func `control characters are stripped from text`() throws {
    let raw = "\u{1B}[31mred\u{07}\u{9B}2J\u{202E}evil\u{2028}x\ty"
    #expect(CompanionText.stripControls(raw) == "[31mred2Jevilx y")

    let built = CompanionPreview(lines: [raw], capturedAt: t0)
    #expect(built.lines == ["[31mred2Jevilx y"])
    let named = CompanionStatus(sessionNickname: "a\u{0}b\u{1B}", state: .idle, capturedAt: t0)
    #expect(named.sessionNickname == "ab")

    // Escaped control characters in received JSON are stripped too.
    let json = #"{"v":1,"type":"preview","id":"r","status":\#(try statusJSON()),"preview":{"lines":["\u001b]52;c;aGk=\u0007ok"],"capturedAt":1800000000}}"#
    guard case .preview(_, _, let preview) = try CompanionCodec.decodeReply(Data(json.utf8))
    else {
      Issue.record("expected preview")
      return
    }
    #expect(preview.lines == ["]52;c;aGk=ok"])
    #expect(!preview.lines.joined().unicodeScalars.contains(where: CompanionText.isDisallowed))
  }

  @Test
  func `preview text is not representable in application context`() throws {
    // A context that tries to carry a preview is rejected outright.
    let smuggled = #"{"v":1,"type":"preview","status":\#(try statusJSON()),"preview":{"lines":["secret"],"capturedAt":1800000000}}"#
    #expect(throws: CompanionCodecError.self) {
      try CompanionCodec.decodeContext(Data(smuggled.utf8))
    }
    let extraField = #"{"v":1,"type":"status","status":\#(try statusJSON()),"preview":{"lines":["secret"],"capturedAt":1800000000}}"#
    #expect(throws: CompanionCodecError.self) {
      try CompanionCodec.decodeContext(Data(extraField.utf8))
    }
    let statusWithText =
      #"{"v":1,"type":"status","status":{"state":"active","capturedAt":1800000000"#
      + #","pendingInput":0,"previewAvailable":true,"lines":["secret"]}}"#
    #expect(throws: CompanionCodecError.self) {
      try CompanionCodec.decodeContext(Data(statusWithText.utf8))
    }
    // Only the single context key is accepted in the dictionary.
    var dictionary: [String: Any] = try CompanionApplicationContext.status(status()).dictionary()
    dictionary["preview"] = Data("secret".utf8)
    #expect(throws: CompanionCodecError.malformed) {
      try CompanionApplicationContext(dictionary: dictionary)
    }
    // What the context carries never includes terminal text fields.
    let encoded = try CompanionCodec.encode(CompanionApplicationContext.status(status()))
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(Set(object.keys) == ["v", "type", "status"])
    let fields = try #require(object["status"] as? [String: Any])
    #expect(
      Set(fields.keys).isSubset(of: [
        "nickname", "state", "capturedAt", "lastScreenAt", "pendingInput", "previewAvailable",
      ])
    )
  }

  @Test
  func `malformed and random payloads never crash the decoders`() {
    var generator = CompanionFuzzRandom(seed: 0xC0FFEE)
    let valid = (try? CompanionCodec.encode(
      CompanionReply.preview(
        .random(), status(), CompanionPreview(lines: ["hello", "world"], capturedAt: t0)
      )
    )) ?? Data()
    let fragments = [
      "{", "}", "[", "]", "\"v\":1", "\"type\":", "\"status\"", "\"preview\"", ",", ":",
      "null", "1e999", "-1", "\"\\u0000\"", "\"lines\":[", "true", "\"capturedAt\":",
      "9223372036854775808", "\"id\":\"x\"",
    ]
    for round in 0..<3000 {
      var data: Data
      switch round % 3 {
      case 0:
        data = Data((0..<Int(generator.next() % 512)).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
      case 1:
        data = valid
        for _ in 0..<(1 + Int(generator.next() % 8)) where !data.isEmpty {
          let index = Int(generator.next() % UInt64(data.count))
          data[index] = UInt8(truncatingIfNeeded: generator.next())
        }
      default:
        let count = Int(generator.next() % 24)
        data = Data(
          (0..<count).map { _ in fragments[Int(generator.next() % UInt64(fragments.count))] }
            .joined().utf8
        )
      }
      _ = try? CompanionCodec.decodeRequest(data)
      _ = try? CompanionCodec.decodeReply(data)
      _ = try? CompanionCodec.decodeContext(data)
      if let reply = try? CompanionCodec.decodeReply(data),
        case .preview(_, _, let preview) = reply
      {
        #expect(preview.lines.count <= CompanionLimits.maxPreviewLines)
        #expect(!preview.lines.joined().unicodeScalars.contains(where: CompanionText.isDisallowed))
      }
    }
    // Deeply nested input is rejected without overflowing the stack.
    let nested = Data((String(repeating: "[", count: 10_000)).utf8)
    #expect(throws: CompanionCodecError.self) { try CompanionCodec.decodeReply(nested) }
  }

  @Test
  func `timestamps must be finite and plausible`() {
    let bad = #"{"v":1,"type":"cleared","clearedAt":1}"#
    #expect(throws: CompanionCodecError.self) { try CompanionCodec.decodeContext(Data(bad.utf8)) }
    let later =
      #"{"v":1,"type":"status","status":{"state":"active","capturedAt":1800000000,"lastScreenAt":1800000100"#
      + #","pendingInput":0,"previewAvailable":false}}"#
    #expect(throws: CompanionCodecError.self) {
      try CompanionCodec.decodeContext(Data(later.utf8))
    }
  }

  private func statusJSON() throws -> String {
    String(decoding: try JSONEncoder().encode(status()), as: UTF8.self)
  }
}

/// Deterministic generator for reproducible fuzz rounds.
private struct CompanionFuzzRandom {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
