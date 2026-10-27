import Foundation
import SessionCore

/// Bounded, typed failure codes. Never carries stack traces or secrets.
public enum RSTErrorCode: String, Hashable, Sendable, Codable {
  case malformed
  case unsupported
  case notAttached
  case unauthorized
  case expired
  case unknownSession
  case wrongInstance
  case staleEpoch
  /// Another writer still has admitted input; takeover refused.
  case writerBusy
  case inputWrongWriter
  case inputGap
  case inputConflict
  case inputBackpressure
  case inputInvalid
  case limitExceeded
  case sessionExited
  case internalError

  public init(_ rejection: HostInputLedger.Rejection) {
    switch rejection {
    case .wrongWriter: self = .inputWrongWriter
    case .gap: self = .inputGap
    case .conflict: self = .inputConflict
    case .backpressure: self = .inputBackpressure
    case .invalid: self = .inputInvalid
    }
  }
}

/// RST/1 control-stream messages (spec §7.2).
public enum ControlMessage: Hashable, Sendable {
  case attach(Attach)
  case attached(Attached)
  case input(Input)
  case inputAck(epoch: UInt64, sequence: UInt64)
  case screenAck(epoch: UInt64, screenRevision: UInt64)
  case ping(epoch: UInt64, nonce: UInt64)
  case pong(epoch: UInt64, nonce: UInt64)
  case detach(epoch: UInt64)
  case detached(epoch: UInt64)
  case terminate(epoch: UInt64)
  case terminated(epoch: UInt64)
  case sessionExited(epoch: UInt64, status: Int32, finalScreenRevision: UInt64)
  case error(RSTError)

  public struct Attach: Hashable, Sendable, Codable {
    public var sessionID: SessionID
    public var serverInstanceID: ServerInstanceID
    public var writerID: WriterID
    public var applicationToken: ApplicationToken

    public init(
      sessionID: SessionID,
      serverInstanceID: ServerInstanceID,
      writerID: WriterID,
      applicationToken: ApplicationToken
    ) {
      self.sessionID = sessionID
      self.serverInstanceID = serverInstanceID
      self.writerID = writerID
      self.applicationToken = applicationToken
    }
  }

  public struct Attached: Hashable, Sendable {
    public var attachmentEpoch: UInt64
    public var writerID: WriterID
    public var lastFullyAppliedInputSequence: UInt64
    /// An admitted operation whose bytes are not all written yet.
    public var partialInputSequence: UInt64?
    public var resizeRevision: UInt64
    /// Additions the host accepts; omitted (empty) from older hosts.
    public var features: RSTFeatures

    public init(
      attachmentEpoch: UInt64,
      writerID: WriterID,
      lastFullyAppliedInputSequence: UInt64,
      partialInputSequence: UInt64? = nil,
      resizeRevision: UInt64,
      features: RSTFeatures = []
    ) {
      self.attachmentEpoch = attachmentEpoch
      self.writerID = writerID
      self.lastFullyAppliedInputSequence = lastFullyAppliedInputSequence
      self.partialInputSequence = partialInputSequence
      self.resizeRevision = resizeRevision
      self.features = features
    }
  }

  public struct Input: Hashable, Sendable {
    public var attachmentEpoch: UInt64
    public var sequence: UInt64
    public var operation: InputOperation

    public init(
      attachmentEpoch: UInt64,
      sequence: UInt64,
      operation: InputOperation
    ) {
      self.attachmentEpoch = attachmentEpoch
      self.sequence = sequence
      self.operation = operation
    }
  }

  public struct RSTError: Hashable, Sendable, Error {
    public var code: RSTErrorCode
    /// The input sequence concerned, if any.
    public var sequence: UInt64?
    /// Short fixed diagnostic; never user data.
    public var message: String?

    public init(
      _ code: RSTErrorCode,
      sequence: UInt64? = nil,
      message: String? = nil
    ) {
      self.code = code
      self.sequence = sequence
      self.message = message.map { String($0.prefix(200)) }
    }
  }

  public var typeName: String {
    switch self {
    case .attach: "Attach"
    case .attached: "Attached"
    case .input: "Input"
    case .inputAck: "InputAck"
    case .screenAck: "ScreenAck"
    case .ping: "Ping"
    case .pong: "Pong"
    case .detach: "Detach"
    case .detached: "Detached"
    case .terminate: "Terminate"
    case .terminated: "Terminated"
    case .sessionExited: "SessionExited"
    case .error: "Error"
    }
  }

  /// The epoch a post-attachment message is scoped to.
  public var epoch: UInt64? {
    switch self {
    case .attach, .error: nil
    case let .attached(a): a.attachmentEpoch
    case let .input(i): i.attachmentEpoch
    case let .inputAck(e, _), let .screenAck(e, _), let .ping(e, _),
      let .pong(e, _), let .detach(e), let .detached(e), let .terminate(e),
      let .terminated(e), let .sessionExited(e, _, _):
      e
    }
  }
}

