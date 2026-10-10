import Foundation
@testable import RoamingApp
import SessionCore
import TerminalSurface
import Testing

@MainActor
struct TerminalScreenModelTests {
  let host = HostProfile(nickname: "Studio", host: "studio.local", username: "me")

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
    model.observe(RoamingStatus(state: .active), at: Date(timeIntervalSince1970: 5))
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

    model.observe(RoamingStatus(state: .sessionExited, sessionID: id, exitStatus: 3))
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
    #expect(model.capabilities == PlatformProfile.profile(for: .mobile).sshSurface)
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
  func `resume store keeps non-secret session ids per host`() throws {
    let defaults = try #require(UserDefaults(suiteName: "resume-\(UUID().uuidString)"))
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
      TerminalScreenModel(host: host, profile: mac).capabilities == mac.roamingSurface
    )
    #expect(
      TerminalScreenModel(host: host, profile: mac, kind: .localShell).capabilities
        == mac.localSurface
    )
    let tv = PlatformProfile.profile(for: .tv)
    #expect(!tv.sftp)
    #expect(!TerminalScreenModel(host: host, profile: tv).capabilities.paste)
  }
}
