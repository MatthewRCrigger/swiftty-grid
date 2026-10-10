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
  private(set) var store = WatchCompanionStore()
  /// Redacted attention summaries from the paired iPhone's last inbox
  /// refresh (`AttentionSummaryBatch`). Read-only: no SSH, no input.
  private(set) var attention: [AttentionSummary] = []
  #if canImport(WatchConnectivity)
    @ObservationIgnored private var delegate: WatchSessionDelegate?
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
  }

  func presentation(now: Date) -> WatchCompanionStore.Presentation {
    store.presentation(now: now)
  }

  func tick(now: Date) {
    store.tick(now: now)
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
    if !store.receive(replyData: data) {
      store.requestFailed(id, now: .now)
    } else if store.status == nil {
      // A `disabled` reply: sharing is off on the iPhone.
      attention = []
    }
  }

  fileprivate func handle(_ event: WatchSessionEvent) {
    switch event {
    case .reachability(let reachable):
      store.setReachable(reachable)
    case .context(let context):
      store.receive(context)
    case .attention(let summaries):
      attention = summaries
    }
  }
}

enum WatchSessionEvent: Sendable {
  case reachability(Bool)
  case context(CompanionApplicationContext)
  /// The context's attention batch; empty when the context has none
  /// (sharing off, or no inbox refresh since the context was replaced).
  case attention([AttentionSummary])
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
    ) {
      deliver(applicationContext)
    }

    private func deliver(_ dictionary: [String: Any]) {
      var dictionary = dictionary
      // Each application context replaces the previous one whole: a
      // context without the batch (e.g. `.cleared`) clears attention.
      let batch = (dictionary.removeValue(forKey: AttentionSummaryBatch.dictionaryKey)
        as? Data).flatMap { try? AttentionSummaryBatch.decode($0) }
      sink(.attention(batch?.summaries ?? []))
      guard !dictionary.isEmpty,
        let context = try? CompanionApplicationContext(dictionary: dictionary)
      else { return }
      sink(.context(context))
    }
  }
#endif