extension ControlMessage: Codable {
  enum Keys: String, CodingKey {
    case type, sessionID, serverInstanceID, writerID, applicationToken,
      attachmentEpoch, lastFullyAppliedInputSequence, partialInputSequence,
      resizeRevision, sequence, operation, screenRevision, nonce, status,
      finalScreenRevision, code, message, features
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    func u64(_ key: Keys) throws -> UInt64 {
      try c.decode(WireUInt64.self, forKey: key).value
    }
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "Attach":
      self = .attach(
        Attach(
          sessionID: try c.decode(SessionID.self, forKey: .sessionID),
          serverInstanceID: try c.decode(
            ServerInstanceID.self,
            forKey: .serverInstanceID
          ),
          writerID: try c.decode(WriterID.self, forKey: .writerID),
          applicationToken: try c.decode(
            ApplicationToken.self,
            forKey: .applicationToken
          )
        )
      )
    case "Attached":
      self = .attached(
        Attached(
          attachmentEpoch: try u64(.attachmentEpoch),
          writerID: try c.decode(WriterID.self, forKey: .writerID),
          lastFullyAppliedInputSequence: try u64(
            .lastFullyAppliedInputSequence
          ),
          partialInputSequence: try c.decodeIfPresent(
            WireUInt64.self,
            forKey: .partialInputSequence
          )?
          .value,
          resizeRevision: try u64(.resizeRevision),
          features: RSTFeatures(
            names: try c.decodeIfPresent([String].self, forKey: .features) ?? []
          )
        )
      )
    case "Input":
      self = .input(
        Input(
          attachmentEpoch: try u64(.attachmentEpoch),
          sequence: try u64(.sequence),
          operation: try c.decode(InputOperation.self, forKey: .operation)
        )
      )
    case "InputAck":
      self = .inputAck(
        epoch: try u64(.attachmentEpoch),
        sequence: try u64(.sequence)
      )
    case "ScreenAck":
      self = .screenAck(
        epoch: try u64(.attachmentEpoch),
        screenRevision: try u64(.screenRevision)
      )
    case "Ping":
      self = .ping(epoch: try u64(.attachmentEpoch), nonce: try u64(.nonce))
    case "Pong":
      self = .pong(epoch: try u64(.attachmentEpoch), nonce: try u64(.nonce))
    case "Detach": self = .detach(epoch: try u64(.attachmentEpoch))
    case "Detached": self = .detached(epoch: try u64(.attachmentEpoch))
    case "Terminate": self = .terminate(epoch: try u64(.attachmentEpoch))
    case "Terminated": self = .terminated(epoch: try u64(.attachmentEpoch))
    case "SessionExited":
      self = .sessionExited(
        epoch: try u64(.attachmentEpoch),
        status: try c.decode(Int32.self, forKey: .status),
        finalScreenRevision: try u64(.finalScreenRevision)
      )
    case "Error":
      let message = try c.decodeIfPresent(String.self, forKey: .message)
      guard (message?.utf8.count ?? 0) <= 1024 else {
        throw DecodingError.dataCorruptedError(
          forKey: .message,
          in: c,
          debugDescription: "message too long"
        )
      }
      self = .error(
        RSTError(
          try c.decode(RSTErrorCode.self, forKey: .code),
          sequence: try c.decodeIfPresent(WireUInt64.self, forKey: .sequence)?
            .value,
          message: message
        )
      )
    default:
      // Unknown message types are rejected in version 1.
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: c,
        debugDescription: "unknown message type"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(typeName, forKey: .type)
    func u64(_ value: UInt64, _ key: Keys) throws {
      try c.encode(WireUInt64(value), forKey: key)
    }
    switch self {
    case let .attach(a):
      try c.encode(a.sessionID, forKey: .sessionID)
      try c.encode(a.serverInstanceID, forKey: .serverInstanceID)
      try c.encode(a.writerID, forKey: .writerID)
      try c.encode(a.applicationToken, forKey: .applicationToken)
    case let .attached(a):
      try u64(a.attachmentEpoch, .attachmentEpoch)
      try c.encode(a.writerID, forKey: .writerID)
      try u64(a.lastFullyAppliedInputSequence, .lastFullyAppliedInputSequence)
      if let p = a.partialInputSequence { try u64(p, .partialInputSequence) }
      try u64(a.resizeRevision, .resizeRevision)
      if !a.features.isEmpty {
        try c.encode(a.features.names, forKey: .features)
      }
    case let .input(i):
      try u64(i.attachmentEpoch, .attachmentEpoch)
      try u64(i.sequence, .sequence)
      try c.encode(i.operation, forKey: .operation)
    case let .inputAck(e, s):
      try u64(e, .attachmentEpoch)
      try u64(s, .sequence)
    case let .screenAck(e, r):
      try u64(e, .attachmentEpoch)
      try u64(r, .screenRevision)
    case let .ping(e, n), let .pong(e, n):
      try u64(e, .attachmentEpoch)
      try u64(n, .nonce)
    case let .detach(e), let .detached(e), let .terminate(e),
      let .terminated(e):
      try u64(e, .attachmentEpoch)
    case let .sessionExited(e, status, revision):
      try u64(e, .attachmentEpoch)
      try c.encode(status, forKey: .status)
      try u64(revision, .finalScreenRevision)
    case let .error(error):
      try c.encode(error.code, forKey: .code)
      if let s = error.sequence { try u64(s, .sequence) }
      try c.encodeIfPresent(error.message, forKey: .message)
    }
  }
}

/// Additive RST/1 behaviour a host advertises in `Attached`. Older peers
/// ignore the field; names this build does not know are ignored.
public struct RSTFeatures: OptionSet, Hashable, Sendable {
  public var rawValue: UInt32
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  /// `kp:<key>` key names. Clients send the main-keyboard key without it.
  public static let keypadKeys = RSTFeatures(rawValue: 1 << 0)

  public static let supported: RSTFeatures = [.keypadKeys]

  private static let wireNames: [(String, RSTFeatures)] = [
    ("keypadKeys", .keypadKeys)
  ]

  init(names: [String]) {
    self = Self.wireNames.reduce(into: []) { result, entry in
      if names.contains(entry.0) { result.insert(entry.1) }
    }
  }

  var names: [String] {
    Self.wireNames.compactMap { contains($0.1) ? $0.0 : nil }
  }
}
