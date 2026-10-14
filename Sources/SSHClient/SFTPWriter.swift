/// Shares one bounded serialization path between size validation and
/// encoding. Validation counts bytes without retaining packet contents.
struct SFTPWriter {
  var bytes: [UInt8]
  private(set) var bodyLength = 0
  private let collectBytes: Bool

  init(collectBytes: Bool = true) {
    self.collectBytes = collectBytes
    bytes = []
  }

  mutating func raw(_ value: some Collection<UInt8>) throws(SFTPCodecError) {
    let count = value.count
    let size = bodyLength.addingReportingOverflow(count)
    guard !size.overflow, size.partialValue <= SFTPLimits.maxPacketBytes else {
      throw .packetTooLarge(size.overflow ? .max : size.partialValue)
    }
    bodyLength = size.partialValue
    if collectBytes { bytes.append(contentsOf: value) }
  }

  mutating func byte(_ value: UInt8) throws(SFTPCodecError) {
    try raw(CollectionOfOne(value))
  }

  mutating func uint32(_ value: UInt32) throws(SFTPCodecError) {
    try raw([
      UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF),
      UInt8(value & 0xFF),
    ])
  }

  mutating func uint64(_ value: UInt64) throws(SFTPCodecError) {
    try uint32(UInt32(value >> 32))
    try uint32(UInt32(value & 0xFFFF_FFFF))
  }

  mutating func string(_ value: String, max: Int) throws(SFTPCodecError) {
    try string(value.utf8, max: max)
  }

  mutating func string(
    _ value: some Collection<UInt8>,
    max: Int
  ) throws(SFTPCodecError) {
    guard value.count <= min(max, SFTPLimits.maxPacketBytes) else {
      throw .stringTooLong
    }
    // Every field cap fits UInt32. Packet accounting remains checked in raw.
    try uint32(UInt32(value.count))
    try raw(value)
  }

  mutating func header(
    _ type: SFTPMessage.PacketType,
    _ id: UInt32
  ) throws(SFTPCodecError) {
    try byte(type.rawValue)
    try uint32(id)
  }

  mutating func extensions(
    _ values: [SFTPExtensionPair],
    counted: Bool
  ) throws(SFTPCodecError) {
    guard values.count <= SFTPLimits.maxExtensions else {
      throw .tooManyEntries
    }
    if counted { try uint32(UInt32(values.count)) }
    for value in values {
      try string(value.name, max: SFTPLimits.maxExtensionBytes)
      try string(value.data, max: SFTPLimits.maxExtensionBytes)
    }
  }

  mutating func attributes(_ value: SFTPAttributes) throws(SFTPCodecError) {
    guard (value.uid == nil) == (value.gid == nil),
      (value.accessTime == nil) == (value.modificationTime == nil)
    else { throw .invalidAttributes }
    var flags: UInt32 = 0
    if value.size != nil { flags |= 0x1 }
    if value.uid != nil { flags |= 0x2 }
    if value.permissions != nil { flags |= 0x4 }
    if value.accessTime != nil { flags |= 0x8 }
    if !value.extended.isEmpty { flags |= 0x8000_0000 }
    try uint32(flags)
    if let size = value.size { try uint64(size) }
    if let uid = value.uid, let gid = value.gid {
      try uint32(uid)
      try uint32(gid)
    }
    if let permissions = value.permissions { try uint32(permissions) }
    if let atime = value.accessTime, let mtime = value.modificationTime {
      try uint32(atime)
      try uint32(mtime)
    }
    if !value.extended.isEmpty { try extensions(value.extended, counted: true) }
  }
}
