import Foundation

/// Bounds enforced by the SFTP v3 codec before any allocation.
public enum SFTPLimits {
  /// Largest accepted packet body (after the 4-byte length). OpenSSH
  /// uses 256 KiB.
  public static let maxPacketBytes = 256 * 1024
  public static let maxHandleBytes = 256
  public static let maxPathBytes = 4096
  public static let maxLongnameBytes = 8192
  public static let maxNamesPerPacket = 1024
  public static let maxExtensions = 64
  public static let maxExtensionBytes = 4096
  public static let maxStatusMessageBytes = 4096
}

public enum SFTPCodecError: Error, Equatable, Sendable {
  case truncated
  case packetTooLarge(Int)
  case emptyPacket
  case unknownType(UInt8)
  case stringTooLong
  case tooManyEntries
  case invalidUTF8
  case trailingBytes
}

/// `SSH_FXF_*` open flags.
public struct SFTPOpenFlags: OptionSet, Hashable, Sendable {
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let read = SFTPOpenFlags(rawValue: 0x01)
  public static let write = SFTPOpenFlags(rawValue: 0x02)
  public static let append = SFTPOpenFlags(rawValue: 0x04)
  public static let create = SFTPOpenFlags(rawValue: 0x08)
  public static let truncate = SFTPOpenFlags(rawValue: 0x10)
  public static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

/// `SSH_FX_*` status codes.
public struct SFTPStatusCode: RawRepresentable, Hashable, Sendable,
  CustomStringConvertible
{
  public let rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public static let ok = SFTPStatusCode(rawValue: 0)
  public static let eof = SFTPStatusCode(rawValue: 1)
  public static let noSuchFile = SFTPStatusCode(rawValue: 2)
  public static let permissionDenied = SFTPStatusCode(rawValue: 3)
  public static let failure = SFTPStatusCode(rawValue: 4)
  public static let badMessage = SFTPStatusCode(rawValue: 5)
  public static let noConnection = SFTPStatusCode(rawValue: 6)
  public static let connectionLost = SFTPStatusCode(rawValue: 7)
  public static let operationUnsupported = SFTPStatusCode(rawValue: 8)
  public var description: String { "SSH_FX(\(rawValue))" }
}

public struct SFTPStatus: Hashable, Sendable {
  public var code: SFTPStatusCode
  public var message: String
  public var language: String
  public init(code: SFTPStatusCode, message: String = "", language: String = "")
  {
    self.code = code
    self.message = message
    self.language = language
  }
}

public struct SFTPExtensionPair: Hashable, Sendable {
  public var name: String
  public var data: [UInt8]
  public init(name: String, data: [UInt8]) {
    self.name = name
    self.data = data
  }
}

/// SFTP v3 `ATTRS`.
public struct SFTPAttributes: Hashable, Sendable {
  public var size: UInt64?
  public var uid: UInt32?
  public var gid: UInt32?
  public var permissions: UInt32?
  public var accessTime: UInt32?
  public var modificationTime: UInt32?
  public var extended: [SFTPExtensionPair]

  public init(
    size: UInt64? = nil,
    uid: UInt32? = nil,
    gid: UInt32? = nil,
    permissions: UInt32? = nil,
    accessTime: UInt32? = nil,
    modificationTime: UInt32? = nil,
    extended: [SFTPExtensionPair] = []
  ) {
    self.size = size
    self.uid = uid
    self.gid = gid
    self.permissions = permissions
    self.accessTime = accessTime
    self.modificationTime = modificationTime
    self.extended = extended
  }

  static let fileTypeMask: UInt32 = 0o170000
  public static let regularFileType: UInt32 = 0o100000
  public static let directoryType: UInt32 = 0o040000
  public static let symbolicLinkType: UInt32 = 0o120000

  /// `true` only when permissions are present and say regular file.
  public var isRegularFile: Bool {
    permissions.map { $0 & Self.fileTypeMask == Self.regularFileType } ?? false
  }

