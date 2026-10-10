import CompanionModel
import Foundation
import MuxNavigation
import Observation
import RoamingApp
import Synchronization

#if canImport(WatchConnectivity)
  import WatchConnectivity
#endif

/// iPhone adapter between the app model and WatchConnectivity.
///
/// All policy lives in `PhoneCompanionBridge` (CompanionModel). This type
/// only moves values: observations in from the app, the latest-state
/// application context and immediate replies out to the watch. It never
/// starts SSH, an RST attachment, background tasks or background modes;
/// a watch request is answered synchronously from cached state.
@MainActor
@Observable
final class PhoneWatchBridge {
  /// Minimum spacing between preview captures pushed into the bridge.
  static let previewInterval: TimeInterval = 2

  @ObservationIgnored private let core = SharedBridge(
    PhoneCompanionBridge(now: .now)
  )
  /// Latest encoded `AttentionSummaryBatch`, sent beside the status.
  @ObservationIgnored private let attention = AttentionCache()
  @ObservationIgnored private var lastPreviewCapture = Date.distantPast
  @ObservationIgnored private weak var model: RoamingAppModel?
  #if canImport(WatchConnectivity)
    @ObservationIgnored private var delegate: SessionDelegate?
  #endif

  init() {}

  /// Connects to the app model and, on an iPhone with WatchConnectivity
  /// support, activates the session. iPad has no paired watch.
  func attach(to model: RoamingAppModel) {
    guard self.model == nil, model.profile.companionBridge else { return }
    self.model = model
    _ = core.withLock { $0.update(model.companionSettings, now: .now) }
    model.onSessionObservation = { [weak self] observation in
      self?.observe(observation)
    }
    model.onAttentionSummaries = { [weak self] summaries in
      self?.publishAttention(summaries)
    }
    model.onCompanionSettingsChange = { [weak self] settings in
      guard let self else { return }
      if let context = core.withLock({ $0.update(settings, now: .now) }) {
        publish(context)
      }
    }
    #if canImport(WatchConnectivity)
      guard WCSession.isSupported() else { return }
      let delegate = SessionDelegate(core: core, attention: attention)
      self.delegate = delegate
      WCSession.default.delegate = delegate
      WCSession.default.activate()
    #endif
  }

  func setForeground(_ foreground: Bool) {
    core.withLock { $0.setForeground(foreground) }
    if foreground { capturePreview(force: true) }
  }

  private func observe(_ observation: PhoneCompanionBridge.Observation) {
    if let context = core.withLock({ $0.observe(observation) }) {
      publish(context)
    }
    capturePreview(force: false)
  }

  /// Pushes the visible rows into the bridge, throttled, only when the
  /// user opted in. The bridge discards them unless in the foreground.
  private func capturePreview(force: Bool) {
    guard let model, model.companionSettings.allowsPreview else { return }
    let now = Date.now
    guard force || now.timeIntervalSince(lastPreviewCapture) >= Self.previewInterval
    else { return }
    guard let session = model.activeSession, let lines = session.previewLines?()
    else {
      core.withLock { $0.clearPreview() }
      return
    }
    lastPreviewCapture = now
    core.withLock { $0.observePreview(lines: lines, capturedAt: now) }
  }

  private func publish(_ context: CompanionApplicationContext) {
    #if canImport(WatchConnectivity)
      guard WCSession.isSupported() else { return }
      let session = WCSession.default
      guard session.activationState == .activated, session.isPaired,
        session.isWatchAppInstalled,
        let dictionary = try? context.dictionary()
      else { return }
      // Latest-state only; status metadata, never preview text.
      try? session.updateApplicationContext(attention.merged(into: dictionary))
    #endif
  }

  /// Redacted attention summaries (no message text, no terminal output).
  /// Replaces the previous batch; the companion status is resent with it.
  private func publishAttention(_ summaries: [AttentionSummary]) {
    guard let data = try? AttentionSummaryBatch(summaries: summaries).encoded()
    else { return }
    attention.set(data)
    publish(core.withLock { $0.applicationContext })
  }
}

/// The encoded attention batch, shared with the delegate queue.
final class AttentionCache: Sendable {
  private let data = Mutex<Data?>(nil)

  func set(_ value: Data) { data.withLock { $0 = value } }

  func merged(into dictionary: [String: Data]) -> [String: Data] {
    var dictionary = dictionary
    if let value = data.withLock({ $0 }) {
      dictionary[AttentionSummaryBatch.dictionaryKey] = value
    }
    return dictionary
  }
}

/// The bridge core behind a lock, so WatchConnectivity's delegate queue
/// can answer immediately without hopping to the main actor.
final class SharedBridge: Sendable {
  private let state: Mutex<PhoneCompanionBridge>

  init(_ bridge: PhoneCompanionBridge) {
    state = Mutex(bridge)
  }

  func withLock<R: Sendable>(_ body: (inout PhoneCompanionBridge) -> R) -> R {
    state.withLock { body(&$0) }
  }
}

#if canImport(WatchConnectivity)
  /// Answers watch requests from the shared core on the delegate queue.
  final class SessionDelegate: NSObject, WCSessionDelegate, Sendable {
    private let core: SharedBridge
    private let attention: AttentionCache

    init(core: SharedBridge, attention: AttentionCache) {
      self.core = core
      self.attention = attention
    }

    func session(
      _ session: WCSession,
      activationDidCompleteWith activationState: WCSessionActivationState,
      error: (any Error)?
    ) {
      guard activationState == .activated, session.isPaired,
        let dictionary = try? core.withLock({ $0.applicationContext }).dictionary()
      else { return }
      try? session.updateApplicationContext(attention.merged(into: dictionary))
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
      // Switching watches: reactivate for the newly paired one.
      session.activate()
    }

    func session(
      _ session: WCSession,
      didReceiveMessageData messageData: Data,
      replyHandler: @escaping (Data) -> Void
    ) {
      // Immediate reply from cached, iPhone-observed state. A malformed
      // request gets an empty reply, which the watch rejects.
      let reply = core.withLock { $0.reply(toMessageData: messageData) }
      replyHandler(reply ?? Data())
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
      // Requests without a reply handler are ignored.
    }
  }
#endif
