/// Kitty drag-and-drop protocol (OSC 72) as a drop target, ported from
/// Ghostty's libghostty-vt. Like Ghostty:
///
/// - The terminal never starts a drag: offers and drags are refused with
///   EPERM.
/// - Every client is local: machine ids are ignored and remote transfers
///   are refused with EINVAL.
/// - The host captures the dropped data when the drop happens; requests
///   are served from those copies until the client concludes.
/// - Replies echo the command's terminator; events the terminal starts
///   (move, drop, leave) always end with ST.
/// - A command without `t` is ignored.
///
/// Specification: https://sw.kovidgoyal.net/kitty/dnd-protocol/
public enum KittyDragAndDrop {
  public enum Operation: UInt32, Sendable {
    case none = 0
    case copy = 1
    case move = 2

    /// 1 copies, 2 moves, anything else is none.
    init(code: UInt32) { self = Operation(rawValue: code) ?? .none }
  }

  /// Operations the drag source allows.
  public struct Operations: OptionSet, Sendable, Hashable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0b11 }
    public static let copy = Operations(rawValue: 1)
    public static let move = Operations(rawValue: 2)
  }

  /// A native drag over the terminal.
  public struct MoveEvent: Sendable, Hashable {
    /// Zero-based cell from the top left.
    public var column: UInt32
    public var row: UInt32
    /// Pixels from the content area's top left.
    public var pixelX: Int32
    public var pixelY: Int32
    public var operations: Operations

    public init(
      column: UInt32,
      row: UInt32,
      pixelX: Int32,
      pixelY: Int32,
      operations: Operations
    ) {
      self.column = column
      self.row = row
      self.pixelX = pixelX
      self.pixelY = pixelY
      self.operations = operations
    }
  }

  /// One dropped representation.
  public struct Item: Sendable, Equatable {
    public var mime: String
    public var data: [UInt8]
    public init(mime: String, data: [UInt8]) {
      self.mime = mime
      self.data = data
    }
  }

  /// What the host should react to; details are read from the state.
  public enum Event: Sendable, Equatable {
    /// Registered, re-registered or unregistered: refresh accepted types.
    case registration
    /// The client answered the current drag (`clientAccepted`).
    case acceptance
    /// The client finished with a drop; its data is released.
    case concluded(Operation)
  }

  static let maxMimeListBytes = 1 << 20
  static let base64ChunkBytes = 3072
  static let plainChunkBytes = 4096
  static let maxItems = 16

  // MARK: Commands

  enum Kind: UInt8 {
    case register = 0x61  // a
    case unregister = 0x41  // A
    case status = 0x6D  // m
    case drop = 0x4D  // M
    case request = 0x72  // r
    case requestError = 0x52  // R
    case offer = 0x6F  // o
    case present = 0x70  // p
    case startDrag = 0x50  // P
    case dragEvent = 0x65  // e
    case dragError = 0x45  // E
    case remoteData = 0x6B  // k
    case query = 0x71  // q
  }

  struct Metadata: Equatable {
    var kind: Kind?
    var more = false
    var clientID: UInt32 = 0
    var operation: UInt32 = 0
    var x: Int32 = 0
    var y: Int32 = 0
    var pixelX: Int32 = 0
    var pixelY: Int32 = 0

    /// `k=v(:k=v)*`, an optional trailing `:`; nil on any error.
    static func parse(_ raw: ArraySlice<UInt8>) -> Metadata? {
      var meta = Metadata()
      var i = raw.startIndex
      while i < raw.endIndex {
        let key = raw[i]
        i += 1
        guard i < raw.endIndex, raw[i] == 0x3D else { return nil }
        i += 1
        guard i < raw.endIndex else { return nil }
        if key == 0x74 {  // t: one type byte
          guard let kind = Kind(rawValue: raw[i]) else { return nil }
          meta.kind = kind
          i += 1
        } else {
          let negative = raw[i] == 0x2D
          let signed = [0x78, 0x79, 0x58, 0x59].contains(key)
          if negative {
            guard signed else { return nil }
            i += 1
          }
          var value: UInt64 = 0
          let start = i
          while i < raw.endIndex, i - start < 10,
            (0x30 ... 0x39).contains(raw[i])
          {
            value = value * 10 + UInt64(raw[i] - 0x30)
            i += 1
          }
          guard i > start, value <= UInt64(UInt32.max) else { return nil }
          let unsigned = UInt32(value)
          let int =
            negative
            ? 0 &- Int32(bitPattern: unsigned) : Int32(bitPattern: unsigned)
          switch key {
          case 0x6D: meta.more = unsigned != 0  // m
          case 0x69: meta.clientID = unsigned  // i
          case 0x6F: meta.operation = unsigned  // o
          case 0x78: meta.x = int
          case 0x79: meta.y = int
          case 0x58: meta.pixelX = int
          case 0x59: meta.pixelY = int
          default: return nil
          }
        }
        guard i == raw.endIndex || raw[i] == 0x3A else { return nil }
        i += 1
      }
      return meta
    }
  }

  // MARK: State

  /// One client registration, shared by both screens.
  public struct State: Sendable {
    /// A command split over packets keeps its first packet's metadata;
    /// meanwhile every OSC 72 continues it.
    var chunking = false
    var chunkMetadata = Metadata()
    public internal(set) var clientID: UInt32 = 0
    var registered: [UInt8] = []
    var hovered = false
    var dropped = false
    var accepted: Operation?
    var acceptInProgress = false
    var acceptedMimes: [UInt8] = []
    var offered: (mimes: [String], payload: [UInt8])?
    public internal(set) var items: [Item]?

    /// Types the client accepts drops of.
    public var registeredMimes: [String] {
      registered.split(separator: 0x20)
        .map { String(decoding: $0, as: UTF8.self) }
    }

    /// The client's answer for the current drag; nil until it answers
    /// (default to copying), `.none` when it refuses.
    public var clientAccepted: Operation? { acceptInProgress ? nil : accepted }

    /// Types the client accepted for the current drag.
    public var acceptedTypes: [String] {
      guard !acceptInProgress else { return [] }
      return acceptedMimes.split(separator: 0)
        .map { String(decoding: $0, as: UTF8.self) }
    }

    mutating func apply(_ raw: Metadata) -> Metadata {
      if chunking {
        var meta = chunkMetadata
        meta.more = raw.more
        chunking = raw.more
        return meta
      }
      if raw.more {
        chunking = true
        chunkMetadata = raw
      }
      return raw
    }

    /// Kitty's `reset_drop`: everything but the registration.
    mutating func resetDrop() {
      offered = nil
      items = nil
      acceptedMimes = []
      hovered = false
      dropped = false
      accepted = nil
      acceptInProgress = false
    }

    mutating func register(
      _ payload: ArraySlice<UInt8>,
      continuation: Bool,
      more: Bool
    ) -> Event? {
      if !continuation { registered.removeAll(keepingCapacity: true) }
      guard registered.count + payload.count <= maxMimeListBytes else {
        return nil
      }
      registered += payload
      return more ? nil : .registration
    }

    mutating func acceptStatus(
      _ meta: Metadata,
      _ payload: ArraySlice<UInt8>
    ) -> Event? {
      if !acceptInProgress {
        acceptedMimes = []
        acceptInProgress = true
        accepted = Operation(code: meta.operation)
      }
      if !payload.isEmpty {
        guard acceptedMimes.count + payload.count <= maxMimeListBytes else {
          return nil
        }
        acceptedMimes += payload
      }
      guard !meta.more else { return nil }
      acceptInProgress = false
      if !acceptedMimes.isEmpty {
        acceptedMimes = acceptedMimes.map { $0 == 0x20 ? 0 : $0 } + [0]
      }
      return .acceptance
    }

    mutating func moveEvent(
      _ event: MoveEvent,
      mimes: [String],
      drop: Bool
    ) -> [UInt8] {
      if !hovered { resetDrop() }
      hovered = true
      if drop {
        dropped = true
        hovered = false
      }
      if offered?.mimes != mimes {
        offered = (mimes, Array(mimes.map { $0 + " " }.joined().utf8))
      }
      let header =
        "t=\(drop ? "M" : "m"):x=\(event.column):y=\(event.row)"
        + ":X=\(event.pixelX):Y=\(event.pixelY):o=\(event.operations.rawValue)"
      return encode(
        header,
        clientID,
        offered!.payload,
        base64: false,
        "\u{1B}\\"
      )
    }
  }

  // MARK: Responses

  /// Chunks of `data` repeating the header and id, `m=1` on all but the
  /// last; empty data is one bare message (the end-of-data marker).
  static func encode(
    _ header: String,
    _ clientID: UInt32,
    _ data: [UInt8],
    base64: Bool,
    _ terminator: String
  ) -> [UInt8] {
    let prefix = Array(
      "\u{1B}]72;\(header)\(clientID != 0 ? ":i=\(clientID)" : "")".utf8
    )
    guard !data.isEmpty else { return prefix + terminator.utf8 }
    let limit = base64 ? base64ChunkBytes : plainChunkBytes
    var out: [UInt8] = []
    var start = 0
    while start < data.count {
      let end = min(start + limit, data.count)
      out += prefix
      out += (end < data.count ? ":m=1;" : ":m=0;").utf8
      let chunk = Array(data[start ..< end])
      out += base64 ? Base64.encode(chunk) : chunk
      out += terminator.utf8
      start = end
    }
    return out
  }

  static func requestKeys(
    x: Int32 = 0,
    y: Int32 = 0,
    pixelY: Int32 = 0
  ) -> String {
    (x != 0 ? ":x=\(x)" : "") + (y != 0 ? ":y=\(y)" : "")
      + (pixelY != 0 ? ":Y=\(pixelY)" : "")
  }

  static func error(
    drag: Bool,
    keys: String,
    clientID: UInt32,
    _ message: String,
    _ terminator: String
  ) -> [UInt8] {
    encode(
      (drag ? "t=E" : "t=R") + keys,
      clientID,
      Array(message.utf8),
      base64: false,
      terminator
    )
  }
}