  public var isDirectory: Bool {
    permissions.map { $0 & Self.fileTypeMask == Self.directoryType } ?? false
  }
}

public struct SFTPNameEntry: Hashable, Sendable {
  public var filename: String
  public var longname: String
  public var attributes: SFTPAttributes
  public init(filename: String, longname: String, attributes: SFTPAttributes) {
    self.filename = filename
    self.longname = longname
    self.attributes = attributes
  }
}

/// One SFTP v3 packet (draft-ietf-secsh-filexfer-02) in the supported
/// subset. Used by the client and by test servers.
public enum SFTPMessage: Hashable, Sendable {
  case initialize(version: UInt32, extensions: [SFTPExtensionPair])
  case version(version: UInt32, extensions: [SFTPExtensionPair])
  case open(id: UInt32, path: String, flags: SFTPOpenFlags, SFTPAttributes)
  case close(id: UInt32, handle: [UInt8])
  case read(id: UInt32, handle: [UInt8], offset: UInt64, length: UInt32)
  case write(id: UInt32, handle: [UInt8], offset: UInt64, data: [UInt8])
  case lstat(id: UInt32, path: String)
  case fstat(id: UInt32, handle: [UInt8])
  case opendir(id: UInt32, path: String)
  case readdir(id: UInt32, handle: [UInt8])
  case remove(id: UInt32, path: String)
  case realpath(id: UInt32, path: String)
  case stat(id: UInt32, path: String)
  case rename(id: UInt32, oldPath: String, newPath: String)
  case extended(id: UInt32, name: String, data: [UInt8])
  case status(id: UInt32, SFTPStatus)
  case handle(id: UInt32, [UInt8])
  case data(id: UInt32, [UInt8])
  case name(id: UInt32, [SFTPNameEntry])
  case attrs(id: UInt32, SFTPAttributes)

  enum PacketType: UInt8 {
    case initialize = 1, version = 2, open = 3, close = 4, read = 5
    case write = 6, lstat = 7, fstat = 8, opendir = 11, readdir = 12
    case remove = 13, realpath = 16, stat = 17, rename = 18
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
    case extended = 200
  }

  /// Request identifier; `nil` for `initialize`/`version`.
  public var id: UInt32? {
    switch self {
    case .initialize, .version: nil
    case let .open(id, _, _, _), let .close(id, _), let .read(id, _, _, _),
      let .write(id, _, _, _), let .lstat(id, _), let .fstat(id, _),
      let .opendir(id, _), let .readdir(id, _), let .remove(id, _),
      let .realpath(id, _), let .stat(id, _), let .rename(id, _, _),
      let .extended(id, _, _), let .status(id, _), let .handle(id, _),
      let .data(id, _), let .name(id, _), let .attrs(id, _):
      id
    }
  }

  // MARK: Encoding

