import Foundation

/// Connection state as the iPhone last observed it. Mirrors the
/// direct-client state machine (spec.roaming.md §9) without depending on
/// SessionCore, plus `noSession` for "nothing selected for the watch".
public enum CompanionConnectionState: String, Hashable, Sendable, Codable,
  CaseIterable
{
  case noSession
  case idle
  case sshBootstrap
  case attaching
  case active
  case suspect
  case reconnecting
  case backgroundDetached
  case sessionExited
  case sessionLost
  case userClosed

  /// Short user-facing description. Never implies the Mac was polled.
  public var summary: String {
    switch self {
    case .noSession: "No session selected"
    case .idle: "Not connected"
    case .sshBootstrap: "Signing in"
    case .attaching: "Attaching"
    case .active: "Attached"
    case .suspect: "Connection uncertain"
    case .reconnecting: "Reconnecting"
    case .backgroundDetached: "Detached (iPhone in background)"
    case .sessionExited: "Session exited"
    case .sessionLost: "Session lost"
    case .userClosed: "Closed"
    }
  }
}

/// Non-sensitive, timestamped session status for the watch.
///
/// Deliberately contains no terminal text, window titles, host names,
/// usernames, tokens, credentials, or commands. The only free text is the
/// nickname the user chose for the session on the iPhone.
public struct CompanionStatus: Hashable, Sendable {
  /// Nickname chosen by the user; sanitized and bounded.
  public let sessionNickname: String?
  public let state: CompanionConnectionState
  /// When the iPhone observed `state`. Never later than that observation.
  public let capturedAt: Date
  /// When the iPhone last received a screen from the host, if ever.
  /// Never later than `capturedAt`.
  public let lastScreenAt: Date?
  /// Input operations the iPhone submitted but the host has not yet
  /// acknowledged (spec §8: shown explicitly, never hidden).
  public let pendingInputCount: Int
  /// Whether the phone currently allows an on-request text preview.
  public let previewAvailable: Bool
  /// Opaque preview ownership. It changes when the selected session
  /// changes and is not a host or session token. Cached preview text
  /// belongs only to this id.
  public let previewOwner: UInt64

  /// Builds a status, sanitizing and clamping every field.
  public init(
    sessionNickname: String?,
    state: CompanionConnectionState,
    capturedAt: Date,
    lastScreenAt: Date? = nil,
    pendingInputCount: Int = 0,
    previewAvailable: Bool = false,
    previewOwner: UInt64 = 0
  ) {
    let nickname = sessionNickname.map {
      CompanionText.bounded(
        $0,
        characters: CompanionLimits.maxNicknameCharacters,
        bytes: CompanionLimits.maxNicknameBytes
      )
    }
    self.sessionNickname = nickname?.isEmpty == false ? nickname : nil
    self.state = state
    self.capturedAt = capturedAt
    self.lastScreenAt = lastScreenAt.map { min($0, capturedAt) }
    self.pendingInputCount = min(
      max(0, pendingInputCount),
      CompanionLimits.maxPendingInputCount
    )
    self.previewAvailable = previewAvailable
    self.previewOwner = previewOwner
  }

  /// "Nothing to show" status captured at `date`.
  public static func noSession(at date: Date) -> CompanionStatus {
    CompanionStatus(sessionNickname: nil, state: .noSession, capturedAt: date)
  }
}

extension CompanionStatus: Codable {
  enum CodingKeys: String, CodingKey, CaseIterable {
    case sessionNickname = "nickname"
    case state
    case capturedAt
    case lastScreenAt
    case pendingInputCount = "pendingInput"
    case previewAvailable
    case previewOwner
  }

  public init(from decoder: any Decoder) throws {
    try StrictKeys.check(decoder, allowed: CodingKeys.self)
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let rawNickname = try c.decodeIfPresent(
      String.self,
      forKey: .sessionNickname
    )
    let nickname = rawNickname.map(CompanionText.stripControls)
    if let nickname,
      !CompanionText.isValid(
        nickname,
        characters: CompanionLimits.maxNicknameCharacters,
        bytes: CompanionLimits.maxNicknameBytes
      )
    {
      throw CompanionCodecError.invalid("nickname exceeds bounds")
    }
    let state = try c.decode(CompanionConnectionState.self, forKey: .state)
    let capturedAt = try CompanionTime.decode(c, .capturedAt)
    let lastScreenAt = try CompanionTime.decodeIfPresent(c, .lastScreenAt)
    if let lastScreenAt, lastScreenAt > capturedAt {
      throw CompanionCodecError.invalid("lastScreenAt after capturedAt")
    }
    let pending = try c.decode(Int.self, forKey: .pendingInputCount)
    guard (0 ... CompanionLimits.maxPendingInputCount).contains(pending) else {
      throw CompanionCodecError.invalid("pendingInput out of range")
    }
    self.init(
      sessionNickname: nickname,
      state: state,
      capturedAt: capturedAt,
      lastScreenAt: lastScreenAt,
      pendingInputCount: pending,
      previewAvailable: try c.decode(Bool.self, forKey: .previewAvailable),
      previewOwner: try c.decode(UInt64.self, forKey: .previewOwner)
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(sessionNickname, forKey: .sessionNickname)
    try c.encode(state, forKey: .state)
    try c.encode(CompanionTime.wire(capturedAt), forKey: .capturedAt)
    try c.encodeIfPresent(
      lastScreenAt.map(CompanionTime.wire),
      forKey: .lastScreenAt
    )
    try c.encode(pendingInputCount, forKey: .pendingInputCount)
    try c.encode(previewAvailable, forKey: .previewAvailable)
    try c.encode(previewOwner, forKey: .previewOwner)
  }
}

/// An opt-in, bounded, in-memory-only text preview of the iPhone's latest
/// observed screen. Only ever delivered as an immediate foreground reply;
/// `CompanionApplicationContext` cannot carry it.
public struct CompanionPreview: Hashable, Sendable {
  /// Sanitized display lines, at most `CompanionLimits.maxPreviewLines`.
  public let lines: [String]
  /// When the iPhone observed this screen content.
  public let capturedAt: Date
  /// `CompanionStatus.previewOwner` for the selection these lines belong
  /// to. It is not a host or session token.
  public let owner: UInt64

