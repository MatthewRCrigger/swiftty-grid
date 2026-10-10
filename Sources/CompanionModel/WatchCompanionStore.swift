import Foundation

/// Watch-side companion state: cached status, an optional in-memory
/// preview, reachability, and the single pending refresh.
///
/// A pure value type owned by the watch app's `@MainActor` model. It
/// offers no operation that reaches a host: the only outbound values are
/// `CompanionRequest`s (refresh/preview), which carry no input, command,
/// credential, or attachment capability.
public struct WatchCompanionStore: Sendable {
  /// What the watch UI should render. Always carries the capture time and
  /// an explicit freshness; nothing here can read as "live".
  public struct Presentation: Hashable, Sendable {
    public var nickname: String?
    public var state: CompanionConnectionState?
    public var capturedAt: Date?
    public var lastScreenAt: Date?
    public var pendingInputCount: Int
    public var freshness: CompanionFreshness
    public var phoneReachable: Bool
    public var refreshing: Bool
    public var lastRefreshFailed: Bool
    public var previewAvailable: Bool
    public var preview: CompanionPreview?
  }

  public private(set) var status: CompanionStatus?
  /// In memory only; cleared whenever the app is not active.
  public private(set) var preview: CompanionPreview?
  public private(set) var isReachable = false
  public private(set) var isActive = false
  public private(set) var gate: RefreshGate
  public private(set) var lastRefreshFailedAt: Date?
  public var staleness: CompanionStaleness

  public init(
    staleness: CompanionStaleness = .standard,
    gate: RefreshGate = RefreshGate()
  ) {
    self.staleness = staleness
    self.gate = gate
  }

  // MARK: Lifecycle

  /// Scene phase. Becoming inactive or backgrounded clears preview text
  /// and abandons any pending preview request.
  public mutating func setActive(_ active: Bool) {
    isActive = active
    if !active {
      preview = nil
      if gate.pending?.request.kind == .preview { gate.cancel() }
    }
  }

  public mutating func setReachable(_ reachable: Bool) {
    isReachable = reachable
  }

  // MARK: Requests

  /// Starts a request, or returns `nil` when one is already pending, the
  /// phone is unreachable, or the app is not active. A preview is only
  /// requested when the phone advertised that previews are enabled.
  public mutating func beginRequest(
    _ kind: CompanionRequest.Kind,
    now: Date
  ) -> CompanionRequest? {
    guard isActive, isReachable else { return nil }
    let kind: CompanionRequest.Kind =
      kind == .preview && status?.previewAvailable == true ? .preview : .refresh
    return gate.begin(kind, now: now)
  }

  /// The transport could not deliver the request or got no reply.
  public mutating func requestFailed(_ id: CompanionRequestID, now: Date) {
    if gate.complete(id) { lastRefreshFailedAt = now }
  }

  /// Abandons a request that exceeded its timeout.
  public mutating func tick(now: Date) {
    if gate.expireIfNeeded(now: now) { lastRefreshFailedAt = now }
  }

  // MARK: Incoming

  /// Applies a reply. Only the reply to the pending request is accepted.
  @discardableResult
  public mutating func receive(_ reply: CompanionReply) -> Bool {
    guard gate.complete(reply.requestID) else { return false }
    lastRefreshFailedAt = nil
    switch reply {
    case .status(_, let status, _):
      apply(status)
    case .preview(_, let status, let newPreview):
      apply(status)
      if isActive, self.status?.previewAvailable == true,
        preview.map({ $0.capturedAt <= newPreview.capturedAt }) ?? true
      {
        preview = newPreview
      }
    case .disabled:
      clearAll()
    }
    return true
  }

  /// Decodes and applies a reply; malformed data is rejected.
  @discardableResult
  public mutating func receive(replyData data: Data) -> Bool {
    guard let reply = try? CompanionCodec.decodeReply(data) else { return false }
    return receive(reply)
  }

  /// Applies a latest-state application context.
  public mutating func receive(_ context: CompanionApplicationContext) {
    switch context {
    case .status(let status): apply(status)
    case .cleared: clearAll()
    }
  }

  /// Drops every cached value (phone-side opt-out).
  public mutating func clearAll() {
    status = nil
    preview = nil
    gate.cancel()
  }

  /// Keeps the newest status; an older one never overwrites it.
  private mutating func apply(_ incoming: CompanionStatus) {
    if let status, incoming.capturedAt < status.capturedAt { return }
    status = incoming
    if !incoming.previewAvailable { preview = nil }
  }

  // MARK: Presentation

  public func freshness(now: Date) -> CompanionFreshness {
    staleness.evaluate(status, now: now)
  }

  public func presentation(now: Date) -> Presentation {
    Presentation(
      nickname: status?.sessionNickname,
      state: status?.state,
      capturedAt: status?.capturedAt,
      lastScreenAt: status?.lastScreenAt,
      pendingInputCount: status?.pendingInputCount ?? 0,
      freshness: freshness(now: now),
      phoneReachable: isReachable,
      refreshing: gate.isPending,
      lastRefreshFailed: lastRefreshFailedAt != nil,
      previewAvailable: status?.previewAvailable ?? false,
      preview: isActive ? preview : nil
    )
  }
}