  /// The complete packet including its `uint32` length prefix.
  public func encoded() -> [UInt8] {
    var w = SFTPWriter()
    w.bytes = [0, 0, 0, 0]
    switch self {
    case let .initialize(version, extensions):
      w.byte(PacketType.initialize.rawValue)
      w.uint32(version)
      for e in extensions { w.string(e.name); w.string(e.data) }
    case let .version(version, extensions):
      w.byte(PacketType.version.rawValue)
      w.uint32(version)
      for e in extensions { w.string(e.name); w.string(e.data) }
    case let .open(id, path, flags, attrs):
      w.header(.open, id)
      w.string(path)
      w.uint32(flags.rawValue)
      w.attributes(attrs)
    case let .close(id, handle):
      w.header(.close, id)
      w.string(handle)
    case let .read(id, handle, offset, length):
      w.header(.read, id)
      w.string(handle)
      w.uint64(offset)
      w.uint32(length)
    case let .write(id, handle, offset, data):
      w.header(.write, id)
      w.string(handle)
      w.uint64(offset)
      w.string(data)
    case let .lstat(id, path): w.header(.lstat, id); w.string(path)
    case let .fstat(id, handle): w.header(.fstat, id); w.string(handle)
    case let .opendir(id, path): w.header(.opendir, id); w.string(path)
    case let .readdir(id, handle): w.header(.readdir, id); w.string(handle)
    case let .remove(id, path): w.header(.remove, id); w.string(path)
    case let .realpath(id, path): w.header(.realpath, id); w.string(path)
    case let .stat(id, path): w.header(.stat, id); w.string(path)
    case let .rename(id, old, new):
      w.header(.rename, id)
      w.string(old)
      w.string(new)
    case let .extended(id, name, data):
      w.header(.extended, id)
      w.string(name)
      w.bytes += data
    case let .status(id, status):
      w.header(.status, id)
      w.uint32(status.code.rawValue)
      w.string(status.message)
      w.string(status.language)
    case let .handle(id, handle): w.header(.handle, id); w.string(handle)
    case let .data(id, data): w.header(.data, id); w.string(data)
    case let .name(id, entries):
      w.header(.name, id)
      w.uint32(UInt32(entries.count))
      for entry in entries {
        w.string(entry.filename)
        w.string(entry.longname)
        w.attributes(entry.attributes)
      }
    case let .attrs(id, attrs): w.header(.attrs, id); w.attributes(attrs)
    }
    let length = UInt32(w.bytes.count - 4)
    w.bytes[0] = UInt8(length >> 24)
    w.bytes[1] = UInt8(length >> 16 & 0xFF)
    w.bytes[2] = UInt8(length >> 8 & 0xFF)
    w.bytes[3] = UInt8(length & 0xFF)
    return w.bytes
  }

  // MARK: Decoding

  /// Decodes one packet body (type byte onward, without the length).
  public static func decode(
    body: ArraySlice<UInt8>
  ) throws(SFTPCodecError) -> SFTPMessage {
    guard body.count <= SFTPLimits.maxPacketBytes else {
      throw .packetTooLarge(body.count)
    }
    var r = SFTPReader(body)
    let rawType = try r.byte()
    guard let type = PacketType(rawValue: rawType) else {
      throw .unknownType(rawType)
    }
    let message: SFTPMessage
    switch type {
    case .initialize, .version:
      let version = try r.uint32()
      var extensions: [SFTPExtensionPair] = []
      while !r.isAtEnd {
        guard extensions.count < SFTPLimits.maxExtensions else {
          throw .tooManyEntries
        }
        let name = try r.string(max: SFTPLimits.maxExtensionBytes)
        let data = try r.bytes(max: SFTPLimits.maxExtensionBytes)
        extensions.append(SFTPExtensionPair(name: name, data: data))
      }
      message =
        type == .initialize
        ? .initialize(version: version, extensions: extensions)
        : .version(version: version, extensions: extensions)
      return message
    default: break
    }
    let id = try r.uint32()
    switch type {
    case .initialize, .version:
      preconditionFailure("handled above")
    case .open:
      let path = try r.path()
      let flags = SFTPOpenFlags(rawValue: try r.uint32())
      message = .open(id: id, path: path, flags: flags, try r.attributes())
    case .close: message = .close(id: id, handle: try r.handle())
    case .read:
      let handle = try r.handle()
      let offset = try r.uint64()
      message = .read(
        id: id,
        handle: handle,
        offset: offset,
        length: try r.uint32()
      )
    case .write:
      let handle = try r.handle()
      let offset = try r.uint64()
      let data = try r.bytes(max: SFTPLimits.maxPacketBytes)
      message = .write(id: id, handle: handle, offset: offset, data: data)
    case .lstat: message = .lstat(id: id, path: try r.path())
    case .fstat: message = .fstat(id: id, handle: try r.handle())
    case .opendir: message = .opendir(id: id, path: try r.path())
    case .readdir: message = .readdir(id: id, handle: try r.handle())
    case .remove: message = .remove(id: id, path: try r.path())
    case .realpath: message = .realpath(id: id, path: try r.path())
    case .stat: message = .stat(id: id, path: try r.path())
    case .rename:
      let old = try r.path()
      message = .rename(id: id, oldPath: old, newPath: try r.path())
    case .extended:
      let name = try r.string(max: SFTPLimits.maxExtensionBytes)
      message = .extended(id: id, name: name, data: r.rest())
    case .status:
      let code = SFTPStatusCode(rawValue: try r.uint32())
      // Some v3 servers omit message/language; accept their absence.
      let text =
        r.isAtEnd ? "" : try r.lossyString(max: SFTPLimits.maxStatusMessageBytes)
      let language = r.isAtEnd ? "" : try r.string(max: 256)
      message = .status(
        id: id,
        SFTPStatus(code: code, message: text, language: language)
      )
    case .handle: message = .handle(id: id, try r.handle())
    case .data:
      message = .data(id: id, try r.bytes(max: SFTPLimits.maxPacketBytes))
    case .name:
      let count = Int(try r.uint32())
      // Each entry needs at least 12 bytes: two empty strings + flags.
      guard count <= SFTPLimits.maxNamesPerPacket, count <= r.remaining / 12
      else { throw .tooManyEntries }
      var entries: [SFTPNameEntry] = []
      for _ in 0 ..< count {
        let filename = try r.path()
        let longname = try r.lossyString(max: SFTPLimits.maxLongnameBytes)
        entries.append(
          SFTPNameEntry(
            filename: filename,
            longname: longname,
            attributes: try r.attributes()
          )
        )
      }
      message = .name(id: id, entries)
    case .attrs: message = .attrs(id: id, try r.attributes())
    }
    guard r.isAtEnd else { throw .trailingBytes }
    return message
  }
}

/// Incremental packet framer. Rejects an oversized length prefix before
/// buffering the body, so buffered bytes stay bounded.
public struct SFTPPacketReader: Sendable {
  private var buffer: [UInt8] = []
  private var start = 0

