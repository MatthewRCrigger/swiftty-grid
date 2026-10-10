import Foundation
import Network
import Observation
import SSHClient
import ScreenProtocol
import SessionCore
import SwiftUI
import SwifttyCore
import Synchronization
import TerminalSurface

#if os(macOS) && !targetEnvironment(macCatalyst)
  import AppKit
  import SwifttyMac
#endif

// The live terminal surfaces behind `TerminalScreen` (replacing the
// former placeholder): one MainActor controller per opened
// `TerminalScreenModel`, owning the display session and its backend.

extension TerminalSurfaceFactory {
  /// Real surfaces for `app`'s sessions: a roaming presentation fed by
  /// `RoamingClient`, an ordinary SSH shell, or (native macOS) a local PTY.
  public static func live(_ app: RoamingAppModel) -> TerminalSurfaceFactory {
    TerminalSurfaceFactory { [weak app] model in
      guard let app else { return AnyView(EmptyView()) }
      return AnyView(LiveTerminalSurface(model: model, app: app))
    }
  }
}

/// What a surface can offer when it cannot show a working terminal.
enum SurfaceAction: Hashable, Sendable {
  /// Try the same thing again (fresh SSH authorization).
  case retry
  /// Forget the old roaming session and create a new one.
  case startNewSession
  /// Open an ordinary SSH shell: a different shell (spec §9).
  case openOrdinarySSH
}

/// A nonsecret explanation of why no working terminal is shown.
struct SurfaceProblem: Hashable, Sendable {
  var title: String
  var detail: String
  var actions: [SurfaceAction]
}

enum SurfacePhase: Hashable, Sendable {
  /// Sign-in or setup in progress, with a short description.
  case preparing(String)
  /// The backend owns the state; the status bar mirrors it.
  case running
  case failed(SurfaceProblem)
}

/// Holds the current client for nonisolated input submission.
final class ClientSlot: Sendable {
  private let value = Mutex<RoamingClient?>(nil)

  var client: RoamingClient? { value.withLock { $0 } }

  func set(_ client: RoamingClient?) { value.withLock { $0 = client } }
}

// MARK: - Roaming

/// One roaming terminal: a presentation-mode `TerminalSession` displaying
/// frames from a `RoamingClient` built from the host profile.
///
/// Sign-in runs one interactive SSH connection first (password prompt,
/// explicit unknown-key decision); the client's own bootstraps afterwards
/// use `RejectUnknownHostKeys`, so automatic reconnects never prompt.
@MainActor
@Observable
final class RoamingTerminalController: TerminalSurfaceController {
  enum StartChoice {
    /// Resume the remembered session if any, else create one.
    case automatic
    /// Forget any remembered session and create a new one.
    case newSession
  }

  let model: TerminalScreenModel
  let display: TerminalSession
  private(set) var phase: SurfacePhase = .preparing("Signing in")

  @ObservationIgnored private weak var app: RoamingAppModel?
  @ObservationIgnored private let slot: ClientSlot
  @ObservationIgnored private let pump: OrderedInputPump
  @ObservationIgnored private var client: RoamingClient?
  @ObservationIgnored private var grid = GridSize(columns: 80, rows: 24)
  @ObservationIgnored private var runTask: Task<Void, Never>?
  /// Lifecycle and grid calls to the client, applied in order.
  @ObservationIgnored private var serialTask: Task<Void, Never>?
  @ObservationIgnored private var closed = false
  @ObservationIgnored private var started = false
  @ObservationIgnored private var monitor: NWPathMonitor?
  @ObservationIgnored private var pathSeen = false
  @ObservationIgnored private var observers: [any NSObjectProtocol] = []

