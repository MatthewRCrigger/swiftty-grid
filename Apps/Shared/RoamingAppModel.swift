import CompanionModel
import Foundation
import MuxNavigation
import Observation
import SSHClient
import ScreenProtocol
import SessionCore
import SwifttyCore
import TerminalSurface

/// Host-key trust question shown before any credential is sent
/// (spec §5.1). Raised by `SSHAccess` through `RoamingAppModel.requestTrust`.
public struct TrustPrompt: Hashable, Sendable, Identifiable {
  public enum Kind: Hashable, Sendable {
    /// First contact: the user may trust the key explicitly.
    case unknownKey
    /// The key differs from the trusted one: connection is blocked.
    case changedKey
  }

  public let id = UUID()
  public let host: HostProfile
  public let kind: Kind
  public let keyAlgorithm: String
  /// `SHA256:` base64 fingerprint, display only.
  public let fingerprint: String

  public init(host: HostProfile, kind: Kind, keyAlgorithm: String, fingerprint: String) {
    self.host = host
    self.kind = kind
    self.keyAlgorithm = keyAlgorithm
    self.fingerprint = fingerprint
  }
}

/// The user's answer to a `TrustPrompt`.
public enum TrustDecision: Hashable, Sendable {
  case trust
  case reject
}

/// Which terminal path a screen shows (spec §A.3).
public enum TerminalKind: Hashable, Sendable {
  /// RST/1 attachment to a helper-owned session that survives roaming.
  case roaming
  /// An ordinary SSH shell. A *different* shell from any roaming session;
  /// it ends with its connection and is never resumed (spec §9).
  case ordinarySSH
  /// App-local PTY (native macOS only).
  case localShell

  public var displayName: String {
    switch self {
    case .roaming: "Roaming session"
    case .ordinarySSH: "Ordinary SSH shell"
    case .localShell: "Local shell"
    }
  }
}

/// The live backend behind a `TerminalScreenModel`; owned by the model so
/// it lives exactly as long as the screen.
@MainActor
protocol TerminalSurfaceController: AnyObject {
  /// Ends the attachment or channel. `.detach` keeps a roaming host
  /// session for a later resume; `.terminate` destroys it.
  func close(_ mode: RoamingCloseMode) async
}

/// State of the one terminal a client app shows at a time (spec §2: one
/// actively attached roaming terminal per client app).
///
/// The terminal integration drives it: `observe(_: RoamingStatus)` mirrors
/// a roaming client, `observe(_: SurfaceLifecycle)` a byte-stream backend.
/// The surface is supplied through `TerminalSurfaceFactory`.
@MainActor
@Observable
public final class TerminalScreenModel: Identifiable {
  /// Local identity of this session view; never sent anywhere.
  public let id = UUID()
  public let host: HostProfile
  public let profile: PlatformProfile
  public let kind: TerminalKind
  /// Capabilities the surface must honour for this session.
  public var capabilities: SurfaceCapabilities
  public private(set) var connectionState: ClientConnectionState = .idle
  /// When `connectionState` was last observed to change.
  public private(set) var stateObservedAt: Date
  public private(set) var lastScreenAt: Date?
  public private(set) var pendingInputCount = 0
  /// Roaming session identity (non-secret), once granted.
  public private(set) var sessionID: SessionID?
  /// Remote window title; display only, never interpreted.
  public private(set) var title = ""
  /// Exit status of the shell, when it exited with one.
  public private(set) var exitStatus: Int32?
  /// Latest nonsecret failure reported by the roaming client.
  public private(set) var lastFailure: RoamingFailure?
  /// Consecutive reconnect attempts since the last success.
  public private(set) var reconnectAttempt = 0
  /// Supplies the current visible rows for an opted-in companion preview.
  /// Set by the terminal integration; `nil` means no screen yet.
  @ObservationIgnored public var previewLines: (@MainActor () -> [String])?
  /// Called after each observed change (companion bridge, diagnostics).
  @ObservationIgnored var onChange: (@MainActor (TerminalScreenModel) -> Void)?
  /// The live backend, created by the surface factory on first display.
  @ObservationIgnored var controller: (any TerminalSurfaceController)?

  public init(
    host: HostProfile,
    profile: PlatformProfile,
    kind: TerminalKind = .roaming,
    now: Date = .now
  ) {
    self.host = host
    self.profile = profile
    self.kind = kind
    self.capabilities =
      switch kind {
      case .roaming: profile.roamingSurface
      case .ordinarySSH: profile.sshSurface
      case .localShell: profile.localSurface ?? profile.sshSurface
      }
    self.stateObservedAt = now
  }