  public init() {}

  public var bufferedBytes: Int { buffer.count - start }

  public mutating func append(_ bytes: some Sequence<UInt8>) {
    if start > 0, start >= buffer.count / 2 {
      buffer.removeFirst(start)
      start = 0
    }
    buffer.append(contentsOf: bytes)
  }

  /// The next complete packet, or `nil` if more bytes are needed.
  public mutating func next() throws(SFTPCodecError) -> SFTPMessage? {
    guard bufferedBytes >= 4 else { return nil }
    let length =
      Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16
      | Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
    guard length <= SFTPLimits.maxPacketBytes else {
      throw .packetTooLarge(length)
    }
    guard length > 0 else { throw .emptyPacket }
    guard bufferedBytes >= 4 + length else { return nil }
    let body = buffer[(start + 4) ..< (start + 4 + length)]
    start += 4 + length
    return try SFTPMessage.decode(body: body)
  }
}

struct SFTPWriter {
  var bytes: [UInt8] = []

  mutating func byte(_ value: UInt8) { bytes.append(value) }

  mutating func uint32(_ value: UInt32) {
    bytes += [
      UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF),
      UInt8(value & 0xFF),
    ]
  }

  mutating func uint64(_ value: UInt64) {
    uint32(UInt32(value >> 32))
    uint32(UInt32(value & 0xFFFF_FFFF))
  }

  mutating func string(_ value: String) { string(Array(value.utf8)) }

  mutating func string(_ value: [UInt8]) {
    uint32(UInt32(value.count))
    bytes += value
  }

  mutating func header(_ type: SFTPMessage.PacketType, _ id: UInt32) {
    byte(type.rawValue)
    uint32(id)
  }