extension TerminalState {
  typealias DnD = KittyDragAndDrop

  /// `OSC 72 ; metadata [; payload]`.
  mutating func kittyDragAndDrop(
    _ rest: UnsafeBufferPointer<UInt8>,
    terminator: String
  ) {
    let bytes = Array(rest)
    let split = bytes.firstIndex(of: 0x3B)
    guard let raw = DnD.Metadata.parse(bytes[..<(split ?? bytes.endIndex)])
    else { return }
    let payload = split.map { bytes[($0 + 1)...] } ?? []
    let continuation = dragAndDrop?.chunking ?? false
    let meta = dragAndDrop != nil ? dragAndDrop!.apply(raw) : raw
    guard let kind = meta.kind else { return }
    var event: DnD.Event?
    switch kind {
    case .register:
      guard meta.x != 1 else { return }  // a machine id: every client is local
      if dragAndDrop == nil {
        dragAndDrop = DnD.State()
        _ = dragAndDrop!.apply(raw)
      }
      dragAndDrop!.clientID = meta.clientID
      event = dragAndDrop!
        .register(payload, continuation: continuation, more: meta.more)
    case .unregister:
      guard dragAndDrop != nil else { return }
      dragAndDrop = nil
      event = .registration
    case .status:
      guard dragAndDrop != nil else { return }
      event = dragAndDrop!.acceptStatus(meta, payload)
    case .request: event = dragAndDropRequest(meta, terminator: terminator)
    case .offer where meta.x != 0: break  // enabling or disabling drags
    case .offer, .present, .startDrag:
      replyDragAndDrop(
        DnD.error(
          drag: true,
          keys: "",
          clientID: meta.clientID,
          "EPERM:drag out is not supported by this terminal",
          terminator
        )
      )
    case .query:
      replyDragAndDrop(
        DnD.encode("t=q", meta.clientID, [], base64: false, terminator)
      )
    case .drop, .requestError, .dragEvent, .dragError, .remoteData: break
    }
    if let event { events.append(.dragAndDrop(event)) }
  }

