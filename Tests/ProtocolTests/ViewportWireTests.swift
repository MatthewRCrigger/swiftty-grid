import Foundation
@testable import ScreenProtocol
import SessionCore
import Testing

/// RST/1 `Viewport` requests and the `historyViewport` feature.
struct ViewportWireTests {
  @Test(arguments: [1, -1, 40, -1_000_000, 1_000_000] as [Int64])
  func `viewport requests round-trip`(_ lines: Int64) throws {
    let message = ControlMessage.viewport(epoch: 9, lines: lines)
    #expect(message.epoch == 9)
    #expect(message.typeName == "Viewport")
    let record = try ControlRecord.encode(message)
    #expect(try ControlRecord.decodeBody(record.dropFirst(4)) == message)
  }

  @Test
  func `oversized viewport movements are rejected`() {
    let body = Data(
      #"{"type":"Viewport","attachmentEpoch":"1","lines":1000001}"#.utf8
    )
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ControlMessage.self, from: body)
    }
  }

  @Test
  func `history viewport is advertised by name`() throws {
    #expect(RSTFeatures.supported.contains(.historyViewport))
    let attached = ControlMessage.attached(
      .init(
        attachmentEpoch: 1,
        writerID: .random(),
        lastFullyAppliedInputSequence: 0,
        resizeRevision: 1,
        features: [.keypadKeys, .historyViewport]
      )
    )
    let record = try ControlRecord.encode(attached)
    let text = String(decoding: record.dropFirst(4), as: UTF8.self)
    #expect(text.contains(#""historyViewport""#))
    #expect(try ControlRecord.decodeBody(record.dropFirst(4)) == attached)
    // Older hosts' lists without it decode to a set without it.
    #expect(!RSTFeatures(names: ["keypadKeys"]).contains(.historyViewport))
  }
}
