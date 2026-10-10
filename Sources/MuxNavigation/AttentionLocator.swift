import Foundation
import SwiftMuxProtocol

/// Opaque, non-secret, compact encoding of an `AttentionDestination` for
/// links (spec.inbox.md §4).
///
/// The locator is **not** an authentication credential and must never
/// become one: it carries only identifiers, never endpoints, hostnames,
/// usernames, passwords, keys, QUIC resume capabilities, approval tokens,
/// terminal output, program messages or commands. Links leak into logs,
/// browser history and previews; following one still requires the
/// recipient's own configured host and normal authentication.
///
/// Layout (version 1), then unpadded base64url:
///
/// ```text
/// u8   version (1)
/// u8   intent  (1 review, 2 result, 3 reveal)
/// u8   flags   (bit 0: tab present; other bits must be zero)
/// 16×  localHostProfileID, serviceEpoch, workspaceID, [tabID],
///      paneID, terminalEpoch, occurrenceID (raw UUID bytes)
/// u64  recordIncarnation (big-endian)
/// u8   recordPath length (≤ 128), then that many path bytes
/// ```
///
/// Decoding is strict: unknown versions, intents or flag bits, wrong
/// lengths, trailing bytes, non-canonical base64url and invalid record
/// paths are all rejected.
public enum AttentionLocator {
  public static let version: UInt8 = 1
  /// Largest encoded payload: header, seven UUIDs, incarnation, path.
  public static let maxPayloadBytes = 3 + 7 * 16 + 8 + 1 + RecordPathGrammar.maxBytes
  /// Longest locator text (base64url of `maxPayloadBytes`, unpadded).
  public static let maxLength = (maxPayloadBytes * 4 + 2) / 3
  static let minPayloadBytes = 3 + 6 * 16 + 8 + 1

  public enum DecodeError: Error, Sendable, Equatable {
    case empty
    case tooLong
    case invalidCharacters
    case nonCanonical
    case truncated
    case trailingBytes
    case unsupportedVersion(UInt8)
    case unsupportedIntent(UInt8)
    case unknownFlags
    case invalidRecordPath
  }