  private mutating func dragAndDropRequest(
    _ meta: DnD.Metadata,
    terminator: String
  ) -> DnD.Event? {
    // Data replies carry the registration's id, not the request's.
    let clientID = dragAndDrop?.clientID ?? 0
    if meta.pixelY != 0 || meta.y != 0 {
      let keys =
        meta.pixelY != 0
        ? DnD.requestKeys(x: meta.x, pixelY: meta.pixelY)
        : DnD.requestKeys(x: meta.x, y: meta.y)
      replyDragAndDrop(
        DnD.error(
          drag: false,
          keys: keys,
          clientID: clientID,
          "EINVAL:remote drop data is not supported",
          terminator
        )
      )
      return nil
    }
    guard meta.x != 0 else {
      // The client concludes the drop.
      guard dragAndDrop != nil else { return nil }
      let dropped = dragAndDrop!.dropped
      dragAndDrop!.resetDrop()
      return dropped ? .concluded(DnD.Operation(code: meta.operation)) : nil
    }
    let keys = DnD.requestKeys(x: meta.x)
    guard let items = dragAndDrop?.items else {
      replyDragAndDrop(
        DnD.error(
          drag: false,
          keys: keys,
          clientID: clientID,
          "ENOENT:no drop data available",
          terminator
        )
      )
      return nil
    }
    guard meta.x >= 1, Int(meta.x) <= items.count else {
      replyDragAndDrop(
        DnD.error(
          drag: false,
          keys: keys,
          clientID: clientID,
          "ENOENT:drop data request index out of bounds",
          terminator
        )
      )
      return nil
    }
    let header = "t=r" + keys
    let item = items[Int(meta.x) - 1]
    var out: [UInt8] = []
    if !item.data.isEmpty {
      out = DnD.encode(header, clientID, item.data, base64: true, terminator)
    }
    out += DnD.encode(header, clientID, [], base64: true, terminator)
    replyDragAndDrop(out)
    return nil
  }