  init(model: TerminalScreenModel, app: RoamingAppModel) {
    self.model = model
    self.app = app
    let display = TerminalSession(
      presentationColumns: 80,
      rows: 24,
      configuration: Configuration().sessionConfiguration()
    )
    self.display = display
    let slot = ClientSlot()
    self.slot = slot
    pump = OrderedInputPump(submit: { input in
      guard let client = slot.client else { return .refused(.notActive(.idle)) }
      return await client.submit(input)
    })
    // Semantic input arrives on the session queue, in order; the pump
    // keeps that order across the hop to the client actor.
    display.semanticInputHandler = { [pump] input in
      if let input = SurfaceInput(input) { pump.enqueue(input) }
    }
    display.gridProposalHandler = { [weak self] columns, rows in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.propose(columns: columns, rows: rows) }
      }
    }
    model.previewLines = { [display] in display.withState { $0.screenLines } }
    observeSystem()
  }

  /// First display: start once. Later attempts are explicit user actions,
  /// so a lost session is never silently replaced by a new one.
  func startIfNeeded() {
    guard !started else { return }
    start()
  }

  /// Starts (or retries) sign-in and attachment. No-op while running.
  func start(_ choice: StartChoice = .automatic) {
    guard !closed, runTask == nil else { return }
    started = true
    runTask = Task {
      await run(choice)
      runTask = nil
    }
  }

  private func run(_ choice: StartChoice) async {
    guard let app else { return }
    let host = model.host
    phase = .preparing("Signing in")
    if let old = client {
      client = nil
      slot.set(nil)
      await old.close(.detach)
    }
    let credential: SSHCredential
    do {
      // Interactive trust and credential check; the client's own SSH
      // bootstraps then run without prompts.
      let probe = try await app.ssh.connect(host)
      await probe.close()
      credential = try await app.ssh.credential(for: host)
    } catch {
      guard !closed else { return }
      phase = .failed(Self.problem(for: error))
      return
    }
    guard !closed, !Task.isCancelled else { return }

    let client = RoamingClient(
      bootstrapper: SSHBootstrapper(endpoint: app.ssh.endpoint(for: host, credential: credential)),
      connector: QUICGrantConnector(),
      sink: display,
      configuration: RoamingClientConfiguration(initialGrid: grid)
    )
    self.client = client
    slot.set(client)
    let token = ObjectIdentifier(client)
    await client.setStatusHandler { [weak self] status in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.apply(status, from: token) }
      }
    }

    if choice == .newSession { app.forgetSession(for: host) }
    let resume = app.resumableSessionID(for: host)
    let reveal = app.takeReveal(for: host)
    phase = .preparing(resume == nil ? "Starting session" : "Resuming session")
    do {
      let target: RoamingTarget =
        switch (resume, reveal) {
        case let (id?, reveal?): .reveal(id, reveal)
        case let (id?, nil): .resume(id)
        case (nil, _): .create(grid)
        }
      try await client.start(target)
      guard !closed else { return }
      if case .preparing = phase { phase = .running }
    } catch {
      guard !closed, self.client === client else { return }
      if error == .sessionLost || error == .sessionExited {
        app.forgetSession(for: host)
      }
      if error == .authenticationFailed { app.forgetPassword(for: host) }
      phase = .failed(Self.problem(for: error, resuming: resume != nil))
    }
  }

  private func apply(_ status: RoamingStatus, from token: ObjectIdentifier) {
    guard !closed, let client, ObjectIdentifier(client) == token else { return }
    model.observe(status)
    guard let app else { return }
    switch status.state {
    case .sessionLost:
      app.forgetSession(for: model.host)
      phase = .failed(Self.problem(for: .sessionLost, resuming: false))
    case .sessionExited:
      app.forgetSession(for: model.host)
      phase = .failed(Self.exited(status.exitStatus))
    case .userClosed:
      break
    default:
      if let id = status.sessionID { app.rememberSession(id, for: model.host) }
      if status.state == .active, phase != .running { phase = .running }
    }
  }

  /// Whether to offer the ordinary-SSH fallback while the roaming
  /// attachment keeps failing (e.g. UDP blocked; spec §9).
  var offersOrdinarySSH: Bool {
    guard model.profile.sshShell, phase == .running else { return false }
    switch model.connectionState {
    case .attaching, .reconnecting:
      return model.reconnectAttempt >= 2 || model.lastFailure == .attachTimedOut
    default:
      return false
    }
  }

  // MARK: Lifecycle

  /// Mobile, spatial and TV scenes detach in the background and
  /// reattach in the foreground. A Mac (native or Catalyst) window
  /// losing focus is not a suspension (spec §9).
  func scenePhaseChanged(_ phase: ScenePhase) {
    switch model.profile.kind {
    case .mac, .catalyst: return
    case .mobile, .vision, .tv: break
    }
    switch phase {
    case .background: serial { await $0.enterBackground() }
    case .active: serial { await $0.enterForeground() }
    default: break
    }
  }

  private func propose(columns: Int, rows: Int) {
    let next = GridSize(
      columns: min(max(columns, 1), RSTLimits.maxColumns),
      rows: min(max(rows, 1), RSTLimits.maxRows)
    )
    guard next != grid else { return }
    grid = next
    serial { await $0.proposeGrid(columns: next.columns, rows: next.rows) }
  }

  private func serial(_ operation: @escaping @Sendable (RoamingClient) async -> Void) {
    guard let client, !closed else { return }
    let previous = serialTask
    serialTask = Task {
      await previous?.value
      await operation(client)
    }
  }

  private func observeSystem() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.pathChanged() }
      }
    }
    monitor.start(queue: DispatchQueue(label: "dev.swiftty.roaming.path"))
    self.monitor = monitor
    #if os(macOS) && !targetEnvironment(macCatalyst)
      // Native macOS: sleep detaches, wake reattaches; focus does not.
      let center = NSWorkspace.shared.notificationCenter
      observers.append(
        center.addObserver(
          forName: NSWorkspace.willSleepNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.serial { await $0.enterBackground() } }
        }
      )
      observers.append(
        center.addObserver(
          forName: NSWorkspace.didWakeNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.serial { await $0.wake() } }
        }
      )
    #endif
  }

  /// A path change is a hint to probe, never proof of failure.
  private func pathChanged() {
    guard pathSeen else {
      pathSeen = true
      return
    }
    serial { await $0.pathChanged() }
  }

  func close(_ mode: RoamingCloseMode) async {
    guard !closed else { return }
    closed = true
    runTask?.cancel()
    pump.close()
    monitor?.cancel()
    #if os(macOS) && !targetEnvironment(macCatalyst)
      for observer in observers {
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
      }
    #endif
    observers = []
    display.semanticInputHandler = nil
    display.gridProposalHandler = nil
    if let client {
      await serialTask?.value
      await client.close(mode)
      await client.setStatusHandler(nil)
    }
    slot.set(nil)
  }

  // MARK: Messages

  static func problem(for error: SSHAccessError) -> SurfaceProblem {
    let actions: [SurfaceAction] =
      switch error {
      case .hostKeyChanged, .trustStoreUnavailable: []
      default: [.retry]
      }
    return SurfaceProblem(title: error.title, detail: error.detail, actions: actions)
  }

  static func problem(for error: RoamingClientError, resuming: Bool) -> SurfaceProblem {
    switch error {
    case .sessionLost:
      SurfaceProblem(
        title: resuming ? "Previous session no longer exists" : "Session lost",
        detail:
          "The Mac no longer has this session: it expired, was terminated, or the "
          + "helper restarted. Nothing was replayed into another shell.",
        actions: [.startNewSession]
      )
    case .sessionExited:
      exited(nil)
    case .unreachable:
      SurfaceProblem(
        title: "Mac unreachable over SSH",
        detail: "The session is kept on the Mac. Try again when the network is back.",
        actions: [.retry]
      )
    case .hostKeyRejected:
      SurfaceProblem(
        title: "Host key not trusted",
        detail: "The connection was closed before any credentials were sent.",
        actions: [.retry]
      )
    case .authenticationFailed:
      SurfaceProblem(
        title: "Authentication failed",
        detail: "The server rejected the credentials.",
        actions: [.retry]
      )
    case .protocolViolation:
      SurfaceProblem(
        title: "Roaming helper unavailable",
        detail:
          "swifttyd did not answer at \(defaultHelperPath). Install it on the Mac, "
          + "or use an ordinary SSH shell.",
        actions: [.retry, .openOrdinarySSH]
      )
    case let .rejected(code):
      SurfaceProblem(
        title: "Roaming session refused",
        detail: "The Mac refused the request (\(code)).",
        actions: [.retry, .openOrdinarySSH]
      )
    case .invalidState:
      SurfaceProblem(
        title: "Session busy",
        detail: "Another attempt is still in progress.",
        actions: [.retry]
      )
    }
  }

  static func exited(_ status: Int32?) -> SurfaceProblem {
    SurfaceProblem(
      title: "Session exited",
      detail: status.map { "The shell exited with status \($0)." }
        ?? "The shell on the Mac has exited.",
      actions: [.startNewSession]
    )
  }
}