  /// Applies a lifecycle transition validated by SessionCore. Invalid
  /// transitions are ignored; use `observe` to mirror a backend's actual
  /// state, which may legitimately skip intermediate states.
  public func transition(to next: ClientConnectionState, at now: Date = .now) {
    guard connectionState.canTransition(to: next) else { return }
    connectionState = next
    stateObservedAt = now
    onChange?(self)
  }

  /// Mirrors a roaming client's status as reported, including state jumps
  /// the client made between two status deliveries. A local close
  /// (`userClosed`) is final and is not overwritten by late updates.
  public func observe(_ status: RoamingStatus, at now: Date = .now) {
    var changed = false
    if status.state != connectionState, connectionState != .userClosed {
      connectionState = status.state
      stateObservedAt = now
      changed = true
    }
    if status.lastScreenAt != lastScreenAt {
      lastScreenAt = status.lastScreenAt
      changed = true
    }
    let pending = max(0, status.pendingInputCount)
    if pending != pendingInputCount {
      pendingInputCount = pending
      changed = true
    }
    if status.sessionID != sessionID {
      sessionID = status.sessionID
      changed = true
    }
    if status.title != title { title = status.title }
    if status.exitStatus != exitStatus {
      exitStatus = status.exitStatus
      changed = true
    }
    if status.lastFailure != lastFailure { lastFailure = status.lastFailure }
    if status.reconnectAttempt != reconnectAttempt {
      reconnectAttempt = status.reconnectAttempt
    }
    if changed { onChange?(self) }
  }

  /// Mirrors a byte-stream backend (ordinary SSH, local PTY) onto the
  /// shared state names. Such a shell has no reconnect: an interruption
  /// is `suspect`, a dropped connection is `sessionLost`.
  public func observe(_ lifecycle: SurfaceLifecycle, at now: Date = .now) {
    let next: ClientConnectionState
    switch lifecycle {
    case .connecting: next = .sshBootstrap
    case .active: next = .active
    case .interrupted: next = .suspect
    case let .exited(status):
      exitStatus = status
      next = .sessionExited
    case .lost: next = .sessionLost
    case .closed: next = .userClosed
    }
    guard next != connectionState, connectionState != .userClosed else { return }
    connectionState = next
    stateObservedAt = now
    onChange?(self)
  }

  /// A complete screen was installed.
  public func screenInstalled(at now: Date = .now) {
    lastScreenAt = now
    onChange?(self)
  }

  public func setPendingInputCount(_ count: Int) {
    pendingInputCount = max(0, count)
    onChange?(self)
  }

  /// Whether new remote input may be accepted (spec §8).
  public var acceptsInput: Bool {
    connectionState.acceptsInput && capabilities.textInput
  }

  /// This model as an iPhone companion observation.
  public var companionObservation: PhoneCompanionBridge.Observation {
    PhoneCompanionBridge.Observation(
      sessionToken: id,
      nickname: host.nickname,
      state: CompanionConnectionState(connectionState),
      observedAt: stateObservedAt,
      lastScreenAt: lastScreenAt,
      pendingInputCount: pendingInputCount
    )
  }
}

/// A password request for `host`. The answer is kept in memory only.
public struct PasswordPrompt: Hashable, Sendable, Identifiable {
  public let id = UUID()
  public let host: HostProfile
  /// The previous password was rejected.
  public let isRetry: Bool

  public init(host: HostProfile, isRetry: Bool) {
    self.host = host
    self.isRetry = isRetry
  }
}

extension CompanionConnectionState {
  /// Maps the direct-client state onto the companion's mirror.
  public init(_ state: ClientConnectionState) {
    self =
      switch state {
      case .idle: .idle
      case .sshBootstrap: .sshBootstrap
      case .attaching: .attaching
      case .active: .active
      case .suspect: .suspect
      case .reconnecting: .reconnecting
      case .backgroundDetached: .backgroundDetached
      case .sessionExited: .sessionExited
      case .sessionLost: .sessionLost
      case .userClosed: .userClosed
      }
  }
}

