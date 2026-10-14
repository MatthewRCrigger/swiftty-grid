import Foundation

/// Resource bounds for SFTP v3 packet bodies and individual fields.
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
  public static let maxLanguageBytes = 256
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
  case invalidAttributes
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
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case opendir = 11
    case readdir = 12
    case remove = 13
    case realpath = 16
    case stat = 17
    case rename = 18
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
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

  /// Validates every field and total body size before allocating a packet.
  func validatedBodyLength() throws(SFTPCodecError) -> Int {
    var writer = SFTPWriter(collectBytes: false)
    try write(to: &writer)
    return writer.bodyLength
  }

  /// The complete packet including its `uint32` length prefix. Invalid
  /// fields and oversized bodies are refused before packet allocation.
  public func encoded() throws(SFTPCodecError) -> [UInt8] {
    let length = try validatedBodyLength()
    var writer = SFTPWriter(collectBytes: true)
    writer.bytes = [0, 0, 0, 0]
    writer.bytes.reserveCapacity(length + 4)
    try write(to: &writer)
    let size = UInt32(length)
    writer.bytes[0] = UInt8(size >> 24)
    writer.bytes[1] = UInt8(size >> 16 & 0xFF)
    writer.bytes[2] = UInt8(size >> 8 & 0xFF)
    writer.bytes[3] = UInt8(size & 0xFF)
    return writer.bytes
  }

  private func write(to w: inout SFTPWriter) throws(SFTPCodecError) {
    switch self {
    case let .initialize(version, extensions):
      try w.byte(PacketType.initialize.rawValue)
      try w.uint32(version)
      try w.extensions(extensions, counted: false)
    case let .version(version, extensions):
      try w.byte(PacketType.version.rawValue)
      try w.uint32(version)
      try w.extensions(extensions, counted: false)
    case let .open(id, path, flags, attrs):
      try w.header(.open, id)
      try w.string(path, max: SFTPLimits.maxPathBytes)
      try w.uint32(flags.rawValue)
      try w.attributes(attrs)
    case let .close(id, handle):
      try w.header(.close, id)
      try w.string(handle, max: SFTPLimits.maxHandleBytes)
    case let .read(id, handle, offset, length):
      try w.header(.read, id)
      try w.string(handle, max: SFTPLimits.maxHandleBytes)
      try w.uint64(offset)
      try w.uint32(length)
    case let .write(id, handle, offset, data):
      try w.header(.write, id)
      try w.string(handle, max: SFTPLimits.maxHandleBytes)
      try w.uint64(offset)
      try w.string(data, max: SFTPLimits.maxPacketBytes)
    case let .lstat(id, path):
      try w.header(.lstat, id);
      try w.string(path, max: SFTPLimits.maxPathBytes)
    case let .fstat(id, handle):
      try w.header(.fstat, id);
      try w.string(handle, max: SFTPLimits.maxHandleBytes)
    case let .opendir(id, path):
      try w.header(.opendir, id);
      try w.string(path, max: SFTPLimits.maxPathBytes)
    case let .readdir(id, handle):
      try w.header(.readdir, id);
      try w.string(handle, max: SFTPLimits.maxHandleBytes)
    case let .remove(id, path):
      try w.header(.remove, id);
      try w.string(path, max: SFTPLimits.maxPathBytes)
    case let .realpath(id, path):
      try w.header(.realpath, id);
      try w.string(path, max: SFTPLimits.maxPathBytes)
    case let .stat(id, path):
      try w.header(.stat, id);
      try w.string(path, max: SFTPLimits.maxPathBytes)
    case let .rename(id, old, new):
      try w.header(.rename, id)
      try w.string(old, max: SFTPLimits.maxPathBytes)
      try w.string(new, max: SFTPLimits.maxPathBytes)
    case let .extended(id, name, data):
      try w.header(.extended, id)
      try w.string(name, max: SFTPLimits.maxExtensionBytes)
      try w.raw(data)
    case let .status(id, status):
      try w.header(.status, id)
      try w.uint32(status.code.rawValue)
      try w.string(status.message, max: SFTPLimits.maxStatusMessageBytes)
      try w.string(status.language, max: SFTPLimits.maxLanguageBytes)
    case let .handle(id, handle):
      try w.header(.handle, id);
      try w.string(handle, max: SFTPLimits.maxHandleBytes)
    case let .data(id, data):
      try w.header(.data, id);
      try w.string(data, max: SFTPLimits.maxPacketBytes)
    case let .name(id, entries):
      guard entries.count <= SFTPLimits.maxNamesPerPacket else {
        throw .tooManyEntries
      }
      try w.header(.name, id)
      try w.uint32(UInt32(entries.count))
      for entry in entries {
        try w.string(entry.filename, max: SFTPLimits.maxPathBytes)
        try w.string(entry.longname, max: SFTPLimits.maxLongnameBytes)
        try w.attributes(entry.attributes)
      }
    case let .attrs(id, attrs):
      try w.header(.attrs, id);
      try w.attributes(attrs)
    }
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
    case .initialize, .version: preconditionFailure("handled above")
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
        r.isAtEnd
        ? "" : try r.lossyString(max: SFTPLimits.maxStatusMessageBytes)
      let language =
        r.isAtEnd ? "" : try r.string(max: SFTPLimits.maxLanguageBytes)
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
/// buffering its body. Complete coalesced packets remain buffered until
/// `next()` drains them.
public struct SFTPPacketReader: Sendable {
  private var buffer: [UInt8] = []
  private var start = 0
  private var scan = 0
  private var bodyRemaining = 0
  private var rejectedPrefix = false

  public init() {}

  public var bufferedBytes: Int { buffer.count - start }

  public mutating func append(_ bytes: some Sequence<UInt8>) {
    compact()
    guard !rejectedPrefix else { return }
    for byte in bytes {
      buffer.append(byte)
      if bodyRemaining > 0 {
        bodyRemaining -= 1
        if bodyRemaining == 0 { scan = buffer.count }
      } else if buffer.count - scan == 4 {
        checkPrefix()
        if rejectedPrefix { return }
      }
    }
  }

  /// Copy bounded portions of ordinary receive buffers in bulk.
  public mutating func append(_ bytes: some Collection<UInt8>) {
    compact()
    guard !rejectedPrefix else { return }
    var index = bytes.startIndex
    while index != bytes.endIndex {
      let remaining =
        bodyRemaining > 0 ? bodyRemaining : 4 - (buffer.count - scan)
      let next =
        bytes.index(index, offsetBy: remaining, limitedBy: bytes.endIndex)
        ?? bytes.endIndex
      let copied = bytes.distance(from: index, to: next)
      buffer.append(contentsOf: bytes[index ..< next])
      index = next
      if bodyRemaining > 0 {
        bodyRemaining -= copied
        if bodyRemaining == 0 { scan = buffer.count }
      } else if buffer.count - scan == 4 {
        checkPrefix()
        if rejectedPrefix { return }
      }
    }
  }

  private mutating func compact() {
    if start > 0, start >= buffer.count / 2 {
      buffer.removeFirst(start)
      scan -= start
      start = 0
    }
  }

  private mutating func checkPrefix() {
    let length =
      Int(buffer[scan]) << 24 | Int(buffer[scan + 1]) << 16 | Int(
        buffer[scan + 2]
      ) << 8 | Int(buffer[scan + 3])
    guard length > 0, length <= SFTPLimits.maxPacketBytes else {
      // Keep the prefix for next() to report in stream order, but
      // never read its body or any later input from the sequence.
      rejectedPrefix = true
      return
    }
    bodyRemaining = length
  }

  /// The next complete packet, or `nil` if more bytes are needed.
  public mutating func next() throws(SFTPCodecError) -> SFTPMessage? {
    guard bufferedBytes >= 4 else { return nil }
    let length =
      Int(buffer[start]) << 24 | Int(buffer[start + 1]) << 16 | Int(
        buffer[start + 2]
      ) << 8 | Int(buffer[start + 3])
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
    return UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(
      bytes[index + 2]
    ) << 8 | UInt32(bytes[index + 3])
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
