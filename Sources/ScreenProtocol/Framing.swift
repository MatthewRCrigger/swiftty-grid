import Foundation
import SessionCore

public enum FramingError: Error, Equatable, Sendable {
  case recordTooLarge(Int)
  case malformedJSON
  case unsupportedEncoding(UInt8)
  case lengthMismatch
  case snapshotTooLarge
  case decompression(Zlib.Error)
  case invalidSnapshot(SnapshotValidationError)
  case trailingData
  case truncated
}

func makeEncoder() -> JSONEncoder {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.withoutEscapingSlashes]
  return encoder
}

/// Control records: `UInt32BE(length)` + UTF-8 JSON object (spec §7.2).
public enum ControlRecord {
  public static func encode(_ message: ControlMessage) throws -> [UInt8] {
    let json = try makeEncoder().encode(message)
    guard json.count <= RSTLimits.maxControlRecordBytes else {
      throw FramingError.recordTooLarge(json.count)
    }
    var out = [UInt8]()
    out.reserveCapacity(json.count + 4)
    appendUInt32(UInt32(json.count), to: &out)
    out.append(contentsOf: json)
    return out
  }

  public static func decodeBody(_ body: some Collection<UInt8>) throws(FramingError)
    -> ControlMessage
  {
    do {
      return try JSONDecoder().decode(ControlMessage.self, from: Data(body))
    } catch {
      throw .malformedJSON
    }
  }
}

/// Incremental control-stream reader. Rejects a length prefix over the
/// limit before buffering the body.
public struct ControlRecordReader: Sendable {
  private var buffer: [UInt8] = []
  public let limit: Int

  public init(limit: Int = RSTLimits.maxControlRecordBytes) {
    self.limit = limit
  }

  public var bufferedBytes: Int { buffer.count }

  /// Appends received bytes and returns every complete message.
  public mutating func append(
    _ bytes: some Collection<UInt8>
  ) throws(FramingError) -> [ControlMessage] {
    buffer.append(contentsOf: bytes)
    var messages: [ControlMessage] = []
    var start = 0
    while buffer.count - start >= 4 {
      let length = Int(readUInt32(buffer, at: start))
      guard length <= limit else { throw .recordTooLarge(length) }
      guard buffer.count - start - 4 >= length else { break }
      let body = buffer[(start + 4) ..< (start + 4 + length)]
      messages.append(try ControlRecord.decodeBody(body))
      start += 4 + length
    }
    if start > 0 { buffer.removeFirst(start) }
    return messages
  }
}

/// Snapshot stream payload: one record then FIN (spec §7.2).
///
///     UInt8     encoding: 0 = plain UTF-8 JSON, 1 = RFC 1950 zlib
///     UInt32BE  decodedLength
///     UInt32BE  encodedLength
///     Byte[]    encoded snapshot JSON
public enum SnapshotFrame {
  public enum Encoding: UInt8, Sendable { case plain = 0, zlib = 1 }
  public static let headerLength = 9

  public static func encode(
    _ snapshot: ScreenSnapshot,
    encoding: Encoding = .zlib
  ) throws -> [UInt8] {
    let json = Array(try makeEncoder().encode(snapshot))
    guard json.count <= RSTLimits.maxSnapshotDecodedBytes else {
      throw FramingError.snapshotTooLarge
    }
    let body = encoding == .zlib ? Zlib.compress(json) : json
    guard body.count <= RSTLimits.maxSnapshotEncodedBytes else {
      throw FramingError.snapshotTooLarge
    }
    var out = [encoding.rawValue]
    out.reserveCapacity(headerLength + body.count)
    appendUInt32(UInt32(json.count), to: &out)
    appendUInt32(UInt32(body.count), to: &out)
    out.append(contentsOf: body)
    return out
  }

  /// Parsed header; lets a reader bound buffering before the body arrives.
  public struct Header: Equatable, Sendable {
    public var encoding: Encoding
    public var decodedLength: Int
    public var encodedLength: Int
  }

  public static func header(
    _ bytes: some Collection<UInt8>
  ) throws(FramingError) -> Header? {
    guard bytes.count >= headerLength else { return nil }
    let b = Array(bytes.prefix(headerLength))
    guard let encoding = Encoding(rawValue: b[0]) else {
      throw .unsupportedEncoding(b[0])
    }
    let decoded = Int(readUInt32(b, at: 1))
    let encoded = Int(readUInt32(b, at: 5))
    guard decoded <= RSTLimits.maxSnapshotDecodedBytes,
      encoded <= RSTLimits.maxSnapshotEncodedBytes
    else { throw .snapshotTooLarge }
    if encoding == .plain, decoded != encoded { throw .lengthMismatch }
    return Header(encoding: encoding, decodedLength: decoded, encodedLength: encoded)
  }

  /// Decodes and validates a complete stream payload. Only a fully
  /// decoded, validated snapshot is ever returned.
  public static func decode(
    _ bytes: [UInt8]
  ) throws(FramingError) -> ScreenSnapshot {
    guard let header = try header(bytes) else { throw .truncated }
    let total = headerLength + header.encodedLength
    guard bytes.count >= total else { throw .truncated }
    guard bytes.count == total else { throw .trailingData }
    let body = Array(bytes[headerLength...])
    let json: [UInt8]
    switch header.encoding {
    case .plain: json = body
    case .zlib:
      do {
        json = try Zlib.decompress(body, limit: header.decodedLength)
      } catch {
        throw .decompression(error)
      }
    }
    guard json.count == header.decodedLength else { throw .lengthMismatch }
    let snapshot: ScreenSnapshot
    do {
      snapshot = try JSONDecoder().decode(ScreenSnapshot.self, from: Data(json))
    } catch {
      throw .malformedJSON
    }
    do { try snapshot.validate() } catch { throw .invalidSnapshot(error) }
    return snapshot
  }
}

/// Accumulates one snapshot stream, enforcing the header's bounds while
/// bytes arrive.
public struct SnapshotStreamReader: Sendable {
  private var buffer: [UInt8] = []
  private var header: SnapshotFrame.Header?

  public init() {}

  public mutating func append(
    _ bytes: some Collection<UInt8>
  ) throws(FramingError) {
    buffer.append(contentsOf: bytes)
    if header == nil { header = try SnapshotFrame.header(buffer) }
    let cap = SnapshotFrame.headerLength
      + (header?.encodedLength ?? RSTLimits.maxSnapshotEncodedBytes)
    guard buffer.count <= cap else { throw .trailingData }
  }

  /// Call at FIN.
  public func finish() throws(FramingError) -> ScreenSnapshot {
    try SnapshotFrame.decode(buffer)
  }
}

@inline(__always)
func appendUInt32(_ value: UInt32, to out: inout [UInt8]) {
  out.append(UInt8(value >> 24))
  out.append(UInt8(value >> 16 & 0xFF))
  out.append(UInt8(value >> 8 & 0xFF))
  out.append(UInt8(value & 0xFF))
}

@inline(__always)
func readUInt32(_ bytes: [UInt8], at i: Int) -> UInt32 {
  UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16
    | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
}