/// Shared application model for every direct client.
@MainActor
@Observable
public final class RoamingAppModel {
  public let profile: PlatformProfile
  public private(set) var hosts: [HostProfile] = []
  public private(set) var lastError: String?
  /// The single active terminal, if any.
  public private(set) var activeSession: TerminalScreenModel?
  /// A host-key decision awaiting the user.
  public var pendingTrust: TrustPrompt?
  /// A password awaiting the user.
  public var pendingPassword: PasswordPrompt?
  /// Sheets presented above the root; while nonzero the topmost one
  /// presents connection prompts.
  var modalDepth = 0
  /// Hosts with a remembered roaming session to resume.
  public private(set) var resumableHosts: Set<UUID> = []
  /// Companion settings (iPhone only; ignored elsewhere).
  public var companionSettings: CompanionSettings {
    didSet {
      guard companionSettings != oldValue else { return }
      Self.saveCompanionSettings(companionSettings)
      onCompanionSettingsChange?(companionSettings)
      // Observations are dropped while sharing is off: re-send the
      // current one so the watch does not show "no session" until the
      // next state change.
      if companionSettings.sharingEnabled, !oldValue.sharingEnabled {
        onSessionObservation?(currentCompanionObservation)
      }
    }
  }

  /// Receives every observation of the active session (iPhone bridge).
  @ObservationIgnored
  public var onSessionObservation: (@MainActor (PhoneCompanionBridge.Observation) -> Void)?
  /// Redacted inbox summaries after each refresh, for the watch bridge.
  @ObservationIgnored
  public var onAttentionSummaries: (@MainActor ([AttentionSummary]) -> Void)?

  @ObservationIgnored
  public var onCompanionSettingsChange: (@MainActor (CompanionSettings) -> Void)?
  /// Observes the user's answer to each `pendingTrust` (diagnostics).
  @ObservationIgnored
  public var onTrustDecision: (@MainActor (TrustPrompt, TrustDecision) -> Void)?

  /// Bulk SFTP work waits here while terminal input is unacknowledged
  /// (spec §10) or the app is suspended.
  public let transferPolicy = TransferPausePolicy()

  @ObservationIgnored private let store: HostProfileStore
  @ObservationIgnored private let resumeStore: SessionResumeStore
  /// Attention links waiting for their host's next roaming start.
  @ObservationIgnored private var pendingReveals: [UUID: ResumeTarget] = [:]
  @ObservationIgnored private var trustQueue:
    [(prompt: TrustPrompt, continuation: CheckedContinuation<TrustDecision, Never>)] = []
  @ObservationIgnored private var passwordQueue:
    [(prompt: PasswordPrompt, continuation: CheckedContinuation<String?, Never>)] = []
  /// Session passwords, in memory only, never logged or persisted.
  @ObservationIgnored private var passwords: [UUID: String] = [:]
  @ObservationIgnored private var sshAccess: SSHAccess?

  public init(
    profile: PlatformProfile = .current,
    store: HostProfileStore = HostProfileStore(fileURL: HostProfileStore.defaultURL()),
    resumeStore: SessionResumeStore = SessionResumeStore(
      defaults: UITesting.defaults ?? .standard
    )
  ) {
    self.profile = profile
    self.store = store
    self.resumeStore = resumeStore
    self.companionSettings = Self.loadCompanionSettings()
    self.resumableHosts = Set(resumeStore.all().keys)
  }

  /// SSH connection services: trust store, credentials, prompts.
  var ssh: SSHAccess {
    if let sshAccess { return sshAccess }
    let access = SSHAccess(app: self)
    sshAccess = access
    return access
  }

  // MARK: Hosts

  public func load() {
    do {
      hosts = try store.load()
      lastError = nil
    } catch {
      lastError = "Saved hosts could not be read."
    }
  }

  /// Adds or replaces `host` (matched by id) after validation.
  public func save(_ host: HostProfile) throws(HostProfile.ValidationError) {
    try host.validate()
    var next = hosts
    if let index = next.firstIndex(where: { $0.id == host.id }) {
      if next[index] != host { passwords[host.id] = nil }
      next[index] = host
    } else {
      next.append(host)
    }
    persist(next)
  }

  public func delete(_ host: HostProfile) {
    if activeSession?.host.id == host.id { close() }
    passwords[host.id] = nil
    forgetSession(for: host)
    persist(hosts.filter { $0.id != host.id })
  }

  private func persist(_ next: [HostProfile]) {
    do {
      try store.save(next)
      hosts = next
      lastError = nil
    } catch {
      lastError = "Saved hosts could not be written."
    }
  }

