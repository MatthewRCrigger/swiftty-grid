import Foundation
@testable import ScreenProtocol
import SessionCore
import Testing

func sampleSnapshot(
  columns: Int = 8,
  rows: Int = 3,
  revision: UInt64 = 1,
  epoch: UInt64 = 1,
  session: SessionID = SessionID(bytes: Array(repeating: 7, count: 16))!
) -> ScreenSnapshot {
  var s = ScreenSnapshot.blank(sessionID: session, columns: columns, rows: rows)
  s.screenRevision = revision
  s.attachmentEpoch = epoch
  s.styles = [.plain, CellStyle(foreground: RGBColor(0xFF0000), attributes: [.bold])]
  s.cells[0][0] = ScreenCell("e\u{301}", width: 1, style: 1)
  s.cells[0][1] = ScreenCell("界", width: 2, style: 0)
  s.cells[0][2] = .continuation
  s.cells[1][0] = ScreenCell("👩‍👩‍👧", width: 2, style: 1)
  s.cells[1][1] = ScreenCell("", width: 0, style: 1)
  s.wrapped[0] = true
  s.title = "title"
  return s
}

struct FramingTests {
  @Test
  func `zlib round trip and RFC 1950 header`() throws {
    let input = Array(String(repeating: "hello terminal ", count: 1000).utf8)
    let compressed = Zlib.compress(input)
    #expect(compressed[0] == 0x78)
    #expect((UInt16(compressed[0]) << 8 | UInt16(compressed[1])) % 31 == 0)
    #expect(compressed.count < input.count / 4)
    #expect(try Zlib.decompress(compressed, limit: input.count) == input)
    #expect(Zlib.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
  }

