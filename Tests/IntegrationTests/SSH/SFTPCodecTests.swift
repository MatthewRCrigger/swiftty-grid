import Foundation
import Testing

@testable import SSHClient

/// Deterministic generator for fuzz inputs.
struct SplitMix64: RandomNumberGenerator {
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

struct SFTPCodecTests {
  static let samples: [SFTPMessage] = [
    .initialize(version: 3, extensions: []),
    .version(
      version: 3,
      extensions: [SFTPExtensionPair(name: "posix-rename@openssh.com", data: Array("1".utf8))]
    ),
    .open(
      id: 1,
      path: "/tmp/ü file",
      flags: [.write, .create, .exclusive],
      SFTPAttributes(permissions: 0o600)
    ),
    .close(id: 2, handle: [1, 2, 3, 4]),
    .read(id: 3, handle: [9], offset: 1 << 40, length: 32768),
    .write(id: 4, handle: [9], offset: 7, data: Array(repeating: 0xAB, count: 1000)),
    .lstat(id: 5, path: "a"),
    .fstat(id: 6, handle: [1]),
    .opendir(id: 7, path: "/"),
    .readdir(id: 8, handle: [2]),
    .remove(id: 9, path: "/x"),
    .realpath(id: 10, path: "."),
    .stat(id: 11, path: "/y"),
    .rename(id: 12, oldPath: "/a", newPath: "/b"),
    .extended(id: 13, name: "posix-rename@openssh.com", data: [0, 0, 0, 1, 0x61]),
    .status(id: 14, SFTPStatus(code: .eof, message: "End of file", language: "en")),
    .handle(id: 15, [0xFF, 0]),
    .data(id: 16, Array(0 ..< 255)),
    .name(
      id: 17,
      [
        SFTPNameEntry(
          filename: "f",
          longname: "-rw-r--r-- f",
          attributes: SFTPAttributes(
            size: 10,
            uid: 501,
            gid: 20,
            permissions: 0o100644,
            accessTime: 1,
            modificationTime: 2,
            extended: [SFTPExtensionPair(name: "x", data: [1])]
          )
        )
      ]
    ),
    .attrs(id: 18, SFTPAttributes(size: 0, permissions: 0o040755)),
  ]

  @Test
  func `every message round trips through the incremental reader`() throws {
    var reader = SFTPPacketReader()
    for message in Self.samples {
      // Feed one byte at a time to exercise partial packets.
      for byte in message.encoded() {
        reader.append([byte])
        if let decoded = try reader.next() {
          #expect(decoded == message)
        }
      }
    }
    #expect(reader.bufferedBytes == 0)
  }

  @Test
  func `oversized length is rejected before the body is buffered`() {
    var reader = SFTPPacketReader()
    reader.append([0x7F, 0xFF, 0xFF, 0xFF])
    #expect(throws: SFTPCodecError.packetTooLarge(0x7FFF_FFFF)) {
      _ = try reader.next()
    }
    #expect(reader.bufferedBytes == 4)

    var empty = SFTPPacketReader()
    empty.append([0, 0, 0, 0])
    #expect(throws: SFTPCodecError.emptyPacket) { _ = try empty.next() }
  }

  @Test
  func `malformed bodies are rejected`() {
    func decode(_ body: [UInt8]) throws(SFTPCodecError) -> SFTPMessage {
      try SFTPMessage.decode(body: body[...])
    }
    #expect(throws: SFTPCodecError.unknownType(99)) { try decode([99]) }
    #expect(throws: SFTPCodecError.truncated) { try decode([102, 0, 0]) }
    // Handle longer than 256 bytes.
    #expect(throws: SFTPCodecError.stringTooLong) {
      try decode([102, 0, 0, 0, 1, 0, 0, 1, 1] + [UInt8](repeating: 0, count: 257))
    }
    // String length pointing past the end.
    #expect(throws: SFTPCodecError.truncated) {
      try decode([102, 0, 0, 0, 1, 0, 0, 0, 9, 1])
    }
    // Trailing bytes after a complete STATUS.
    var status = SFTPMessage.status(id: 1, SFTPStatus(code: .ok)).encoded()
    status.append(0)
    #expect(throws: SFTPCodecError.trailingBytes) {
      try decode(Array(status.dropFirst(4)))
    }
    // NAME count claims far more entries than bytes present.
    #expect(throws: SFTPCodecError.tooManyEntries) {
      try decode([104, 0, 0, 0, 1, 0xFF, 0xFF, 0xFF, 0xFF])
    }
    #expect(throws: SFTPCodecError.tooManyEntries) {
      try decode([104, 0, 0, 0, 1, 0, 0, 0x10, 0] + [UInt8](repeating: 0, count: 64))
    }
    // Invalid UTF-8 path.
    #expect(throws: SFTPCodecError.invalidUTF8) {
      try decode([17, 0, 0, 0, 1, 0, 0, 0, 2, 0xC3, 0x28])
    }
    // Attribute extension count bomb.
    #expect(throws: SFTPCodecError.tooManyEntries) {
      try decode([105, 0, 0, 0, 1, 0x80, 0, 0, 0, 0x7F, 0xFF, 0xFF, 0xFF])
    }
  }

  @Test
  func `random input never crashes or over-allocates`() {
    var rng = SplitMix64(seed: 0x5F7F_0001)
    for _ in 0 ..< 5000 {
      let count = Int.random(in: 0 ... 96, using: &rng)
      var bytes = (0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
      if !bytes.isEmpty, Bool.random(using: &rng) {
        // Bias toward known packet types.
        bytes[0] = [1, 2, 3, 4, 5, 6, 101, 102, 103, 104, 105, 200].randomElement(
          using: &rng
        )!
      }
      _ = try? SFTPMessage.decode(body: bytes[...])
    }
  }

  @Test
  func `mutated valid packets never crash the reader`() {
    var rng = SplitMix64(seed: 0xC0DE)
    for _ in 0 ..< 400 {
      var packet = Self.samples.randomElement(using: &rng)!.encoded()
      for _ in 0 ..< Int.random(in: 1 ... 4, using: &rng) {
        let index = Int.random(in: 0 ..< packet.count, using: &rng)
        packet[index] = UInt8.random(in: 0 ... 255, using: &rng)
      }
      var reader = SFTPPacketReader()
      reader.append(packet)
      _ = try? reader.next()
      #expect(reader.bufferedBytes <= packet.count)
    }
  }

  @Test
  func `attributes classify file types`() {
    #expect(SFTPAttributes(permissions: 0o100644).isRegularFile)
    #expect(!SFTPAttributes(permissions: 0o040755).isRegularFile)
    #expect(SFTPAttributes(permissions: 0o040755).isDirectory)
    #expect(!SFTPAttributes(permissions: 0o120777).isRegularFile)
    #expect(!SFTPAttributes().isRegularFile)
  }
}