  // MARK: Session

  /// Opens the terminal screen for `host`, replacing any other session in
  /// this app (one active roaming terminal per client). Replacing a
  /// roaming session detaches it; the host keeps the shell.
  public func open(_ host: HostProfile, kind: TerminalKind = .roaming) {
    if let activeSession, activeSession.host.id == host.id, activeSession.kind == kind {
      return
    }
    if kind == .localShell, !profile.localPTY { return }
    close()
    let session = TerminalScreenModel(host: host, profile: profile, kind: kind)
    session.onChange = { [weak self] model in
      guard let self else { return }
      transferPolicy.setPendingInput(model.pendingInputCount > 0)
      onSessionObservation?(model.companionObservation)
    }
    activeSession = session
    onSessionObservation?(session.companionObservation)
  }

  /// Opens an app-local shell (native macOS only).
  public func openLocalShell() {
    guard profile.localPTY else { return }
    open(.localMachine, kind: .localShell)
  }

  /// Closes the active terminal view. `.detach` keeps a roaming host
  /// shell for a later resume (spec §4); `.terminate` destroys it.
  public func close(_ mode: RoamingCloseMode = .detach) {
    guard let session = activeSession else { return }
    if let controller = session.controller {
      session.controller = nil
      Task { await controller.close(mode) }
    }
    if mode == .terminate { forgetSession(for: session.host) }
    session.transition(to: .userClosed)
    session.onChange = nil
    session.previewLines = nil
    activeSession = nil
    transferPolicy.setPendingInput(false)
    onSessionObservation?(currentCompanionObservation)
  }

  /// The active session's observation, or "no session" observed now.
  var currentCompanionObservation: PhoneCompanionBridge.Observation {
    activeSession?.companionObservation
      ?? PhoneCompanionBridge.Observation(
        sessionToken: nil,
        nickname: nil,
        state: .noSession,
        observedAt: .now
      )
  }

  /// Bounded detach of the active session before the app quits; the
  /// helper also retains sessions whose detach never arrives (spec §9).
  public func detachForTermination() async {
    guard let session = activeSession, let controller = session.controller else { return }
    session.controller = nil
    await controller.close(.detach)
  }

  /// Opens `workspace` on `host` from an attention link: the next start
  /// resumes it, focuses `target.pane` and takes over only the lease the
  /// user confirmed (`target.expectedLease`). Replaces the active session.
  public func reveal(_ host: HostProfile, workspace: SessionID, target: ResumeTarget) {
    if activeSession != nil { close() }
    rememberSession(workspace, for: host)
    pendingReveals[host.id] = target
    open(host)
  }

  /// The reveal for `host`'s next start, consumed once.
  func takeReveal(for host: HostProfile) -> ResumeTarget? {
    pendingReveals.removeValue(forKey: host.id)
  }

  // MARK: Resume (non-secret session identifiers only)

  /// The remembered roaming session for `host`, if any.
  public func resumableSessionID(for host: HostProfile) -> SessionID? {
    resumeStore.sessionID(for: host.id)
  }

  func rememberSession(_ id: SessionID, for host: HostProfile) {
    guard resumeStore.sessionID(for: host.id) != id else { return }
    resumeStore.set(id, for: host.id)
    resumableHosts.insert(host.id)
  }

  func forgetSession(for host: HostProfile) {
    resumeStore.set(nil, for: host.id)
    resumableHosts.remove(host.id)
  }

  // MARK: Trust prompts

  /// Shows `prompt` (queued behind any other) and waits for the user. A
  /// changed key is always answered `.reject`.
  public func requestTrust(_ prompt: TrustPrompt) async -> TrustDecision {
    await withCheckedContinuation { continuation in
      trustQueue.append((prompt, continuation))
      showNextTrustPrompt()
    }
  }

  public func resolveTrust(_ decision: TrustDecision) {
    guard let prompt = pendingTrust else { return }
    pendingTrust = nil
    let final = prompt.kind == .changedKey ? .reject : decision
    if let index = trustQueue.firstIndex(where: { $0.prompt.id == prompt.id }) {
      trustQueue.remove(at: index).continuation.resume(returning: final)
    }
    onTrustDecision?(prompt, final)
    showNextTrustPrompt()
  }

  private func showNextTrustPrompt() {
    guard pendingTrust == nil, let next = trustQueue.first else { return }
    pendingTrust = next.prompt
  }