  mutating func attributes(_ a: SFTPAttributes) {
    var flags: UInt32 = 0
    if a.size != nil { flags |= 0x1 }
    if a.uid != nil, a.gid != nil { flags |= 0x2 }
    if a.permissions != nil { flags |= 0x4 }
    if a.accessTime != nil, a.modificationTime != nil { flags |= 0x8 }
    if !a.extended.isEmpty { flags |= 0x8000_0000 }
    uint32(flags)
    if let size = a.size { uint64(size) }
    if let uid = a.uid, let gid = a.gid { uint32(uid); uint32(gid) }
    if let permissions = a.permissions { uint32(permissions) }
    if let atime = a.accessTime, let mtime = a.modificationTime {
      uint32(atime)
      uint32(mtime)
    }
    if !a.extended.isEmpty {
      uint32(UInt32(a.extended.count))
      for e in a.extended { string(e.name); string(e.data) }
    }
  }
}

struct SFTPReader {
  let bytes: ArraySlice<UInt8>
  var index: Int

  init(_ bytes: ArraySlice<UInt8>) {
    self.bytes = bytes
    self.index = bytes.startIndex
  }

  var remaining: Int { bytes.endIndex - index }
  var isAtEnd: Bool { index == bytes.endIndex }

  mutating func byte() throws(SFTPCodecError) -> UInt8 {
    guard remaining >= 1 else { throw .truncated }
    defer { index += 1 }
    return bytes[index]
  }

  mutating func uint32() throws(SFTPCodecError) -> UInt32 {
    guard remaining >= 4 else { throw .truncated }
    defer { index += 4 }
    return UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
      | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
  }

  mutating func uint64() throws(SFTPCodecError) -> UInt64 {
    let hi = try uint32()
    return UInt64(hi) << 32 | UInt64(try uint32())
  }

  /// Length-prefixed bytes; the length is checked against `max` and
  /// the remaining input before copying.
  mutating func bytes(max: Int) throws(SFTPCodecError) -> [UInt8] {
    let length = Int(try uint32())
    guard length <= max else { throw .stringTooLong }
    guard length <= remaining else { throw .truncated }
    defer { index += length }
    return Array(bytes[index ..< index + length])
  }

  mutating func string(max: Int) throws(SFTPCodecError) -> String {
    let raw = try bytes(max: max)
    guard let text = String(validating: raw, as: UTF8.self) else {
      throw .invalidUTF8
    }
    return text
  }

  /// Display-only text: invalid UTF-8 is replaced rather than rejected.
  mutating func lossyString(max: Int) throws(SFTPCodecError) -> String {
    String(decoding: try bytes(max: max), as: UTF8.self)
  }

  mutating func path() throws(SFTPCodecError) -> String {
    try string(max: SFTPLimits.maxPathBytes)
  }

  mutating func handle() throws(SFTPCodecError) -> [UInt8] {
    try bytes(max: SFTPLimits.maxHandleBytes)
  }

  mutating func rest() -> [UInt8] {
    defer { index = bytes.endIndex }
    return Array(bytes[index...])
  }

  mutating func attributes() throws(SFTPCodecError) -> SFTPAttributes {
    let flags = try uint32()
    var a = SFTPAttributes()
    if flags & 0x1 != 0 { a.size = try uint64() }
    if flags & 0x2 != 0 {
      a.uid = try uint32()
      a.gid = try uint32()
    }
    if flags & 0x4 != 0 { a.permissions = try uint32() }
    if flags & 0x8 != 0 {
      a.accessTime = try uint32()
      a.modificationTime = try uint32()
    }
    if flags & 0x8000_0000 != 0 {
      let count = Int(try uint32())
      guard count <= SFTPLimits.maxExtensions, count <= remaining / 8 else {
        throw .tooManyEntries
      }
      for _ in 0 ..< count {
        let name = try string(max: SFTPLimits.maxExtensionBytes)
        let data = try bytes(max: SFTPLimits.maxExtensionBytes)
        a.extended.append(SFTPExtensionPair(name: name, data: data))
      }
    }
    return a
  }
}
