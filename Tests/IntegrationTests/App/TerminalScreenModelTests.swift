import CompanionModel
import Foundation
@testable import RoamingApp
import SessionCore
import TerminalSurface
import Testing

extension MainActorIntegrationTests {
  @MainActor
  struct TerminalScreenModelTests {
    let host = HostProfile(
      nickname: "Studio",
      host: "studio.local",
      username: "me"
    )

    func makeModel(kind: TerminalKind = .roaming) -> TerminalScreenModel {
      TerminalScreenModel(
        host: host,
        profile: .profile(for: .mobile),
        kind: kind,
        now: Date(timeIntervalSince1970: 0)
      )
    }

    @Test
    func `observe mirrors states the validated transition would skip`() {
      let model = makeModel()
      // idle -> active is not a single valid transition, but the client
      // may pass through several states between two status deliveries.
      #expect(!ClientConnectionState.idle.canTransition(to: .active))
      model.observe(
        RoamingStatus(state: .active),
        at: Date(timeIntervalSince1970: 5)
      )
      #expect(model.connectionState == .active)
      #expect(model.stateObservedAt == Date(timeIntervalSince1970: 5))
      #expect(model.acceptsInput)

      model.observe(RoamingStatus(state: .attaching, reconnectAttempt: 3))
      #expect(model.connectionState == .attaching)
      #expect(model.reconnectAttempt == 3)
      #expect(!model.acceptsInput)

      // `transition(to:)` still refuses invalid jumps.
      model.transition(to: .idle)
      #expect(model.connectionState == .attaching)
    }

    @Test
    func `observe copies pending input, screen time, session and exit`() {
      let model = makeModel()
      let id = SessionID.random()
      let screen = Date(timeIntervalSince1970: 42)
      model.observe(
        RoamingStatus(
          state: .active,
          sessionID: id,
          lastScreenAt: screen,
          pendingInputCount: 4,
          title: "vim",
          lastFailure: .stale
        )
      )
      #expect(model.sessionID == id)
      #expect(model.lastScreenAt == screen)
      #expect(model.pendingInputCount == 4)
      #expect(model.title == "vim")
      #expect(model.lastFailure == .stale)
      #expect(model.companionObservation.pendingInputCount == 4)

      model.observe(
        RoamingStatus(state: .sessionExited, sessionID: id, exitStatus: 3)
      )
      #expect(model.connectionState == .sessionExited)
      #expect(model.exitStatus == 3)
      #expect(model.pendingInputCount == 0)
    }

    @Test
    func `a local close is final against late status updates`() {
      let model = makeModel()
      model.observe(RoamingStatus(state: .active))
      model.transition(to: .userClosed)
      model.observe(RoamingStatus(state: .backgroundDetached))
      #expect(model.connectionState == .userClosed)
    }

    @Test
    func `byte stream lifecycles map onto honest states`() {
      let model = makeModel(kind: .ordinarySSH)
      #expect(
        model.capabilities == PlatformProfile.profile(for: .mobile).sshSurface
      )
      model.observe(SurfaceLifecycle.connecting)
      #expect(model.connectionState == .sshBootstrap)
      model.observe(SurfaceLifecycle.active)
      #expect(model.connectionState == .active)
      model.observe(SurfaceLifecycle.lost)
      #expect(model.connectionState == .sessionLost)

      let exited = makeModel(kind: .ordinarySSH)
      exited.observe(SurfaceLifecycle.active)
      exited.observe(SurfaceLifecycle.exited(7))
      #expect(exited.connectionState == .sessionExited)
      #expect(exited.exitStatus == 7)
    }

    @Test
    func `only real changes are published`() {
      let model = makeModel()
      var published = 0
      model.onChange = { _ in published += 1 }
      let status = RoamingStatus(state: .active, pendingInputCount: 1)
      model.observe(status)
      model.observe(status)
      #expect(published == 1)
      model.observe(RoamingStatus(state: .active, pendingInputCount: 0))
      #expect(published == 2)
    }

