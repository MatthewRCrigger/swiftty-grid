import Foundation

/// iPhone-side companion core: holds the latest state the iPhone itself
/// observed and answers watch requests from it.
///
/// This is a pure value type; the WatchConnectivity adapter in
/// `Apps/MobileClient` owns one behind a lock. Its contract
/// (spec.roaming.md §2.3, §A.3.D):
///
/// - Replies carry the latest *observed* state with its original capture
///   time. Answering never advances `capturedAt`, never claims the Mac was
///   polled, and has no hook that could start an SSH login, an RST
///   reattachment, or background work.
/// - Preview text is retained in memory only, only while opted in and in
///   the foreground, and is only ever returned as an immediate reply. It
///   is not representable in `CompanionApplicationContext`.
/// - Turning sharing off clears every cached observation and produces a
///   `.cleared` context so the watch drops its cache too.
public struct PhoneCompanionBridge: Sendable {
  /// One iPhone observation of the explicitly selected session.
  public struct Observation: Hashable, Sendable {
    /// Local identity of the selected session; never sent to the watch.
    /// A change discards any cached preview from the previous session.
    public var sessionToken: UUID?
    public var nickname: String?
    public var state: CompanionConnectionState
    /// When the iPhone observed `state`.
    public var observedAt: Date
    public var lastScreenAt: Date?
    public var pendingInputCount: Int

    public init(
      sessionToken: UUID?,
      nickname: String?,
      state: CompanionConnectionState,
      observedAt: Date,
      lastScreenAt: Date? = nil,
      pendingInputCount: Int = 0
    ) {
      self.sessionToken = sessionToken
      self.nickname = nickname
      self.state = state
      self.observedAt = observedAt
      self.lastScreenAt = lastScreenAt
      self.pendingInputCount = pendingInputCount
    }
  }

  public private(set) var settings: CompanionSettings
  public private(set) var isForeground: Bool
  private var observation: Observation
  private var cachedPreview: CompanionPreview?
  /// When sharing was last turned off; reported in `.disabled` replies.
  private var clearedAt: Date

  /// Starts with "no session" observed at `now`.
  public init(settings: CompanionSettings = .default, isForeground: Bool = false, now: Date) {
    self.settings = settings
    self.isForeground = isForeground
    self.observation = Observation(
      sessionToken: nil,
      nickname: nil,
      state: .noSession,
      observedAt: now
    )
    self.clearedAt = now
  }

  /// The latest observed status, or `nil` while sharing is off.
  public var status: CompanionStatus? {
    guard settings.sharingEnabled else { return nil }
    return CompanionStatus(
      sessionNickname: observation.nickname,
      state: observation.state,
      capturedAt: observation.observedAt,
      lastScreenAt: observation.lastScreenAt,
      pendingInputCount: observation.pendingInputCount,
      previewAvailable: settings.allowsPreview
    )
  }

  /// Whether a preview is currently cached (for tests and diagnostics).
  public var hasCachedPreview: Bool { cachedPreview != nil }

  /// The context to publish with `updateApplicationContext`.
  public var applicationContext: CompanionApplicationContext {
    status.map(CompanionApplicationContext.status) ?? .cleared(at: clearedAt)
  }

  /// Records an observation. Returns the context to publish, or `nil` when
  /// nothing should be sent (sharing off, or an out-of-order observation
  /// older than the one already held).
  public mutating func observe(_ next: Observation) -> CompanionApplicationContext? {
    guard settings.sharingEnabled else { return nil }
    guard next.observedAt >= observation.observedAt else { return nil }
    if next.sessionToken != observation.sessionToken { cachedPreview = nil }
    observation = next
    return applicationContext
  }

  /// Caches the latest screen text for an on-request preview. Ignored
  /// unless the user opted in and the app is in the foreground.
  public mutating func observePreview(lines: [String], capturedAt: Date) {
    guard settings.allowsPreview, isForeground else { return }
    if let cachedPreview, cachedPreview.capturedAt > capturedAt { return }
    cachedPreview = CompanionPreview(lines: lines, capturedAt: capturedAt)
  }

  /// Drops cached preview text (for example when the terminal is hidden).
  public mutating func clearPreview() { cachedPreview = nil }

  /// Scene lifecycle. Leaving the foreground clears preview text.
  public mutating func setForeground(_ foreground: Bool) {
    isForeground = foreground
    if !foreground { cachedPreview = nil }
  }

  /// Applies new settings. Returns the context to publish when it changed.
  /// Turning sharing off clears all cached companion data and yields
  /// `.cleared`, which tells the watch to clear its cache as well.
  public mutating func update(
    _ newSettings: CompanionSettings,
    now: Date
  ) -> CompanionApplicationContext? {
    let old = settings
    settings = newSettings
    if !newSettings.allowsPreview { cachedPreview = nil }
    if old.sharingEnabled, !newSettings.sharingEnabled {
      observation = Observation(
        sessionToken: nil,
        nickname: nil,
        state: .noSession,
        observedAt: max(now, observation.observedAt)
      )
      cachedPreview = nil
      clearedAt = now
      return .cleared(at: now)
    }
    return old == newSettings ? nil : applicationContext
  }

  /// Answers one watch request from cached state only.
  public func reply(to request: CompanionRequest) -> CompanionReply {
    guard let status else { return .disabled(request.id, clearedAt: clearedAt) }
    switch request.kind {
    case .refresh:
      return .status(request.id, status, previewUnavailable: nil)
    case .preview:
      guard settings.allowsPreview else {
        return .status(request.id, status, previewUnavailable: .notEnabled)
      }
      guard isForeground else {
        return .status(request.id, status, previewUnavailable: .phoneNotForeground)
      }
      guard let cachedPreview else {
        return .status(request.id, status, previewUnavailable: .noScreen)
      }
      return .preview(request.id, status, cachedPreview)
    }
  }

  /// Decodes a request and encodes its reply. Returns `nil` for a
  /// malformed request, which the adapter answers with an error instead.
  public func reply(toMessageData data: Data) -> Data? {
    guard let request = try? CompanionCodec.decodeRequest(data) else { return nil }
    let reply = reply(to: request)
    if let encoded = try? CompanionCodec.encode(reply) { return encoded }
    // A preview reply that cannot be encoded within bounds degrades to
    // status only rather than failing the request.
    guard let status else { return nil }
    return try? CompanionCodec.encode(
      CompanionReply.status(request.id, status, previewUnavailable: .noScreen)
    )
  }
}
