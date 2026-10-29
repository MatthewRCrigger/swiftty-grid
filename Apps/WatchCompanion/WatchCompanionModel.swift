import CompanionModel
import Foundation
import MuxNavigation
import Observation

#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Main-actor owner of the watch's `WatchCompanionStore` and its
/// WatchConnectivity adapter.
@MainActor
@Observable
final class WatchCompanionModel {
  /// A working copy for updates that must commit together.
  private struct State {
    var store: WatchCompanionStore
    var attention: [AttentionSummary]
    var pendingContext: WatchApplicationContext?
  }

  /// Separate stored properties, so a view that reads one is not
  /// invalidated by a change to another.
  private(set) var store = WatchCompanionStore()
  /// Redacted attention summaries from the paired iPhone's last inbox
  /// refresh (`AttentionSummaryBatch`). Read-only: no SSH, no input.
  private(set) var attention: [AttentionSummary] = []
  /// Never read by views.
  @ObservationIgnored
  private var pendingContext: WatchApplicationContext?

  /// Commits only the fields that changed.
  private var state: State {
    get {
      State(store: store, attention: attention, pendingContext: pendingContext)
    }
    set {
      if newValue.store != store { store = newValue.store }
      if newValue.attention != attention { attention = newValue.attention }
      pendingContext = newValue.pendingContext
    }
  }
  #if canImport(WatchConnectivity)
  @ObservationIgnored
  private var delegate: WatchSessionDelegate?
  #endif

  init() {}

  func activate() {
    #if canImport(WatchConnectivity)
    guard delegate == nil, WCSession.isSupported() else { return }
    let delegate = WatchSessionDelegate { [weak self] event in
      Task { @MainActor in self?.handle(event) }
    }
    self.delegate = delegate
    WCSession.default.delegate = delegate
    WCSession.default.activate()
    #endif
  }

  func setActive(_ active: Bool) {
    store.setActive(active)
    #if canImport(WatchConnectivity)
    if active, WCSession.isSupported() {
      store.setReachable(WCSession.default.isReachable)
    }
    #endif
    if active, store.needsPublisherConfirmation { refresh(.refresh) }
  }

  func presentation(now: Date) -> WatchCompanionStore.Presentation {
    store.presentation(now: now)
  }

  func tick(now: Date) {
    store.tick(now: now)
    if store.needsPublisherConfirmation { refresh(.refresh) }
  }

  /// Sends one refresh (or preview) request if none is pending.
  func refresh(_ kind: CompanionRequest.Kind) {
    #if canImport(WatchConnectivity)
    guard let request = store.beginRequest(kind, now: .now) else { return }
    guard let data = try? CompanionCodec.encode(request) else {
      store.requestFailed(request.id, now: .now)
      return
    }
    let id = request.id
    WCSession.default.sendMessageData(
      data,
      replyHandler: { @Sendable [weak self] reply in
        Task { @MainActor in self?.receiveReply(reply, for: id) }
      },
      errorHandler: { @Sendable [weak self] _ in
        Task { @MainActor in self?.store.requestFailed(id, now: .now) }
      }
    )
    #endif
  }

  private func receiveReply(_ data: Data, for id: CompanionRequestID) {
    var next = state
    if let reply = try? CompanionCodec.decodeReply(data), reply.requestID == id,
      next.store.receive(reply)
    {
      if next.store.status == nil
        || next.store.publisherID != state.store.publisherID
      {
        // A disabled reply or a newly confirmed publisher drops old content.
        next.attention = []
      }
      if !next.store.needsPublisherConfirmation {
        if let pending = next.pendingContext,
          pending.companion.publisherID == next.store.publisherID,
          next.store.receive(pending.companion)
        {
          next.attention = pending.attention?.summaries ?? []
        }
        next.pendingContext = nil
      } else if next.pendingContext?.companion.publisherID
        != next.store.confirmationPublisherID
      {
        next.pendingContext = nil
      }
    } else {
      next.store.requestFailed(id, now: .now)
    }
    state = next
    if store.needsPublisherConfirmation { refresh(.refresh) }
  }

  fileprivate func handle(_ event: WatchSessionEvent) {
    switch event {
    case .reachability(let reachable):
      store.setReachable(reachable)
      if reachable, store.needsPublisherConfirmation { refresh(.refresh) }
    case .context(let context):
      var next = state
      if next.store.receive(context.companion) {
        next.attention = context.attention?.summaries ?? []
      } else if next.store.needsPublisherConfirmation,
        context.companion.publisherID == next.store.confirmationPublisherID
      {
        if next.pendingContext?.companion.publisherID
          != context.companion.publisherID
          || next.pendingContext.map({
            $0.companion.revision < context.companion.revision
          }) ?? true
        {
          next.pendingContext = context
        }
      }
      state = next
      if store.needsPublisherConfirmation { refresh(.refresh) }
    }
  }
}

enum WatchSessionEvent: Sendable {
  case reachability(Bool)
  case context(WatchApplicationContext)
}

#if canImport(WatchConnectivity)
/// Decodes WatchConnectivity callbacks into Sendable events.
final class WatchSessionDelegate: NSObject, WCSessionDelegate, Sendable {
  private let sink: @Sendable (WatchSessionEvent) -> Void

  init(sink: @escaping @Sendable (WatchSessionEvent) -> Void) {
    self.sink = sink
  }

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: (any Error)?
  ) {
    sink(.reachability(activationState == .activated && session.isReachable))
    deliver(session.receivedApplicationContext)
  }

  func sessionReachabilityDidChange(_ session: WCSession) {
    sink(.reachability(session.isReachable))
  }

  func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) { deliver(applicationContext) }

  private func deliver(_ dictionary: [String: Any]) {
    guard let context = try? WatchApplicationContext(dictionary: dictionary)
    else { return }
    sink(.context(context))
  }
}
#endif
