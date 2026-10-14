import CompanionModel
import Foundation
import MuxNavigation
import Observation
import RoamingApp

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

  @ObservationIgnored
  private let core: PhoneWatchPublication?
  @ObservationIgnored
  private var captureGate = PreviewCaptureGate(
    lastCapture: .distantPast,
    interval: PhoneWatchBridge.previewInterval
  )
  @ObservationIgnored
  private var pendingPreview: Task<Void, Never>?
  @ObservationIgnored
  private weak var model: RoamingAppModel?
  #if canImport(WatchConnectivity)
  @ObservationIgnored
  private var delegate: SessionDelegate?
  #endif

  init() {
    do {
      let directory = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let sequence = CompanionPublicationSequenceFile(
        url: directory.appending(path: "Companion/publication-sequence")
      )
      let identity = try sequence.load()
      core = PhoneWatchPublication(
        bridge: PhoneCompanionBridge(
          now: .now,
          publicationRevision: identity.revision,
          publisherID: identity.publisherID
        ),
        saveIdentity: { (try? sequence.save($0)) != nil }
      )
    } catch {
      // Refuse publication if the durable watermark cannot be recovered.
      core = nil
    }
  }

  /// Connects to the app model and, on an iPhone with WatchConnectivity
  /// support, activates the session. iPad has no paired watch.
  func attach(to model: RoamingAppModel) {
    guard self.model == nil, model.profile.companionBridge, let core else {
      return
    }
    self.model = model
    _ = core.withBridge { $0.update(model.companionSettings, now: .now) }
    model.onSessionObservation = { [weak self] observation in
      self?.observe(observation)
    }
    model.onAttentionSummaries = { [weak self] summaries in
      self?.publishAttention(summaries)
    }
    model.onCompanionSettingsChange = { [weak self] settings in
      guard let self else { return }
      let decision = core.withBridge {
        bridge -> (CompanionApplicationContext?, Bool) in
        let wasAllowed = bridge.settings.allowsPreview
        let context = bridge.update(settings, now: .now)
        return (context, settings.allowsPreview && !wasAllowed)
      }
      if decision.0 != nil { publish() }
      if decision.1 { capturePreview(force: true) }
    }
    #if canImport(WatchConnectivity)
    guard WCSession.isSupported() else { return }
    let delegate = SessionDelegate(core: core)
    self.delegate = delegate
    WCSession.default.delegate = delegate
    WCSession.default.activate()
    #endif
  }

  func setForeground(_ foreground: Bool) {
    core?.withBridge { $0.setForeground(foreground) }
    if foreground { capturePreview(force: true) }
  }

  private func observe(_ observation: PhoneCompanionBridge.Observation) {
    guard let core else { return }
    if core.withBridge({ $0.observe(observation) }) != nil { publish() }
    capturePreview(force: false)
  }

  /// Pushes the visible rows into the bridge, throttled, only when the
  /// user opted in. The bridge discards them unless in the foreground.
  private func capturePreview(force: Bool) {
    guard let model, let core, model.companionSettings.allowsPreview else {
      pendingPreview?.cancel()
      pendingPreview = nil
      captureGate.cancelSchedule()
      return
    }
    switch captureGate.decide(now: .now, force: force) {
    case .skip: return
    case let .schedule(delay):
      pendingPreview?.cancel()
      pendingPreview = Task { [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard !Task.isCancelled else { return }
        self?.capturePreview(force: true)
      }
    case let .capture(now):
      pendingPreview?.cancel()
      pendingPreview = nil
      guard let session = model.activeSession,
        let preview = session.companionPreview
      else {
        core.withBridge { $0.clearPreview() }
        return
      }
      captureGate.didCapture(at: now)
      core.withBridge {
        $0.observePreview(lines: preview.lines, capturedAt: preview.capturedAt)
      }
    }
  }

  private func publish() {
    #if canImport(WatchConnectivity)
    guard WCSession.isSupported() else { return }
    let session = WCSession.default
    guard session.activationState == .activated, session.isPaired,
      session.isWatchAppInstalled
    else { return }
    core?
      .publish { dictionary in
        (try? session.updateApplicationContext(dictionary)) != nil
      }
    #endif
  }

  /// Redacted attention summaries; no message text or terminal output.
  private func publishAttention(_ summaries: [AttentionSummary]) {
    guard let core, core.setAttention(summaries) else { return }
    publish()
  }
}

#if canImport(WatchConnectivity)
/// Answers watch requests from the shared core on the delegate queue.
final class SessionDelegate: NSObject, WCSessionDelegate, Sendable {
  private let core: PhoneWatchPublication

  init(core: PhoneWatchPublication) { self.core = core }

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: (any Error)?
  ) {
    guard activationState == .activated, session.isPaired,
      session.isWatchAppInstalled
    else { return }
    core.publish { dictionary in
      (try? session.updateApplicationContext(dictionary)) != nil
    }
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
    let reply = core.reply(toMessageData: messageData)
    replyHandler(reply ?? Data())
    // A fresh whole context lets a confirmed new publisher replace its
    // status and attention together. The receiver also handles the context
    // arriving before this reply. Both sends use cached state only.
    if reply != nil, session.activationState == .activated, session.isPaired,
      session.isWatchAppInstalled
    {
      core.publish { dictionary in
        (try? session.updateApplicationContext(dictionary)) != nil
      }
    }
  }

  func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
    // Requests without a reply handler are ignored.
  }
}
#endif
