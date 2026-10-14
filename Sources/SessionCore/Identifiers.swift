import Foundation

/// Fills `count` bytes from the system CSPRNG.
public func secureRandomBytes(_ count: Int) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  var generator = SystemRandomNumberGenerator()
  for i in bytes.indices { bytes[i] = generator.next() }
  return bytes
}

/// Lowercase hexadecimal, two digits per byte.
public func hexString(_ bytes: some Sequence<UInt8>) -> String {
  let digits = Array("0123456789abcdef".utf8)
  var out = [UInt8]()
  for byte in bytes {
    out.append(digits[Int(byte >> 4)])
    out.append(digits[Int(byte & 0xF)])
  }
  return String(decoding: out, as: UTF8.self)
}

/// Parses lowercase or uppercase hexadecimal with an exact byte count.
public func bytes(fromHex text: String, count: Int) -> [UInt8]? {
  let utf8 = Array(text.utf8)
  guard utf8.count == count * 2 else { return nil }
  func nibble(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0") ... UInt8(ascii: "9"): c - UInt8(ascii: "0")
    case UInt8(ascii: "a") ... UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A") ... UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
    default: nil
    }
  }
  var out = [UInt8]()
  out.reserveCapacity(count)
  var i = 0
  while i < utf8.count {
    guard let hi = nibble(utf8[i]), let lo = nibble(utf8[i + 1]) else {
      return nil
    }
    out.append(hi << 4 | lo)
    i += 2
  }
  return out
}

/// A fixed-size random identifier encoded on the wire as lowercase hex.
public protocol RandomIdentifier: Hashable, Sendable, Codable,
  CustomStringConvertible
{
  static var byteCount: Int { get }
  var bytes: [UInt8] { get }
  init?(bytes: [UInt8])
}

extension RandomIdentifier {
  public static func random() -> Self {
    Self(bytes: secureRandomBytes(byteCount))!
  }

  public init?(hex: String) {
    guard let b = SessionCore.bytes(fromHex: hex, count: Self.byteCount) else {
      return nil
    }
    self.init(bytes: b)
  }

  public var hex: String { hexString(bytes) }
  public var description: String { hex }

  public init(from decoder: any Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let value = Self(hex: text) else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "bad identifier"
        )
      )
    }
    self = value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(hex)
  }
}

/// Random 128-bit identifier of one host session.
public struct SessionID: RandomIdentifier {
  public static let byteCount = 16
  public let bytes: [UInt8]
  public init?(bytes: [UInt8]) {
    guard bytes.count == Self.byteCount else { return nil }
    self.bytes = bytes
  }
}

/// Random identifier for one `swifttyd` agent lifetime.
public struct ServerInstanceID: RandomIdentifier {
  public static let byteCount = 16
  public let bytes: [UInt8]
  public init?(bytes: [UInt8]) {
    guard bytes.count == Self.byteCount else { return nil }
    self.bytes = bytes
  }
}

/// Identity of the permitted input sequence for a session.
public struct WriterID: RandomIdentifier {
  public static let byteCount = 16
  public let bytes: [UInt8]
  public init?(bytes: [UInt8]) {
    guard bytes.count == Self.byteCount else { return nil }
    self.bytes = bytes
  }
}

/// Random 256-bit bearer capability. Never logged or described.
public struct ApplicationToken: Hashable, Sendable, Codable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  public static let byteCount = 32
  public let bytes: [UInt8]

  public init?(bytes: [UInt8]) {
    guard bytes.count == Self.byteCount else { return nil }
    self.bytes = bytes
  }

  public static func random() -> Self {
    Self(bytes: secureRandomBytes(byteCount))!
  }

  /// Constant-time comparison.
  public func matches(_ other: ApplicationToken) -> Bool {
    var diff: UInt8 = 0
    for i in 0 ..< Self.byteCount { diff |= bytes[i] ^ other.bytes[i] }
    return diff == 0
  }

  public var description: String { "ApplicationToken(<redacted>)" }
  public var debugDescription: String { description }

  public init(from decoder: any Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard let data = Data(base64Encoded: text),
      let value = Self(bytes: Array(data))
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "bad token")
      )
    }
    self = value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(Data(bytes).base64EncodedString())
  }
}

/// A 64-bit counter encoded on the wire as a decimal string (RST/1 §7.2).
public struct WireUInt64: Hashable, Sendable, Codable, Comparable,
  ExpressibleByIntegerLiteral, CustomStringConvertible
{
  public var value: UInt64
  public init(_ value: UInt64) { self.value = value }
  public init(integerLiteral value: UInt64) { self.value = value }

  public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
  public var description: String { String(value) }

  public init(from decoder: any Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    // Canonical decimal only: no sign, no leading zeros, no whitespace.
    guard !text.isEmpty, text.utf8.count <= 20,
      text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
      text == "0" || text.utf8.first != 0x30, let value = UInt64(text)
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "bad counter")
      )
    }
    self.value = value
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(String(value))
  }
}