  public static func encode(_ destination: AttentionDestination) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(maxPayloadBytes)
    out.append(version)
    out.append(destination.intent.rawValue)
    out.append(destination.tabID == nil ? 0 : 1)
    func uuid(_ value: UUID) {
      withUnsafeBytes(of: value.uuid) { out.append(contentsOf: $0) }
    }
    uuid(destination.localHostProfileID)
    uuid(destination.serviceEpoch.rawValue)
    uuid(destination.workspaceID.rawValue)
    if let tab = destination.tabID { uuid(tab.rawValue) }
    uuid(destination.paneID.rawValue)
    uuid(destination.terminalEpoch.rawValue)
    uuid(destination.occurrenceID.rawValue)
    withUnsafeBytes(of: destination.recordIncarnation.bigEndian) {
      out.append(contentsOf: $0)
    }
    // Callers build destinations from validated items; an invalid path
    // is clamped to the root rather than emitted unvalidated.
    let path =
      RecordPathGrammar.isValid(destination.recordPath)
      ? Array(destination.recordPath.utf8) : []
    out.append(UInt8(path.count))
    out.append(contentsOf: path)
    return Base64URL.encode(out)
  }

  public static func decode(
    _ text: String
  ) throws(DecodeError) -> AttentionDestination {
    guard !text.isEmpty else { throw .empty }
    guard text.utf8.count <= maxLength else { throw .tooLong }
    guard let bytes = Base64URL.decode(text) else {
      throw .invalidCharacters
    }
    // Rejects alternative spellings of the same bytes (stray low bits).
    guard Base64URL.encode(bytes) == text else { throw .nonCanonical }
    guard bytes.count >= minPayloadBytes else { throw .truncated }
    var reader = Reader(bytes: bytes)
    let v = try reader.byte()
    guard v == version else { throw .unsupportedVersion(v) }
    let rawIntent = try reader.byte()
    guard let intent = AttentionDestination.Intent(rawValue: rawIntent) else {
      throw .unsupportedIntent(rawIntent)
    }
    let flags = try reader.byte()
    guard flags & ~1 == 0 else { throw .unknownFlags }
    let host = try reader.uuid()
    let epoch = try reader.uuid()
    let workspace = try reader.uuid()
    let tab = flags & 1 == 1 ? try reader.uuid() : nil
    let pane = try reader.uuid()
    let terminal = try reader.uuid()
    let occurrence = try reader.uuid()
    let incarnation = try reader.u64()
    let pathLength = Int(try reader.byte())
    guard pathLength <= RecordPathGrammar.maxBytes else {
      throw .invalidRecordPath
    }
    let pathBytes = try reader.bytes(pathLength)
    guard reader.isAtEnd else { throw .trailingBytes }
    guard let path = String(validating: pathBytes, as: UTF8.self),
      RecordPathGrammar.isValid(path)
    else { throw .invalidRecordPath }
    return AttentionDestination(
      localHostProfileID: host,
      serviceEpoch: ServerInstanceID(rawValue: epoch),
      workspaceID: WorkspaceID(rawValue: workspace),
      tabID: tab.map(TabID.init(rawValue:)),
      paneID: PaneID(rawValue: pane),
      terminalEpoch: TerminalEpochID(rawValue: terminal),
      recordPath: path,
      recordIncarnation: incarnation,
      occurrenceID: OccurrenceID(rawValue: occurrence),
      intent: intent
    )
  }

  private struct Reader {
    let bytes: [UInt8]
    var offset = 0

    var isAtEnd: Bool { offset == bytes.count }

    mutating func bytes(_ count: Int) throws(DecodeError) -> ArraySlice<UInt8> {
      guard count <= bytes.count - offset else { throw .truncated }
      defer { offset += count }
      return bytes[offset..<offset + count]
    }

    mutating func byte() throws(DecodeError) -> UInt8 {
      try bytes(1).first!
    }

    mutating func uuid() throws(DecodeError) -> UUID {
      let b = Array(try bytes(16))
      return UUID(
        uuid: (
          b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10],
          b[11], b[12], b[13], b[14], b[15]
        )
      )
    }

    mutating func u64() throws(DecodeError) -> UInt64 {
      try bytes(8).reduce(0) { $0 << 8 | UInt64($1) }
    }
  }
}

/// RFC 4648 §5 base64url without padding.
enum Base64URL {
  private static let alphabet = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8
  )

  static func encode(_ bytes: [UInt8]) -> String {
    var out: [UInt8] = []
    out.reserveCapacity((bytes.count * 4 + 2) / 3)
    var i = 0
    while i + 3 <= bytes.count {
      let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
      for shift in [18, 12, 6, 0] { out.append(alphabet[Int(n >> UInt32(shift) & 63)]) }
      i += 3
    }
    let rest = bytes.count - i
    if rest == 1 {
      let n = UInt32(bytes[i]) << 16
      out.append(alphabet[Int(n >> 18 & 63)])
      out.append(alphabet[Int(n >> 12 & 63)])
    } else if rest == 2 {
      let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8
      out.append(alphabet[Int(n >> 18 & 63)])
      out.append(alphabet[Int(n >> 12 & 63)])
      out.append(alphabet[Int(n >> 6 & 63)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Nil for any character outside the alphabet (including `=`) or an
  /// impossible length.
  static func decode(_ text: String) -> [UInt8]? {
    let input = Array(text.utf8)
    guard input.count % 4 != 1 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(input.count * 3 / 4)
    var acc: UInt32 = 0
    var bits = 0
    for c in input {
      let v: UInt32
      switch c {
      case 0x41...0x5A: v = UInt32(c - 0x41)
      case 0x61...0x7A: v = UInt32(c - 0x61 + 26)
      case 0x30...0x39: v = UInt32(c - 0x30 + 52)
      case 0x2D: v = 62  // -
      case 0x5F: v = 63  // _
      default: return nil
      }
      acc = acc << 6 | v
      bits += 6
      if bits >= 8 {
        bits -= 8
        out.append(UInt8(truncatingIfNeeded: acc >> UInt32(bits)))
        acc &= (1 << UInt32(bits)) - 1
      }
    }
    return out
  }
}
