import Foundation
import SessionCore

public struct GridSize: Hashable, Sendable, Codable {
  public var columns: Int
  public var rows: Int

  public init(columns: Int, rows: Int) {
    self.columns = columns
    self.rows = rows
  }

  public var isValid: Bool {
    (1 ... RSTLimits.maxColumns).contains(columns)
      && (1 ... RSTLimits.maxRows).contains(rows)
  }
}

/// Request sent on stdin of `swifttyd bootstrap --stdio` (spec §5.1).
/// Contains no shell commands, paths or passwords.
public struct BootstrapRequest: Hashable, Sendable, Codable {
  public enum Operation: String, Hashable, Sendable, Codable {
    case create, resume, list, terminate
  }

  public var operation: Operation
  /// Protocol versions the client supports, e.g. `["RST/1"]`.
  public var protocols: [String]
  public var sessionID: SessionID?
  /// For `resume` by a still-running client: keep its writer identity
  /// so retained operations can be retried. Omitted after a cold start.
  public var writerID: WriterID?
  public var initialGrid: GridSize?
  /// For `resume`: the user confirmed taking control of a workspace
  /// another frontend (for example the Mac app) is attached to. Without
  /// it, attaching to a held workspace fails with `writerBusy`.
  public var takeover: Bool?

  public init(
    operation: Operation,
    protocols: [String] = [RSTLimits.protocolName],
    sessionID: SessionID? = nil,
    writerID: WriterID? = nil,
    initialGrid: GridSize? = nil,
    takeover: Bool? = nil
  ) {
    self.operation = operation
    self.protocols = protocols
    self.sessionID = sessionID
    self.writerID = writerID
    self.initialGrid = initialGrid
    self.takeover = takeover
  }

  public enum ValidationError: Error, Equatable {
    case unsupportedProtocol, missingSession, invalidGrid, tooManyProtocols
  }

  public func validate() throws(ValidationError) {
    guard protocols.count <= 8 else { throw .tooManyProtocols }
    guard protocols.contains(RSTLimits.protocolName) else {
      throw .unsupportedProtocol
    }
    switch operation {
    case .create:
      guard let grid = initialGrid, grid.isValid else { throw .invalidGrid }
    case .resume:
      guard sessionID != nil else { throw .missingSession }
      if let grid = initialGrid, !grid.isValid { throw .invalidGrid }
    case .terminate:
      guard sessionID != nil else { throw .missingSession }
    case .list: break
    }
  }
}

public struct NegotiatedLimits: Hashable, Sendable, Codable {
  public var maxColumns = RSTLimits.maxColumns
  public var maxRows = RSTLimits.maxRows
  public var maxControlRecordBytes = RSTLimits.maxControlRecordBytes
  public var maxSnapshotEncodedBytes = RSTLimits.maxSnapshotEncodedBytes
  public var maxSnapshotDecodedBytes = RSTLimits.maxSnapshotDecodedBytes
  public var maxPendingInputBytes = RSTLimits.maxPendingInputBytes
  public var maxPasteBytes = RSTLimits.maxPasteBytes
  public init() {}
}

/// Approved QUIC endpoint for the attachment.
public struct BootstrapEndpoint: Hashable, Sendable, Codable {
  public var host: String
  public var port: UInt16
  public init(host: String, port: UInt16) {
    self.host = host
    self.port = port
  }
}

/// Successful create/resume response (spec §5.2). Carries a bearer
/// capability: never log or persist it.
public struct BootstrapGrant: Hashable, Sendable, Codable,
  CustomStringConvertible
{
  public var `protocol`: String
  public var serverInstanceID: ServerInstanceID
  public var sessionID: SessionID
  public var writerID: WriterID
  public var endpoint: BootstrapEndpoint
  /// Base64 DER on the wire.
  public var serverCertificateDER: Data
  /// Lowercase hex SHA-256 of `serverCertificateDER`.
  public var serverCertificateSHA256: String
  /// The QUIC pin: lowercase hex SHA-256 of the certificate's DER
  /// SubjectPublicKeyInfo. Optional on the wire for older hosts; this host
  /// always sets it. When present it must be 64 lowercase hex digits and
  /// the client verifies it in the TLS handshake, before the token is sent.
  public var serverSPKISHA256: String?
  public var applicationToken: ApplicationToken
  /// Seconds since 1970.
  public var tokenExpiresAt: Double
  public var initialGrid: GridSize
  public var limits: NegotiatedLimits

  public init(
    serverInstanceID: ServerInstanceID,
    sessionID: SessionID,
    writerID: WriterID,
    endpoint: BootstrapEndpoint,
    serverCertificateDER: Data,
    serverCertificateSHA256: String,
    serverSPKISHA256: String? = nil,
    applicationToken: ApplicationToken,
    tokenExpiresAt: Double,
    initialGrid: GridSize,
    limits: NegotiatedLimits = NegotiatedLimits()
  ) {
    self.protocol = RSTLimits.protocolName
    self.serverInstanceID = serverInstanceID
    self.sessionID = sessionID
    self.writerID = writerID
    self.endpoint = endpoint
    self.serverCertificateDER = serverCertificateDER
    self.serverCertificateSHA256 = serverCertificateSHA256
    self.serverSPKISHA256 = serverSPKISHA256
    self.applicationToken = applicationToken
    self.tokenExpiresAt = tokenExpiresAt
    self.initialGrid = initialGrid
    self.limits = limits
  }

  public var description: String {
    "BootstrapGrant(session: \(sessionID), endpoint: \(endpoint.host):\(endpoint.port))"
  }
}