    @Test
    func `companion previews retain the screen observation time`() throws {
      let model = makeModel()
      model.previewLines = { ["cached screen"] }
      #expect(model.companionPreview == nil)
      let later = Date(
        timeIntervalSince1970: floor(Date.now.timeIntervalSince1970)
      )
      let screenAt = later.addingTimeInterval(-120)
      model.screenInstalled(at: screenAt)
      model.observe(SurfaceLifecycle.interrupted, at: later)
      model.setPendingInputCount(2)

      let preview = try #require(model.companionPreview)
      var phone = PhoneCompanionBridge(
        settings: CompanionSettings(sharingEnabled: true, previewEnabled: true),
        isForeground: true,
        now: Date(timeIntervalSince1970: 0)
      )
      _ = phone.observe(model.companionObservation)
      phone.observePreview(lines: preview.lines, capturedAt: preview.capturedAt)
      var watch = WatchCompanionStore()
      watch.setActive(true)
      watch.setReachable(true)
      let context = try CompanionCodec.encode(phone.applicationContext)
      watch.receive(try CompanionCodec.decodeContext(context))
      let pending = watch.beginRequest(.preview, now: later)
      let request = try #require(pending)
      let reply = try CompanionCodec.encode(phone.reply(to: request))
      let accepted = watch.receive(replyData: reply)
      #expect(accepted)
      #expect(watch.preview?.lines == ["cached screen"])
      #expect(watch.preview?.capturedAt == screenAt)
      #expect(
        CompanionStaleness.standard.evaluate(
          capturedAt: watch.preview?.capturedAt,
          now: later
        ) == .stale
      )

      let newer = later.addingTimeInterval(1)
      model.screenInstalled(at: newer)
      #expect(model.companionPreview?.capturedAt == newer)
      model.previewLines = nil
      #expect(model.companionPreview == nil)
    }

    @Test
    func `companion status timestamps follow screen and input observations`() {
      let model = makeModel()
      let stateAt = Date(timeIntervalSince1970: 1_700_000_000)
      let screenAt = stateAt.addingTimeInterval(10)
      let inputAt = stateAt.addingTimeInterval(20)
      model.observe(SurfaceLifecycle.active, at: stateAt)
      model.screenInstalled(at: screenAt)
      var phone = PhoneCompanionBridge(now: stateAt)
      _ = phone.observe(model.companionObservation)
      #expect(phone.status?.capturedAt == screenAt)
      #expect(phone.status?.lastScreenAt == screenAt)
      #expect(model.stateObservedAt == stateAt)

      model.observe(
        RoamingStatus(
          state: .active,
          lastScreenAt: screenAt,
          pendingInputCount: 1
        ),
        at: inputAt
      )
      _ = phone.observe(model.companionObservation)
      #expect(phone.status?.capturedAt == inputAt)
      #expect(phone.status?.lastScreenAt == screenAt)
      #expect(phone.status?.pendingInputCount == 1)
      #expect(model.stateObservedAt == stateAt)
      model.observe(
        RoamingStatus(
          state: .active,
          lastScreenAt: screenAt,
          pendingInputCount: 1
        ),
        at: inputAt.addingTimeInterval(10)
      )
      #expect(model.companionObservation.observedAt == inputAt)
      let drainedAt = inputAt.addingTimeInterval(20)
      model.setPendingInputCount(0, at: drainedAt)
      #expect(model.companionObservation.observedAt == drainedAt)
      model.setPendingInputCount(0, at: drainedAt.addingTimeInterval(10))
      #expect(model.companionObservation.observedAt == drainedAt)
    }

    @Test
    func `resume store keeps non-secret session ids per host`() throws {
      let suite = "resume-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let store = SessionResumeStore(defaults: defaults)
      let id = SessionID.random()
      store.set(id, for: host.id)
      #expect(store.sessionID(for: host.id) == id)
      #expect(store.all() == [host.id: id])
      store.set(nil, for: host.id)
      #expect(store.sessionID(for: host.id) == nil)
    }

    @Test
    func `capabilities follow the terminal kind`() {
      let mac = PlatformProfile.profile(for: .mac)
      #expect(
        TerminalScreenModel(host: host, profile: mac).capabilities
          == mac.roamingSurface
      )
      #expect(
        TerminalScreenModel(host: host, profile: mac, kind: .localShell)
          .capabilities == mac.localSurface
      )
      let tv = PlatformProfile.profile(for: .tv)
      #expect(!tv.sftp)
      #expect(!TerminalScreenModel(host: host, profile: tv).capabilities.paste)
    }
  }
}