// MARK: - Ordinary SSH

/// An ordinary SSH shell (spec §A.3.B): a local `TerminalSession` fed
/// by an SSH shell channel. A different shell from any roaming session;
/// it ends with its connection and is never resumed.
@MainActor
@Observable
final class SSHShellController: TerminalSurfaceController {
  let model: TerminalScreenModel
  let session: TerminalSession
  private(set) var phase: SurfacePhase = .preparing("Signing in")

  @ObservationIgnored private weak var app: RoamingAppModel?
  @ObservationIgnored private var backend: SSHStreamBackend?
  @ObservationIgnored private var connection: SSHConnection?
  @ObservationIgnored private var runTask: Task<Void, Never>?
  @ObservationIgnored private var closed = false
  @ObservationIgnored private var started = false

  init(model: TerminalScreenModel, app: RoamingAppModel) {
    self.model = model
    self.app = app
    let session = TerminalSession(
      columns: 80,
      rows: 24,
      configuration: Configuration().sessionConfiguration()
    )
    self.session = session
    model.previewLines = { [session] in session.withState { $0.screenLines } }
  }

  /// Opens the shell once; a new shell needs a new screen.
  func start() {
    guard !closed, runTask == nil, backend == nil, !started else { return }
    started = true
    runTask = Task {
      await run()
      runTask = nil
    }
  }