public struct SessionSummary: Hashable, Sendable, Codable {
  public enum State: String, Hashable, Sendable, Codable {
    case reserved, attached, detached, exited
  }

  public var sessionID: SessionID
  public var state: State
  public var columns: Int
  public var rows: Int
  /// Seconds since 1970.
  public var lastActivity: Double
  public var exitStatus: Int32?

  public init(
    sessionID: SessionID,
    state: State,
    columns: Int,
    rows: Int,
    lastActivity: Double,
    exitStatus: Int32? = nil
  ) {
    self.sessionID = sessionID
    self.state = state
    self.columns = columns
    self.rows = rows
    self.lastActivity = lastActivity
    self.exitStatus = exitStatus
  }
}

public enum BootstrapErrorCode: String, Hashable, Sendable, Codable, Error {
  case malformed
  case unsupportedVersion
  case agentUnavailable
  case sessionLimit
  case unknownSession
  /// Another writer still has admitted input that has not completed.
  case writerBusy
  case sessionExited
  case internalError
}

public enum BootstrapResponse: Hashable, Sendable {
  case granted(BootstrapGrant)
  case sessions([SessionSummary])
  case terminated(SessionID)
  case failure(BootstrapErrorCode)
}

extension BootstrapResponse: Codable {
  enum Keys: String, CodingKey { case result, grant, sessions, sessionID, error }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    switch try c.decode(String.self, forKey: .result) {
    case "granted": self = .granted(try c.decode(BootstrapGrant.self, forKey: .grant))
    case "sessions":
      let list = try c.decode([SessionSummary].self, forKey: .sessions)
      guard list.count <= RSTLimits.maxSessionsPerAccount else {
        throw DecodingError.dataCorruptedError(
          forKey: .sessions,
          in: c,
          debugDescription: "too many sessions"
        )
      }
      self = .sessions(list)
    case "terminated":
      self = .terminated(try c.decode(SessionID.self, forKey: .sessionID))
    case "error":
      self = .failure(try c.decode(BootstrapErrorCode.self, forKey: .error))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .result,
        in: c,
        debugDescription: "unknown result"
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    switch self {
    case let .granted(grant):
      try c.encode("granted", forKey: .result)
      try c.encode(grant, forKey: .grant)
    case let .sessions(list):
      try c.encode("sessions", forKey: .result)
      try c.encode(list, forKey: .sessions)
    case let .terminated(id):
      try c.encode("terminated", forKey: .result)
      try c.encode(id, forKey: .sessionID)
    case let .failure(code):
      try c.encode("error", forKey: .result)
      try c.encode(code, forKey: .error)
    }
  }
}

/// Bounded `UInt32BE(length)` + JSON envelope for bootstrap stdin/stdout.
/// Unexpected stdout bytes are a protocol error.
public enum BootstrapEnvelope {
  public static func encode(_ value: some Encodable) throws -> [UInt8] {
    let json = try makeEncoder().encode(value)
    guard json.count <= RSTLimits.maxBootstrapEnvelopeBytes else {
      throw FramingError.recordTooLarge(json.count)
    }
    var out = [UInt8]()
    appendUInt32(UInt32(json.count), to: &out)
    out.append(contentsOf: json)
    return out
  }

  /// Decodes exactly one envelope; trailing bytes are rejected.
  public static func decode<T: Decodable>(
    _ type: T.Type,
    from bytes: [UInt8]
  ) throws(FramingError) -> T {
    guard bytes.count >= 4 else { throw .truncated }
    let length = Int(readUInt32(bytes, at: 0))
    guard length <= RSTLimits.maxBootstrapEnvelopeBytes else {
      throw .recordTooLarge(length)
    }
    guard bytes.count >= 4 + length else { throw .truncated }
    guard bytes.count == 4 + length else { throw .trailingData }
    do {
      return try JSONDecoder().decode(T.self, from: Data(bytes[4...]))
    } catch {
      throw .malformedJSON
    }
  }

  /// Length of the envelope once its prefix is available, bounded.
  public static func expectedLength(
    _ prefix: [UInt8]
  ) throws(FramingError) -> Int? {
    guard prefix.count >= 4 else { return nil }
    let length = Int(readUInt32(prefix, at: 0))
    guard length <= RSTLimits.maxBootstrapEnvelopeBytes else {
      throw .recordTooLarge(length)
    }
    return 4 + length
  }
}
