import Foundation

/// Bounded typed failure from the companion codec. Never carries payload
/// content.
public enum CompanionCodecError: Error, Hashable, Sendable {
  /// Payload larger than `CompanionLimits.maxPayloadBytes`.
  case tooLarge(Int)
  /// A version other than `CompanionLimits.version`.
  case unsupportedVersion(Int)
  /// Not valid JSON of the expected shape.
  case malformed
  /// Well-formed but violates a companion bound or invariant.
  case invalid(String)
}

/// Strict JSON codec for every companion payload.
///
/// Encoding and decoding both enforce the 16 KiB decoded maximum; the
/// size check precedes any parsing. Unknown versions and unexpected
/// fields are rejected, and text is sanitized on the way in.
public enum CompanionCodec {
  public static func encode(_ request: CompanionRequest) throws(CompanionCodecError) -> Data {
    try encodeValue(request)
  }

  public static func encode(_ reply: CompanionReply) throws(CompanionCodecError) -> Data {
    try encodeValue(reply)
  }

  public static func encode(
    _ context: CompanionApplicationContext
  ) throws(CompanionCodecError) -> Data {
    try encodeValue(context)
  }

  public static func decodeRequest(_ data: Data) throws(CompanionCodecError) -> CompanionRequest {
    try decodeValue(data)
  }

  public static func decodeReply(_ data: Data) throws(CompanionCodecError) -> CompanionReply {
    try decodeValue(data)
  }

  public static func decodeContext(
    _ data: Data
  ) throws(CompanionCodecError) -> CompanionApplicationContext {
    try decodeValue(data)
  }

  static func encodeValue<T: Encodable>(_ value: T) throws(CompanionCodecError) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data: Data
    do {
      data = try encoder.encode(value)
    } catch {
      throw .malformed
    }
    guard data.count <= CompanionLimits.maxPayloadBytes else {
      throw .tooLarge(data.count)
    }
    return data
  }

  static func decodeValue<T: Decodable>(_ data: Data) throws(CompanionCodecError) -> T {
    guard data.count <= CompanionLimits.maxPayloadBytes else {
      throw .tooLarge(data.count)
    }
    // Every companion payload is a JSON object.
    guard data.first(where: { !isJSONWhitespace($0) }) == UInt8(ascii: "{") else {
      throw .malformed
    }
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch let error as CompanionCodecError {
      throw error
    } catch {
      throw .malformed
    }
  }

  private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
  }
}