  private func run() async {
    guard let app else { return }
    phase = .preparing("Signing in")
    model.observe(.connecting)
    do {
      let connection = try await app.ssh.connect(model.host)
      guard !closed else {
        await connection.close()
        return
      }
      self.connection = connection
      phase = .preparing("Opening shell")
      let (columns, rows) = session.withState { ($0.columns, $0.rows) }
      let channel = try await SSHShellByteChannel.open(
        on: connection,
        columns: columns,
        rows: rows
      )
      guard !closed else {
        await channel.close()
        return
      }
      let backend = SSHStreamBackend(channel: channel, session: session)
      backend.onLifecycleChange = { [weak self] lifecycle in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.apply(lifecycle) }
        }
      }
      self.backend = backend
      phase = .running
      backend.start()
    } catch let error as SSHAccessError {
      guard !closed else { return }
      phase = .failed(RoamingTerminalController.problem(for: error))
    } catch {
      guard !closed else { return }
      model.observe(.lost)
      phase = .failed(
        SurfaceProblem(
          title: "Shell unavailable",
          detail: "The Mac refused to open a shell on this connection.",
          actions: [.retry]
        )
      )
    }
  }

  private func apply(_ lifecycle: SurfaceLifecycle) {
    guard !closed else { return }
    model.observe(lifecycle)
    switch lifecycle {
    case .lost:
      phase = .failed(
        SurfaceProblem(
          title: "SSH connection lost",
          detail:
            "This ordinary SSH shell ended with its connection and cannot be resumed. "
            + "A roaming session on the Mac is not affected.",
          actions: [.retry]
        )
      )
    case let .exited(status):
      phase = .failed(
        SurfaceProblem(
          title: "Shell exited",
          detail: status.map { "The shell exited with status \($0)." } ?? "The shell exited.",
          actions: [.retry]
        )
      )
    default: break
    }
  }

  func close(_ mode: RoamingCloseMode) async {
    guard !closed else { return }
    closed = true
    runTask?.cancel()
    await backend?.close()
    await connection?.close()
  }
}

// MARK: - Local shell (native macOS only)

#if os(macOS) && !targetEnvironment(macCatalyst)
  /// The app-local PTY (spec §A.3.A). Its lifetime is the app's.
  @MainActor
  @Observable
  final class LocalShellController: TerminalSurfaceController {
    let model: TerminalScreenModel
    let backend: LocalPTYBackend
    private(set) var phase: SurfacePhase = .preparing("Starting shell")
    @ObservationIgnored private var started = false

    init(model: TerminalScreenModel) {
      self.model = model
      let session = TerminalSession(configuration: Configuration().sessionConfiguration())
      backend = LocalPTYBackend(session: session)
      model.previewLines = { [session] in session.withState { $0.screenLines } }
    }

    /// Starts the shell once `view` hosts the session, keeping the
    /// view's own event handling behind the backend's exit tracking.
    func attach(_ view: TerminalView) {
      guard !started else { return }
      started = true
      backend.onEvent = backend.session.onEvent
      backend.onLifecycleChange = { [weak self] lifecycle in
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self?.apply(lifecycle) }
        }
      }
      do {
        try backend.start(Configuration().sessionConfiguration())
        phase = .running
      } catch {
        phase = .failed(
          SurfaceProblem(
            title: "Shell could not start",
            detail: "The local shell failed to launch.",
            actions: []
          )
        )
      }
    }

    private func apply(_ lifecycle: SurfaceLifecycle) {
      model.observe(lifecycle)
      if case let .exited(status) = lifecycle {
        phase = .failed(
          SurfaceProblem(
            title: "Shell exited",
            detail: status.map { "The shell exited with status \($0)." } ?? "The shell exited.",
            actions: []
          )
        )
      }
    }

    func close(_ mode: RoamingCloseMode) async {
      await backend.close()
    }
  }
#endif
