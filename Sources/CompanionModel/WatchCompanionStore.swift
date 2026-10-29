import Foundation

/// Watch-side companion state: cached status, an optional in-memory
/// preview, reachability, and the single pending refresh.
///
/// A pure value type owned by the watch app's `@MainActor` model. It
/// offers no operation that reaches a host: the only outbound values are
/// `CompanionRequest`s (refresh/preview), which carry no input, command,
/// credential, or attachment capability.
public struct WatchCompanionStore: Equatable, Sendable {
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
  /// Owner of `preview`. Nil when no preview is retained. A status whose
  /// owner differs cannot keep this text.
  private var retainedPreviewOwner: UInt64?
  public private(set) var isReachable = false
  public private(set) var isActive = false
  public private(set) var gate: RefreshGate
  public private(set) var lastRefreshFailedAt: Date?
  public var staleness: CompanionStaleness
  /// Kept after clearing, so a delayed publication cannot restore data.
  public private(set) var lastPublicationRevision: UInt64?
  private var lastContextRevision: UInt64?
  public private(set) var publisherID: UUID?
  /// An unfamiliar publisher requires a fresh immediate request. Queued
  /// contexts alone cannot establish order between installations.
  public private(set) var needsPublisherConfirmation = false
  public private(set) var confirmationPublisherID: UUID?
  private var confirmingRequestID: CompanionRequestID?
  private var previousPublisherID: UUID?

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
      dropPreview()
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
    if needsPublisherConfirmation, let lastRefreshFailedAt {
      let sinceFailure = now.timeIntervalSince(lastRefreshFailedAt)
      if sinceFailure >= 0, sinceFailure < CompanionLimits.refreshTimeout {
        return nil
      }
    }
    let kind: CompanionRequest.Kind =
      !needsPublisherConfirmation && kind == .preview
        && status?.previewAvailable == true ? .preview : .refresh
    let request = gate.begin(kind, now: now)
    if needsPublisherConfirmation, let request {
      confirmingRequestID = request.id
    }
    return request
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
    let confirming = confirmingRequestID == reply.requestID
    confirmingRequestID = nil
    if let publisherID, publisherID != reply.publisherID, !confirming {
      requirePublisherConfirmation(for: reply.publisherID)
      return true
    }
    if publisherID != reply.publisherID { adoptPublisher(reply.publisherID) }
    if confirming {
      needsPublisherConfirmation = false
      confirmationPublisherID = nil
    }
    // A correlated old reply completes its request, but cannot change
    // caches established by a newer context or reply.
    guard admit(reply.revision) else { return true }
    switch reply {
    case .status(_, let status, let reason, _, _):
      apply(status, previewUnavailable: reason != nil)
    case .preview(_, let status, let newPreview, _, _):
      apply(status)
      if isActive, self.status?.previewAvailable == true,
        newPreview.owner == status.previewOwner,
        preview.map({ $0.capturedAt <= newPreview.capturedAt }) ?? true
      {
        preview = newPreview
        retainedPreviewOwner = status.previewOwner
      }
    case .disabled: clearAll()
    }
    return true
  }

  /// Decodes and applies a reply; malformed data is rejected.
  @discardableResult
  public mutating func receive(replyData data: Data) -> Bool {
    guard let reply = try? CompanionCodec.decodeReply(data) else {
      return false
    }
    return receive(reply)
  }

  /// Applies a latest-state application context.
  @discardableResult
  public mutating func receive(_ context: CompanionApplicationContext) -> Bool {
    if let publisherID, context.publisherID != publisherID {
      if context.publisherID != previousPublisherID {
        requirePublisherConfirmation(for: context.publisherID)
      }
      return false
    }
    if publisherID == nil { adoptPublisher(context.publisherID) }
    guard lastContextRevision.map({ context.revision > $0 }) ?? true,
      admit(context.revision)
    else { return false }
    lastContextRevision = context.revision
    switch context {
    case .status(let status, _, _):
      apply(status)
      return true
    case .cleared:
      clearAll()
      return true
    }
  }

  private mutating func requirePublisherConfirmation(for publisher: UUID) {
    if !needsPublisherConfirmation || confirmationPublisherID != publisher {
      gate.cancel()
      confirmingRequestID = nil
    }
    dropPreview()
    needsPublisherConfirmation = true
    confirmationPublisherID = publisher
  }

  private mutating func adoptPublisher(_ publisher: UUID) {
    previousPublisherID = publisherID
    publisherID = publisher
    lastPublicationRevision = nil
    lastContextRevision = nil
    status = nil
    dropPreview()
    needsPublisherConfirmation = false
    confirmationPublisherID = nil
  }

  private mutating func admit(_ revision: UInt64) -> Bool {
    guard lastPublicationRevision.map({ revision >= $0 }) ?? true else {
      return false
    }
    lastPublicationRevision = revision
    return true
  }

  /// Drops every cached value (phone-side opt-out).
  public mutating func clearAll() {
    status = nil
    dropPreview()
    gate.cancel()
  }

  /// Publication admission supplies the order. Observation time can stay
  /// unchanged on re-enable or move backward with the phone's clock.
  /// Preview text stays only for the same owner, and only while a preview
  /// is still offered. A status reply that cannot serve a preview drops it.
  private mutating func apply(
    _ incoming: CompanionStatus,
    previewUnavailable: Bool = false
  ) {
    let keep =
      !previewUnavailable && incoming.previewAvailable
      && retainedPreviewOwner == incoming.previewOwner
    status = incoming
    if !keep { dropPreview() }
  }

  private mutating func dropPreview() {
    preview = nil
    retainedPreviewOwner = nil
  }

  // MARK: Presentation

  public func freshness(now: Date) -> CompanionFreshness {
    if needsPublisherConfirmation, status != nil { return .stale }
    return staleness.evaluate(status, now: now)
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
