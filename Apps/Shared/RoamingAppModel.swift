import CompanionModel
import Foundation

#if canImport(CloudKit) && !os(watchOS)
import CloudKit
#endif
import MuxNavigation
import Observation
import SSHClient
import SSHIdentity
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
  /// The key already matched a pairing code the user confirmed.
  public let matchesPairingCode: Bool

  public init(
    host: HostProfile,
    kind: Kind,
    keyAlgorithm: String,
    fingerprint: String,
    matchesPairingCode: Bool = false
  ) {
    self.host = host
    self.kind = kind
    self.keyAlgorithm = keyAlgorithm
    self.fingerprint = fingerprint
    self.matchesPairingCode = matchesPairingCode
  }
}

/// Which workspace a roaming screen attaches to. Chosen explicitly by the
/// user (workspace chooser, attention link, Resume Last Workspace); a
/// remembered identity is a convenience, never permission to create.
public enum WorkspaceIntent: Hashable, Sendable {
  /// New Workspace: the only intent that sends a create request.
  case create
  /// An existing workspace by identity. With a target, focus its pane
  /// and take over only the lease generation the user confirmed.
  case resume(SessionID, ResumeTarget?)
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

  public var displayName: String {
    switch self {
    case .roaming: "Roaming session"
    case .ordinarySSH: "Ordinary SSH shell"
    }
  }
}

/// The live backend behind a `TerminalScreenModel`; owned by the model so
/// it lives exactly as long as the screen.
@MainActor
protocol TerminalSurfaceController: AnyObject {
  /// Stops main-actor work at once and starts ending the attachment or
  /// channel: `.detach` keeps a roaming host session for a later resume;
  /// `.terminate` destroys it. The returned work never needs the main
  /// actor, so a quit that blocks the main queue can wait for it. Later
  /// calls return the same work.
  func beginClose(_ mode: RoamingCloseMode) -> Task<Void, Never>
  /// `beginClose(_:)`, waiting for it to finish.
  func close(_ mode: RoamingCloseMode) async
}