  @Test
  func `zlib enforces output limit, checksum and header`() {
    let input = [UInt8](repeating: 0, count: 100_000)
    let compressed = Zlib.compress(input)
    #expect(throws: Zlib.Error.outputLimit) {
      try Zlib.decompress(compressed, limit: 99_999)
    }
    var corrupt = compressed
    corrupt[corrupt.count - 1] ^= 1
    #expect(throws: Zlib.Error.checksum) {
      try Zlib.decompress(corrupt, limit: 200_000)
    }
    var header = compressed
    header[1] ^= 1
    #expect(throws: Zlib.Error.header) {
      try Zlib.decompress(header, limit: 200_000)
    }
    #expect(throws: Zlib.Error.truncated) {
      try Zlib.decompress(Array(compressed.prefix(3)), limit: 200_000)
    }
  }

  @Test(arguments: [SnapshotFrame.Encoding.plain, .zlib])
  func `snapshot frame round trip`(encoding: SnapshotFrame.Encoding) throws {
    let snapshot = sampleSnapshot()
    let frame = try SnapshotFrame.encode(snapshot, encoding: encoding)
    #expect(frame[0] == encoding.rawValue)
    let decoded = try SnapshotFrame.decode(frame)
    #expect(decoded == snapshot)
    #expect(decoded.cells[0][0].text == "e\u{301}")
    #expect(decoded.textLines[0] == "e\u{301}界")

    var reader = SnapshotStreamReader()
    for chunk in stride(from: 0, to: frame.count, by: 7) {
      try reader.append(frame[chunk ..< min(chunk + 7, frame.count)])
    }
    #expect(try reader.finish() == snapshot)
  }

  @Test
  func `snapshot frame rejects bad headers and bodies`() throws {
    let frame = try SnapshotFrame.encode(sampleSnapshot(), encoding: .plain)
    var badEncoding = frame
    badEncoding[0] = 9
    #expect(throws: FramingError.unsupportedEncoding(9)) {
      try SnapshotFrame.decode(badEncoding)
    }
    var huge = frame
    huge[1] = 0xFF
    #expect(throws: FramingError.snapshotTooLarge) {
      try SnapshotFrame.decode(huge)
    }
    #expect(throws: FramingError.trailingData) {
      try SnapshotFrame.decode(frame + [0])
    }
    #expect(throws: FramingError.truncated) {
      try SnapshotFrame.decode(Array(frame.dropLast()))
    }
    var reader = SnapshotStreamReader()
    try reader.append(frame)
    #expect(throws: FramingError.trailingData) { try reader.append([1]) }
  }

  @Test
  func `control records round trip incrementally`() throws {
    let token = ApplicationToken.random()
    let messages: [ControlMessage] = [
      .attach(
        .init(
          sessionID: .random(),
          serverInstanceID: .random(),
          writerID: .random(),
          applicationToken: token
        )
      ),
      .attached(
        .init(
          attachmentEpoch: 3,
          writerID: .random(),
          lastFullyAppliedInputSequence: UInt64.max,
          partialInputSequence: 4,
          resizeRevision: 2
        )
      ),
      .input(.init(attachmentEpoch: 3, sequence: 5, operation: .paste("x\ny"))),
      .input(
        .init(
          attachmentEpoch: 3,
          sequence: 6,
          operation: .key(SemanticKey(.character("c"), modifiers: [.control]))
        )
      ),
      .input(
        .init(
          attachmentEpoch: 3,
          sequence: 7,
          operation: .resize(columns: 100, rows: 30, resizeRevision: 9)
        )
      ),
      .inputAck(epoch: 3, sequence: 5),
      .screenAck(epoch: 3, screenRevision: 77),
      .ping(epoch: 3, nonce: 1), .pong(epoch: 3, nonce: 1),
      .detach(epoch: 3), .detached(epoch: 3), .terminate(epoch: 3),
      .terminated(epoch: 3),
      .sessionExited(epoch: 3, status: 0, finalScreenRevision: 80),
      .error(.init(.inputGap, sequence: 9, message: "gap")),
    ]
    var bytes: [UInt8] = []
    for m in messages { bytes += try ControlRecord.encode(m) }
    var reader = ControlRecordReader()
    var decoded: [ControlMessage] = []
    for b in bytes { decoded += try reader.append([b]) }
    #expect(decoded == messages)
    #expect(reader.bufferedBytes == 0)
    // 64-bit counters are decimal strings; tokens never print.
    let json = String(decoding: try ControlRecord.encode(messages[1]).dropFirst(4), as: UTF8.self)
    #expect(json.contains("\"18446744073709551615\""))
    #expect(!"\(messages[0])".contains(Data(token.bytes).base64EncodedString()))
  }

  @Test
  func `control reader rejects oversized, unknown and malformed records`() throws {
    var reader = ControlRecordReader()
    #expect(throws: FramingError.recordTooLarge(0x10_0000)) {
      try reader.append([0x00, 0x10, 0x00, 0x00])
    }
    for body in [
      #"{"type":"Bogus"}"#, #"{"type":"InputAck","attachmentEpoch":"01","sequence":"1"}"#,
      #"{"type":"InputAck","attachmentEpoch":1,"sequence":"1"}"#, "not json",
      #"{"type":"Input","attachmentEpoch":"1","sequence":"1","operation":{"op":"exec"}}"#,
    ] {
      var r = ControlRecordReader()
      var bytes: [UInt8] = []
      appendUInt32(UInt32(body.utf8.count), to: &bytes)
      bytes += Array(body.utf8)
      #expect(throws: FramingError.malformedJSON) { try r.append(bytes) }
    }
    // Unknown optional fields are ignored.
    let body = #"{"type":"Ping","attachmentEpoch":"1","nonce":"2","extra":true}"#
    var bytes: [UInt8] = []
    appendUInt32(UInt32(body.utf8.count), to: &bytes)
    bytes += Array(body.utf8)
    var fresh = ControlRecordReader()
    #expect(try fresh.append(bytes) == [.ping(epoch: 1, nonce: 2)])
  }

  @Test
  func `bootstrap envelope round trip and bounds`() throws {
    let request = BootstrapRequest(
      operation: .create,
      initialGrid: GridSize(columns: 80, rows: 24)
    )
    try request.validate()
    let bytes = try BootstrapEnvelope.encode(request)
    #expect(try BootstrapEnvelope.decode(BootstrapRequest.self, from: bytes) == request)
    #expect(throws: FramingError.trailingData) {
      try BootstrapEnvelope.decode(BootstrapRequest.self, from: bytes + [0])
    }
    #expect(throws: BootstrapRequest.ValidationError.unsupportedProtocol) {
      try BootstrapRequest(operation: .list, protocols: ["RST/2"]).validate()
    }
    #expect(throws: BootstrapRequest.ValidationError.invalidGrid) {
      try BootstrapRequest(
        operation: .create,
        initialGrid: GridSize(columns: 201, rows: 24)
      ).validate()
    }
    let grant = BootstrapGrant(
      serverInstanceID: .random(),
      sessionID: .random(),
      writerID: .random(),
      endpoint: BootstrapEndpoint(host: "mac.local", port: 51222),
      serverCertificateDER: Data([1, 2, 3]),
      serverCertificateSHA256: String(repeating: "a", count: 64),
      applicationToken: .random(),
      tokenExpiresAt: 1_000,
      initialGrid: GridSize(columns: 80, rows: 24)
    )
    for response in [
      BootstrapResponse.granted(grant), .sessions([]), .failure(.writerBusy),
      .terminated(grant.sessionID),
    ] {
      let data = try BootstrapEnvelope.encode(response)
      #expect(try BootstrapEnvelope.decode(BootstrapResponse.self, from: data) == response)
    }
    #expect(!grant.description.contains(Data(grant.applicationToken.bytes).base64EncodedString()))
  }
}