  // MARK: Password prompts (memory only)

  /// The remembered password for `host`, or a prompt for one. Returns
  /// `nil` when the user cancels.
  func password(for host: HostProfile, retry: Bool) async -> String? {
    if retry {
      passwords[host.id] = nil
    } else if let known = passwords[host.id] {
      return known
    }
    let prompt = PasswordPrompt(host: host, isRetry: retry)
    let answer = await withCheckedContinuation { continuation in
      passwordQueue.append((prompt, continuation))
      showNextPasswordPrompt()
    }
    if let answer { passwords[host.id] = answer }
    return answer
  }

  /// Drops a password the server rejected.
  func forgetPassword(for host: HostProfile) {
    passwords[host.id] = nil
  }

  /// Answers `pendingPassword`; `nil` cancels.
  public func resolvePassword(_ password: String?) {
    guard let prompt = pendingPassword else { return }
    pendingPassword = nil
    if let index = passwordQueue.firstIndex(where: { $0.prompt.id == prompt.id }) {
      let value = password.flatMap { $0.isEmpty ? nil : $0 }
      passwordQueue.remove(at: index).continuation.resume(returning: value)
    }
    showNextPasswordPrompt()
  }

  private func showNextPasswordPrompt() {
    guard pendingPassword == nil, let next = passwordQueue.first else { return }
    pendingPassword = next.prompt
  }

  // MARK: Companion settings persistence (non-sensitive)

  private static let settingsKey = "companion.settings.v1"

  private static func loadCompanionSettings() -> CompanionSettings {
    guard let data = UserDefaults.standard.data(forKey: settingsKey),
      let settings = try? JSONDecoder().decode(CompanionSettings.self, from: data)
    else { return .default }
    return settings
  }

  private static func saveCompanionSettings(_ settings: CompanionSettings) {
    if let data = try? JSONEncoder().encode(settings) {
      UserDefaults.standard.set(data, forKey: settingsKey)
    }
  }
}

extension HostProfile {
  /// Stand-in profile for the app-local shell; never used for SSH.
  public static let localMachine = HostProfile(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
    nickname: "This Mac",
    host: "localhost",
    username: "local"
  )
}

/// Remembered roaming session per saved host, so a cold launch can resume
/// by session ID (spec §9). Session IDs are not credentials: attaching
/// still needs fresh SSH authorization. Stored in `UserDefaults`.
public struct SessionResumeStore: @unchecked Sendable {
  public static let key = "roaming.resume.v1"
  let defaults: UserDefaults
  let key: String

  public init(defaults: UserDefaults = .standard, key: String = SessionResumeStore.key) {
    self.defaults = defaults
    self.key = key
  }

  /// Host id to session id, skipping malformed entries.
  public func all() -> [UUID: SessionID] {
    guard let raw = defaults.dictionary(forKey: key) as? [String: String] else { return [:] }
    var out: [UUID: SessionID] = [:]
    for (host, session) in raw {
      if let host = UUID(uuidString: host), let session = SessionID(hex: session) {
        out[host] = session
      }
    }
    return out
  }

  public func sessionID(for host: UUID) -> SessionID? { all()[host] }

  public func set(_ session: SessionID?, for host: UUID) {
    var raw = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
    raw[host.uuidString] = session?.hex
    defaults.set(raw, forKey: key)
  }
}

/// Pauses bulk SFTP work while the terminal has unacknowledged input or
/// the app is suspended (spec §10). Transfers wait on `gate`.
@MainActor
@Observable
public final class TransferPausePolicy {
  public let gate = TransferPauseGate()
  /// Whether bulk transfers are currently held.
  public private(set) var isPaused = false
  @ObservationIgnored private var pendingInput = false
  @ObservationIgnored private var suspended = false
  /// Gate updates run in order, each after the previous one.
  @ObservationIgnored private var lastUpdate: Task<Void, Never>?

  public init() {}

  public func setPendingInput(_ pending: Bool) {
    pendingInput = pending
    update()
  }

  public func setSuspended(_ value: Bool) {
    suspended = value
    update()
  }

  private func update() {
    let next = pendingInput || suspended
    guard next != isPaused else { return }
    isPaused = next
    let gate = gate
    let previous = lastUpdate
    lastUpdate = Task {
      await previous?.value
      if next { await gate.pause() } else { await gate.resume() }
    }
  }
}