extension TerminalSurfaceController {
  func close(_ mode: RoamingCloseMode) async { await beginClose(mode).value }
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
  /// Latest change to the status sent to the companion, including screen
  /// and pending-input observations independent of connection state.
  private var companionObservedAt: Date
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
  /// The transport's reason for `lastFailure`, when it reported one.
  public private(set) var lastFailureDetail: String?
  /// Consecutive reconnect attempts since the last success.
  public private(set) var reconnectAttempt = 0
  /// The roaming (QUIC) endpoint SSH authorized, for diagnostics only.
  public private(set) var roamingEndpoint: BootstrapEndpoint?
  /// Supplies the current visible rows for an opted-in companion preview.
  /// Set by the terminal integration; `nil` means no screen yet.
  @ObservationIgnored
  public var previewLines: (@MainActor () -> [String])?
  /// The latest screen with its original observation time. Lifecycle,
  /// input, and companion refreshes never make cached content fresher.
  public var companionPreview: CompanionPreview? {
    guard let lastScreenAt, let lines = previewLines?() else { return nil }
    return CompanionPreview(lines: lines, capturedAt: lastScreenAt)
  }
  /// Called after each observed change (companion bridge, diagnostics).
  @ObservationIgnored
  var onChange: (@MainActor (TerminalScreenModel) -> Void)?
  /// The live backend, created by the surface factory on first display.
  @ObservationIgnored
  var controller: (any TerminalSurfaceController)?
  /// Set when the app closes this screen: a screen still on its way out
  /// never starts another backend.
  @ObservationIgnored
  var isClosed = false

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
      }
    self.stateObservedAt = now
    self.companionObservedAt = now
  }

  /// Applies a lifecycle transition validated by SessionCore. Invalid
  /// transitions are ignored; use `observe` to mirror a backend's actual
  /// state, which may legitimately skip intermediate states.
  public func transition(to next: ClientConnectionState, at now: Date = .now) {
    guard connectionState.canTransition(to: next) else { return }
    connectionState = next
    stateObservedAt = now
    companionObservedAt = now
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
    if status.lastFailureDetail != lastFailureDetail {
      lastFailureDetail = status.lastFailureDetail
    }
    if status.reconnectAttempt != reconnectAttempt {
      reconnectAttempt = status.reconnectAttempt
    }
    if status.roamingEndpoint != roamingEndpoint {
      roamingEndpoint = status.roamingEndpoint
    }
    if changed {
      companionObservedAt = now
      onChange?(self)
    }
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
    guard next != connectionState, connectionState != .userClosed else {
      return
    }
    connectionState = next
    stateObservedAt = now
    companionObservedAt = now
    onChange?(self)
  }

  /// A complete screen was installed.
  public func screenInstalled(at now: Date = .now) {
    lastScreenAt = now
    companionObservedAt = now
    onChange?(self)
  }

  public func setPendingInputCount(_ count: Int, at now: Date = .now) {
    let bounded = max(0, count)
    if bounded != pendingInputCount { companionObservedAt = now }
    pendingInputCount = bounded
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
      observedAt: companionObservedAt,
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
  /// Saved hosts visible on this device (local-only, or bound to the
  /// current iCloud account).
  public private(set) var hosts: [HostProfile] = []
  /// The committed non-secret connection state (spec.ssh-identity.md §5).
  public private(set) var connections = ConnectionSnapshot()
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
  public var onSessionObservation:
    (@MainActor (PhoneCompanionBridge.Observation) -> Void)?
  /// Redacted inbox summaries after each refresh, for the watch bridge.
  @ObservationIgnored
  public var onAttentionSummaries: (@MainActor ([AttentionSummary]) -> Void)?

  @ObservationIgnored
  public var onCompanionSettingsChange:
    (@MainActor (CompanionSettings) -> Void)?
  /// Observes the user's answer to each `pendingTrust` (diagnostics).
  @ObservationIgnored
  public var onTrustDecision: (@MainActor (TrustPrompt, TrustDecision) -> Void)?

  /// Bulk SFTP work waits here while terminal input is unacknowledged
  /// (spec §10) or the app is suspended.
  public let transferPolicy = TransferPausePolicy()

  @ObservationIgnored
  let store: ConnectionStore
  /// A failed load must not be overwritten by a later save of the
  /// in-memory list. Cleared only by a load that reads the file.
  @ObservationIgnored
  private var savedHostsReadable = true
  @ObservationIgnored
  private let resumeStore: SessionResumeStore
  /// Explicit workspace choices waiting for their host's next roaming
  /// start (chooser selections and attention links).
  @ObservationIgnored
  private var pendingIntents: [UUID: WorkspaceIntent] = [:]
  @ObservationIgnored
  private var trustQueue:
    [(
      prompt: TrustPrompt,
      continuation: CheckedContinuation<TrustDecision, Never>?
    )] = []
  /// Keep approvals invalidatable until the waiting caller consumes them.
  @ObservationIgnored
  private var trustRequests: [UUID: HostProfile] = [:]
  @ObservationIgnored
  private var passwordQueue:
    [(
      prompt: PasswordPrompt, continuation: CheckedContinuation<String?, Never>
    )] = []
  /// Includes answered continuations whose callers have not resumed yet.
  /// Removing a request invalidates its answer without a growing epoch map.
  @ObservationIgnored
  private var passwordRequests: [UUID: HostProfile] = [:]
  /// Session passwords, in memory only, never logged or persisted.
  @ObservationIgnored
  private var passwords: [UUID: (host: HostProfile, value: String)] = [:]
  @ObservationIgnored
  private var sshAccess: SSHAccess?
  /// Closes still in flight; a quit waits for them (spec §9).
  @ObservationIgnored
  private var closing: [UUID: Task<Void, Never>] = [:]

  /// SSH identities: generation, import, migration and resolution.
  @ObservationIgnored
  public private(set) var identityStore: SSHIdentityStore!
  /// Opt-in CloudKit metadata sync, when the build is configured for it.
  @ObservationIgnored
  public private(set) var sync: ConnectionSyncCoordinator?
  @ObservationIgnored
  private var accountObserver: (any NSObjectProtocol)?

  public init(
    profile: PlatformProfile = .current,
    store: ConnectionStore = ConnectionStore(
      fileURL: ConnectionStore.defaultURL()
    ),
    resumeStore: SessionResumeStore = SessionResumeStore(
      defaults: UITesting.defaults ?? .standard
    ),
    secrets: (any IdentitySecretStore)? = nil,
    legacyKeys: (any LegacyKeySource)? = nil,
    cloud: (any ConnectionCloudDatabase)? = nil
  ) {
    self.profile = profile
    self.store = store
    self.resumeStore = resumeStore
    self.companionSettings = Self.loadCompanionSettings()
    self.resumableHosts = Set(resumeStore.all().keys)
    self.identityStore = SSHIdentityStore(
      app: self,
      secrets: secrets ?? IdentityKeychainConfiguration.secretStore(),
      legacy: legacyKeys ?? IdentityKeychainConfiguration.legacyKeySource()
    )
    if let cloud = cloud ?? CloudKitConnectionDatabase.configured(),
      profile.cloudSync
    {
      let sync = ConnectionSyncCoordinator(app: self, database: cloud)
      self.sync = sync
      // An iCloud identity needs a verified current account (§8.4).
      identityStore.verifyICloudAccount = { [weak sync] in
        guard let sync else { return false }
        return (try? await sync.database.accountID()) != nil
      }
      #if canImport(CloudKit) && !os(watchOS)
      accountObserver = NotificationCenter.default.addObserver(
        forName: .CKAccountChanged,
        object: nil,
        queue: .main
      ) { [weak sync] _ in
        MainActor.assumeIsolated { sync?.accountDidChange() }
      }
      #endif
    }
  }

  /// SSH connection services: trust store, credentials, prompts.
  var ssh: SSHAccess {
    if let sshAccess { return sshAccess }
    // Trusted host keys live beside the connection snapshot (in production
    // both are in `RoamingStorage.directory`).
    let access = SSHAccess(
      app: self,
      trustStore: FileHostTrustStore(
        fileURL: store.fileURL.deletingLastPathComponent()
          .appending(path: "known_hosts.json", directoryHint: .notDirectory)
      )
    )
    sshAccess = access
    return access
  }

  // MARK: Hosts

  public func load() {
    do {
      let loaded = try store.loadSnapshot()
      apply(loaded)
      savedHostsReadable = true
      lastError = nil
    } catch {
      savedHostsReadable = false
      lastError = "Saved hosts could not be read."
      return
    }
    // Version-1 labels move to stable identities before any new identity
    // write or sync (spec.ssh-identity.md §9); interrupted identity
    // operations resume.
    if !connections.migration.completed || !connections.intents.isEmpty
      || !connections.migration.pendingCleanup.isEmpty
    {
      identityStore.startRecovery()
    }
  }

  /// Installs a committed snapshot and invalidates prompts for hosts whose
  /// saved profile changed.
  private func apply(_ snapshot: ConnectionSnapshot) {
    let visible = snapshot.visibleHosts
    let identities = Set(visible)
    let changed = hosts.filter { !identities.contains($0) }
    connections = snapshot
    hosts = visible
    for host in changed { invalidateConnectionPrompts(for: host) }
  }

  /// Applies `mutate` to a copy of the snapshot and commits it atomically.
  /// The in-memory state advances only after the write succeeds; a store
  /// that could not be read is never overwritten.
  @discardableResult
  func commitConnections(
    notifySync: Bool = true,
    _ mutate: (inout ConnectionSnapshot) throws(ConnectionStore.StoreError) -> Void
  ) -> Bool {
    guard savedHostsReadable else {
      lastError = "Saved hosts could not be read."
      return false
    }
    var next = connections
    do {
      try mutate(&next)
      guard next != connections else { return true }
      try store.commit(next)
    } catch .tooManyHosts {
      lastError = "You can save up to \(ConnectionStore.maxHosts) hosts."
      return false
    } catch .tooManyIdentities {
      lastError = "You can save up to \(ConnectionStore.maxIdentities) keys."
      return false
    } catch {
      lastError = "Saved hosts could not be written."
      return false
    }
    apply(next)
    lastError = nil
    if notifySync { sync?.localChange() }
    return true
  }

  /// Adds or replaces `host` (matched by id) after validation.
  /// Returns false if persistence failed; the saved list stays unchanged.
  @discardableResult
  public func save(
    _ host: HostProfile
  ) throws(HostProfile.ValidationError) -> Bool {
    try host.validate()
    return commitConnections { snapshot throws(ConnectionStore.StoreError) in
      if !snapshot.hosts.contains(where: { $0.id == host.id }),
        snapshot.hosts.count >= ConnectionStore.maxHosts
      {
        throw .tooManyHosts
      }
      snapshot.upsertHost(host)
    }
  }

  public func delete(_ host: HostProfile) {
    guard commitConnections({ $0.deleteHost(host.id) }) else { return }
    if activeSession?.host.id == host.id { close() }
    invalidateConnectionPrompts(for: host)
    forgetSession(for: host)
    pendingIntents[host.id] = nil
  }

  private func invalidateConnectionPrompts(for host: HostProfile) {
    passwords[host.id] = nil
    invalidatePasswordRequests { $0.id == host.id }
    trustRequests = trustRequests.filter { $0.value.id != host.id }
    let ids = trustQueue.filter { $0.prompt.host.id == host.id }
      .map { $0.prompt.id }
    for id in ids { cancelTrust(id) }
  }

  // MARK: Identities

  /// SSH identities visible on this device, by name.
  public var identities: [SSHIdentityMetadata] {
    connections.visibleIdentities.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  public func identity(_ id: UUID) -> SSHIdentityMetadata? {
    connections.identity(id)
  }

  /// The sign-in summary shown under a host.
  public func authSummary(for host: HostProfile) -> String {
    guard case .key(let id) = host.auth else { return host.auth.summary }
    guard let identity = identity(id), !identity.isDeleted else {
      return "SSH key (deleted or unavailable)"
    }
    return "Key \u{201C}\(identity.name)\u{201D}"
  }

  // MARK: Session

  /// Opens the terminal screen for `host`, replacing any other session in
  /// this app (one active roaming terminal per client). Replacing a
  /// roaming session detaches it; the host keeps the shell.
  public func open(_ host: HostProfile, kind: TerminalKind = .roaming) {
    if let activeSession, activeSession.host.id == host.id,
      activeSession.kind == kind
    {
      return
    }
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

  /// Closes the active terminal view. `.detach` keeps a roaming host
  /// shell for a later resume (spec §4); `.terminate` destroys it.
  public func close(_ mode: RoamingCloseMode = .detach) {
    guard let session = activeSession else { return }
    session.isClosed = true
    if let controller = session.controller {
      session.controller = nil
      let id = UUID()
      let work = controller.beginClose(mode)
      closing[id] = work
      Task { [weak self] in
        await work.value
        self?.closing[id] = nil
      }
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

  /// How long a quit waits for closes: the roaming detach bound, plus a
  /// second for the channel and connection closes that follow.
  static let terminationWait =
    RoamingClientConfiguration.defaultDetachDeadline + .seconds(1)

  /// A quit the platform cannot defer (Mac Catalyst's
  /// `applicationWillTerminate`): detaches the active session, then waits
  /// up to `terminationWait` for it and for every close still in flight.
  /// The helper also retains sessions whose detach never arrives (spec §9).
  public func detachBeforeExit() {
    close(.detach)
    guard !closing.isEmpty else { return }
    let finished = DispatchGroup()
    for work in closing.values {
      finished.enter()
      // The blocked main thread donates no priority; awaiting at high
      // priority escalates the close instead.
      Task.detached(priority: .high) {
        await work.value
        finished.leave()
      }
    }
    let (seconds, attoseconds) = Self.terminationWait.components
    _ = finished.wait(
      timeout: .now() + Double(seconds) + Double(attoseconds) / 1e18
    )
  }

  /// Opens `workspace` on `host` from an attention link: the next start
  /// resumes it, focuses `target.pane` and takes over only the lease the
  /// user confirmed (`target.expectedLease`). Replaces the active session.
  public func reveal(
    _ host: HostProfile,
    workspace: SessionID,
    target: ResumeTarget
  ) { openWorkspace(host, intent: .resume(workspace, target)) }

  /// Attaches the one active roaming terminal to the workspace the user
  /// chose. The previous terminal is detached through the ordinary close,
  /// never ended. Choosing the workspace already shown changes nothing.
  public func openWorkspace(_ host: HostProfile, intent: WorkspaceIntent) {
    // A reveal (pane focus or takeover) always reattaches.
    if case let .resume(id, nil) = intent, let active = activeSession,
      active.host == host, active.kind == .roaming, active.sessionID == id
    {
      return
    }
    if activeSession != nil { close() }
    if case let .resume(id, _) = intent { rememberSession(id, for: host) }
    pendingIntents[host.id] = intent
    open(host)
  }

  /// Resume Last Workspace: the remembered identity only. Returns false,
  /// creating nothing, when no workspace is remembered for `host`.
  @discardableResult
  public func resumeLastWorkspace(_ host: HostProfile) -> Bool {
    guard let id = resumableSessionID(for: host) else { return false }
    openWorkspace(host, intent: .resume(id, nil))
    return true
  }

  /// The explicit choice for `host`'s next start, consumed once.
  func takeIntent(for host: HostProfile) -> WorkspaceIntent? {
    pendingIntents.removeValue(forKey: host.id)
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

  /// Includes the visible prompt. Overflow is rejected without suspending.
  static let maxPendingConnectionPrompts = 32

  /// Shows `prompt` (queued behind any other) and waits for the user. A
  /// changed key is always answered `.reject`. Rejects overflow or an ID
  /// already awaiting a decision.
  public func requestTrust(_ prompt: TrustPrompt) async -> TrustDecision {
    guard !Task.isCancelled,
      trustRequests.count < Self.maxPendingConnectionPrompts,
      trustRequests[prompt.id] == nil
    else { return .reject }
    trustRequests[prompt.id] = prompt.host
    defer { trustRequests[prompt.id] = nil }
    let decision = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled
          || trustQueue.count >= Self.maxPendingConnectionPrompts
          || trustQueue.contains(where: { $0.prompt.id == prompt.id })
        {
          continuation.resume(returning: TrustDecision.reject)
        } else {
          trustQueue.append((prompt, continuation))
          showNextTrustPrompt()
          // Cancellation can win before this append. The handler then
          // finds nothing to resume, so re-check before waiting.
          if Task.isCancelled { cancelTrust(prompt.id) }
        }
      }
    } onCancel: {
      self.resumePromptCancellation { self.cancelTrust(prompt.id) }
    }
    return Task.isCancelled || trustRequests[prompt.id] != prompt.host
      ? .reject : decision
  }

  /// A changed key blocks sign-in already: its notice needs no waiting task.
  /// Coalesce repeat notices while preserving the visible prompt and decisions.
  func notifyChangedKey(_ prompt: TrustPrompt) {
    guard prompt.kind == .changedKey,
      trustQueue.count < Self.maxPendingConnectionPrompts,
      !trustQueue.contains(where: {
        $0.prompt.kind == .changedKey && $0.prompt.host == prompt.host
          && $0.prompt.fingerprint == prompt.fingerprint
      })
    else { return }
    trustQueue.append((prompt, nil))
    showNextTrustPrompt()
  }

  /// Resumes the prompt on this turn when cancellation is already on the
  /// main thread. A later unstructured hop misses the one-second wait
  /// while the main actor is busy, and a hop that runs before enqueue
  /// never resumes the continuation.
  nonisolated private func resumePromptCancellation(
    _ cancel: @escaping @MainActor () -> Void
  ) {
    if Thread.isMainThread {
      MainActor.assumeIsolated(cancel)
    } else {
      Task { @MainActor in cancel() }
    }
  }

  private func cancelTrust(_ id: UUID) {
    guard let index = trustQueue.firstIndex(where: { $0.prompt.id == id })
    else { return }
    let cancelled = trustQueue.remove(at: index)
    if pendingTrust?.id == id { pendingTrust = nil }
    cancelled.continuation?.resume(returning: .reject)
    showNextTrustPrompt()
  }

  /// View callbacks pass their prompt id, so a stale sheet cannot
  /// answer a different host's newly displayed prompt.
  public func resolveTrust(_ decision: TrustDecision, for id: UUID? = nil) {
    guard let prompt = pendingTrust, id == nil || id == prompt.id else {
      return
    }
    pendingTrust = nil
    let final = prompt.kind == .changedKey ? .reject : decision
    if let index = trustQueue.firstIndex(where: { $0.prompt.id == prompt.id }) {
      trustQueue.remove(at: index).continuation?.resume(returning: final)
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
  func password(
    for host: HostProfile,
    retry: Bool,
    rejectedPassword: String? = nil
  ) async -> String? {
    guard !Task.isCancelled else { return nil }
    if retry {
      if let rejectedPassword {
        forgetRejectedPassword(rejectedPassword, for: host)
        if let known = passwords[host.id], known.host == host {
          return known.value
        }
      } else {
        forgetPassword(for: host)
      }
    } else if let known = passwords[host.id], known.host == host {
      return known.value
    }
    guard passwordRequests.count < Self.maxPendingConnectionPrompts else {
      return nil
    }
    let prompt = PasswordPrompt(host: host, isRetry: retry)
    passwordRequests[prompt.id] = host
    defer { passwordRequests[prompt.id] = nil }
    let answer: String? = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled
          || passwordQueue.count >= Self.maxPendingConnectionPrompts
        {
          continuation.resume(returning: nil)
        } else {
          passwordQueue.append((prompt, continuation))
          showNextPasswordPrompt()
          if Task.isCancelled { cancelPassword(prompt.id) }
        }
      }
    } onCancel: {
      self.resumePromptCancellation { self.cancelPassword(prompt.id) }
    }
    guard !Task.isCancelled, passwordRequests[prompt.id] == host else {
      return nil
    }
    let current = hosts.first { $0.id == host.id }
    if let answer, current == nil || current == host {
      passwords[host.id] = (host, answer)
    }
    return answer
  }

  private func cancelPassword(_ id: UUID) {
    guard let index = passwordQueue.firstIndex(where: { $0.prompt.id == id })
    else { return }
    let cancelled = passwordQueue.remove(at: index)
    if pendingPassword?.id == id { pendingPassword = nil }
    cancelled.continuation.resume(returning: nil)
    showNextPasswordPrompt()
  }

  /// Invalidates remembered and pending passwords for this exact profile.
  func forgetPassword(for host: HostProfile) {
    if passwords[host.id]?.host == host { passwords[host.id] = nil }
    invalidatePasswordRequests { $0 == host }
  }

  /// An older attempt may reject a different password or profile. Its failure
  /// must not cancel fresh consent or clear a newer remembered credential.
  func forgetRejectedPassword(_ password: String, for host: HostProfile) {
    guard let known = passwords[host.id], known.host == host,
      known.value == password
    else { return }
    passwords[host.id] = nil
  }

  private func invalidatePasswordRequests(
    matching matches: (HostProfile) -> Bool
  ) {
    passwordRequests = passwordRequests.filter { !matches($0.value) }
    let ids = passwordQueue.filter { matches($0.prompt.host) }
      .map { $0.prompt.id }
    for id in ids { cancelPassword(id) }
  }

  /// Answers `pendingPassword`; `nil` cancels.
  /// View callbacks pass the prompt id to reject stale answers.
  public func resolvePassword(_ password: String?, for id: UUID? = nil) {
    guard let prompt = pendingPassword, id == nil || id == prompt.id else {
      return
    }
    pendingPassword = nil
    if let index = passwordQueue.firstIndex(where: { $0.prompt.id == prompt.id }
    ) {
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
      let settings = try? JSONDecoder()
        .decode(CompanionSettings.self, from: data)
    else { return .default }
    return settings
  }

  private static func saveCompanionSettings(_ settings: CompanionSettings) {
    if let data = try? JSONEncoder().encode(settings) {
      UserDefaults.standard.set(data, forKey: settingsKey)
    }
  }
}

/// Remembered roaming session per saved host, so a cold launch can resume
/// by session ID (spec §9). Session IDs are not credentials: attaching
/// still needs fresh SSH authorization. Stored in `UserDefaults`.
public struct SessionResumeStore: @unchecked Sendable {
  public static let key = "roaming.resume.v1"
  // UserDefaults synchronizes individual operations, not read/modify/write.
  // Share ownership across instances, including separate handles for one suite.
  // Recursive locking permits synchronous defaults observers to read the store.
  private static let access = NSRecursiveLock()
  let defaults: UserDefaults
  let key: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = SessionResumeStore.key,
  ) {
    self.defaults = defaults
    self.key = key
  }

  /// Host id to session id, skipping malformed entries.
  public func all() -> [UUID: SessionID] {
    Self.access.lock()
    defer { Self.access.unlock() }
    guard let raw = defaults.dictionary(forKey: key) else { return [:] }
    var out: [UUID: SessionID] = [:]
    for (host, session) in raw {
      if let session = session as? String, let host = UUID(uuidString: host),
        let session = SessionID(hex: session)
      {
        out[host] = session
      }
    }
    return out
  }

  public func sessionID(for host: UUID) -> SessionID? { all()[host] }

  public func set(_ session: SessionID?, for host: UUID) {
    Self.access.lock()
    defer { Self.access.unlock() }
    var raw = defaults.dictionary(forKey: key) ?? [:]
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
  @ObservationIgnored
  private var pendingInput = false
  @ObservationIgnored
  private var suspended = false
  /// Gate updates run in order, each after the previous one.
  @ObservationIgnored
  private var lastUpdate: Task<Void, Never>?

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