  /// Builds a preview from raw screen rows: strips controls, truncates
  /// each row, keeps the bottom-most rows that fit the line and byte
  /// budgets, and drops trailing blank rows.
  public init(lines raw: [String], capturedAt: Date, owner: UInt64 = 0) {
    var rows = raw.suffix(CompanionLimits.maxPreviewLines * 4)
      .map {
        CompanionText.bounded(
          $0,
          characters: CompanionLimits.maxPreviewColumns,
          bytes: CompanionLimits.maxPreviewLineBytes
        )
      }
    while let last = rows.last, last.allSatisfy(\.isWhitespace) {
      rows.removeLast()
    }
    var kept: [String] = []
    var bytes = 0
    for row in rows.reversed() {
      guard kept.count < CompanionLimits.maxPreviewLines,
        bytes + row.utf8.count <= CompanionLimits.maxPreviewTextBytes
      else { break }
      kept.append(row)
      bytes += row.utf8.count
    }
    self.lines = kept.reversed()
    self.capturedAt = capturedAt
    self.owner = owner
  }
}

extension CompanionPreview: Codable {
  enum CodingKeys: String, CodingKey, CaseIterable {
    case lines
    case capturedAt
    case owner
  }

  public init(from decoder: any Decoder) throws {
    try StrictKeys.check(decoder, allowed: CodingKeys.self)
    let c = try decoder.container(keyedBy: CodingKeys.self)
    var linesContainer = try c.nestedUnkeyedContainer(forKey: .lines)
    if let count = linesContainer.count, count > CompanionLimits.maxPreviewLines
    {
      throw CompanionCodecError.invalid("too many preview lines")
    }
    var lines: [String] = []
    var bytes = 0
    while !linesContainer.isAtEnd {
      guard lines.count < CompanionLimits.maxPreviewLines else {
        throw CompanionCodecError.invalid("too many preview lines")
      }
      let line = CompanionText.stripControls(
        try linesContainer.decode(String.self)
      )
      guard
        CompanionText.isValid(
          line,
          characters: CompanionLimits.maxPreviewColumns,
          bytes: CompanionLimits.maxPreviewLineBytes
        )
      else { throw CompanionCodecError.invalid("preview line exceeds bounds") }
      bytes += line.utf8.count
      guard bytes <= CompanionLimits.maxPreviewTextBytes else {
        throw CompanionCodecError.invalid("preview text exceeds bounds")
      }
      lines.append(line)
    }
    self.lines = lines
    self.capturedAt = try CompanionTime.decode(c, .capturedAt)
    self.owner = try c.decode(UInt64.self, forKey: .owner)
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(lines, forKey: .lines)
    try c.encode(CompanionTime.wire(capturedAt), forKey: .capturedAt)
    try c.encode(owner, forKey: .owner)
  }
}

/// Wire timestamps: finite seconds since 1970 with millisecond precision.
enum CompanionTime {
  /// 2000-01-01 ... 2200-01-01; anything else is malformed.
  static let range: ClosedRange<Double> = 946_684_800 ... 7_258_118_400

  static func wire(_ date: Date) -> Double {
    (date.timeIntervalSince1970 * 1000).rounded(.down) / 1000
  }

  static func decode<K: CodingKey>(
    _ c: KeyedDecodingContainer<K>,
    _ key: K
  ) throws -> Date {
    let seconds = try c.decode(Double.self, forKey: key)
    guard seconds.isFinite, range.contains(seconds) else {
      throw CompanionCodecError.invalid("timestamp out of range")
    }
    return Date(timeIntervalSince1970: seconds)
  }

  static func decodeIfPresent<K: CodingKey>(
    _ c: KeyedDecodingContainer<K>,
    _ key: K
  ) throws -> Date? {
    guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
    return try decode(c, key)
  }
}

/// Rejects objects carrying keys outside a closed set. The companion model
/// is strict: an unexpected field (for example preview text smuggled into
/// a status) is a malformed payload, not an ignorable extension.
enum StrictKeys {
  struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  static func check<K: CodingKey & CaseIterable>(
    _ decoder: any Decoder,
    allowed: K.Type
  ) throws {
    let names = Set(K.allCases.map(\.stringValue))
    let c = try decoder.container(keyedBy: AnyKey.self)
    for key in c.allKeys where !names.contains(key.stringValue) {
      throw CompanionCodecError.invalid("unexpected field")
    }
  }
}