  private mutating func replyDragAndDrop(_ bytes: [UInt8]) {
    guard !discardsReplies else { return }
    output.append(contentsOf: bytes)
  }

  /// A native drag moved over the terminal, offering `mimes` (in the
  /// order data requests index them, from 1). Returns the bytes for the
  /// program, or nil when no client is registered: handle the drag
  /// natively then.
  public mutating func dragMove(
    _ event: KittyDragAndDrop.MoveEvent,
    mimes: [String]
  ) -> [UInt8]? {
    guard dragAndDrop != nil else { return nil }
    return dragAndDrop!.moveEvent(event, mimes: mimes, drop: false)
  }

  /// The drag was dropped. At most 16 items are held until the client
  /// concludes; more are discarded.
  public mutating func dragDrop(
    _ event: KittyDragAndDrop.MoveEvent,
    items: [KittyDragAndDrop.Item]
  ) -> [UInt8]? {
    guard dragAndDrop != nil else { return nil }
    let held = Array(items.prefix(DnD.maxItems))
    let out = dragAndDrop!.moveEvent(event, mimes: held.map(\.mime), drop: true)
    dragAndDrop!.items = held
    return out
  }

  /// The drag left. Ignored after a drop, whose data must survive (some
  /// toolkits report a leave with the drop).
  public mutating func dragLeave() -> [UInt8]? {
    guard dragAndDrop != nil, !dragAndDrop!.dropped else { return nil }
    let hovered = dragAndDrop!.hovered
    dragAndDrop!.hovered = false
    dragAndDrop!.offered = nil
    guard hovered else { return nil }
    return DnD.encode(
      "t=m:x=-1:y=-1",
      dragAndDrop!.clientID,
      [],
      base64: false,
      "\u{1B}\\"
    )
  }
}
