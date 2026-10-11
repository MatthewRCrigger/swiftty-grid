import ScreenProtocol
import SessionCore
import SwifttyCore
import Synchronization

/// Ordinary SSH on direct clients (spec §A.3.B): shell-channel output is
/// parsed by a local `TerminalSession`; encoded input and terminal replies
/// return over the same channel.
///
/// `TerminalSession.receive` returns before parsing, so it is not
/// backpressure. This adapter hands the channel output credit only as
/// parsing completes: after each chunk it queues an ordered marker
/// (`receive { _ in ...; return [] }`) that runs on the session queue once
/// the chunk is parsed and returns that chunk's credit. Unparsed output
/// therefore never exceeds `outputWindow` plus one transport read.
public final class SSHStreamBackend: TerminalSurfaceBackend {
  enum Outbound: Sendable {
    case bytes([UInt8])
    case resize(columns: Int, rows: Int)
  }

  struct State: Sendable {
    var lifecycle: SurfaceLifecycle = .connecting
    var started = false
    var unparsed = 0
    var peakUnparsed = 0
    var outbound: [Outbound] = []
    var outboundBytes = 0
    var pumping = false
    var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)?
    /// Grid last sent to (or opened on) the remote PTY.
    var remoteGrid: GridSize?
  }

  public let session: TerminalSession
  let channel: any TerminalByteChannel
  /// Output credit: the most program output delivered but not yet parsed.
  public let outputWindow: Int
  /// User input is refused while this many bytes await the channel.
  public let writeLimit: Int
  private let state = Mutex(State())

  /// No remote clipboard writes or URL opening by default (spec §A.7);
  /// local emulator features otherwise work.
  public static let capabilities = SurfaceCapabilities(
    scrollback: true,
    search: true,
    mouseReporting: true,
    remoteClipboardWrites: false,
    localCopy: true,
    paste: true,
    openURLs: false,
    localProcess: false,
    textInput: true
  )

  /// - Parameter session: A regular (byte-stream) session with no PTY.
  public init(
    channel: any TerminalByteChannel,
    session: TerminalSession,
    outputWindow: Int = 256 * 1024,
    writeLimit: Int = RSTLimits.maxPendingInputBytes
  ) {
    precondition(outputWindow > 0 && writeLimit > 0)
    self.channel = channel
    self.session = session
    self.outputWindow = outputWindow
    self.writeLimit = writeLimit
  }

  /// Bytes delivered to the session and not yet parsed.
  public var unparsedBytes: Int { state.withLock { $0.unparsed } }
  /// High-water mark of `unparsedBytes`.
  public var peakUnparsedBytes: Int { state.withLock { $0.peakUnparsed } }

  /// Wires the session and channel and grants the initial credit.
  public func start() {
    let first = state.withLock { s in
      defer { s.started = true }
      return !s.started
    }
    guard first else { return }
    // Encoded input and terminal replies share the ordered writer.
    session.onWrite = { [weak self] bytes in self?.enqueue(.bytes(bytes)) }
    // Any local grid change (a view resizing its session directly, or
    // `proposeGrid`) becomes a window-change request, ordered with writes.
    let initial = session.withState { GridSize(columns: $0.columns, rows: $0.rows) }
    state.withLock { $0.remoteGrid = initial }
    session.onStateChange = { [weak self] terminal in
      self?.gridChanged(GridSize(columns: terminal.columns, rows: terminal.rows))
    }
    channel.start(
      TerminalChannelHandler(
        onOutput: { [weak self] bytes in self?.output(bytes) },
        onExit: { [weak self] exit in self?.exited(exit) }
      )
    )
    setLifecycle(.active)
    channel.grantCredit(outputWindow)
  }

  private func output(_ bytes: [UInt8]) {
    let count = bytes.count
    guard count > 0 else { return }
    state.withLock { s in
      s.unparsed += count
      s.peakUnparsed = max(s.peakUnparsed, s.unparsed)
    }
    session.receive(bytes)
    // Runs on the session queue after `bytes` were parsed.
    session.receive { [weak self] _ in
      self?.parsed(count)
      return []
    }
  }

  private func gridChanged(_ grid: GridSize) {
    let changed = state.withLock { s -> Bool in
      guard s.remoteGrid != grid else { return false }
      s.remoteGrid = grid
      return true
    }
    if changed { enqueue(.resize(columns: grid.columns, rows: grid.rows)) }
  }

  private func parsed(_ count: Int) {
    state.withLock { $0.unparsed -= count }
    channel.grantCredit(count)
  }

  private func exited(_ exit: TerminalChannelExit) {
    // Ordered after all output already handed to the session.
    session.programExited()
    switch exit {
    case let .exited(status): setLifecycle(.exited(status))
    case .signaled: setLifecycle(.exited(nil))
    case .disconnected: setLifecycle(.lost)
    }
  }

  private func setLifecycle(_ next: SurfaceLifecycle) {
    let handler = state.withLock { s -> (@Sendable (SurfaceLifecycle) -> Void)? in
      guard s.lifecycle != next, !s.lifecycle.isFinal else { return nil }
      s.lifecycle = next
      return s.onLifecycleChange
    }
    handler?(next)
  }

  // MARK: Ordered channel writer

  private func enqueue(_ item: Outbound) {
    let start = state.withLock { s -> Bool in
      guard !s.lifecycle.isFinal else { return false }
      s.outbound.append(item)
      if case let .bytes(bytes) = item { s.outboundBytes += bytes.count }
      guard !s.pumping else { return false }
      s.pumping = true
      return true
    }
    if start { Task { await self.pump() } }
  }

  private func pump() async {
    while true {
      let item = state.withLock { s -> Outbound? in
        guard !s.outbound.isEmpty, !s.lifecycle.isFinal else {
          s.pumping = false
          s.outbound = []
          s.outboundBytes = 0
          return nil
        }
        return s.outbound.removeFirst()
      }
      guard let item else { return }
      do {
        switch item {
        case let .bytes(bytes):
          try await channel.write(bytes)
          state.withLock { $0.outboundBytes -= bytes.count }
        case let .resize(columns, rows):
          try await channel.resize(columns: columns, rows: rows)
        }
      } catch {
        setLifecycle(.lost)
      }
    }
  }

  // MARK: TerminalSurfaceBackend

  public var capabilities: SurfaceCapabilities { Self.capabilities }
  public var display: SurfaceDisplay { .session(session) }
  public func currentFrame() -> SurfaceFrame? { nil }

  /// The view observes `session.onUpdate` directly.
  public var onInvalidate: (@Sendable () -> Void)? {
    get { nil }
    set { _ = newValue }
  }

  public var lifecycle: SurfaceLifecycle { state.withLock { $0.lifecycle } }

  public var onLifecycleChange: (@Sendable (SurfaceLifecycle) -> Void)? {
    get { state.withLock { $0.onLifecycleChange } }
    set { state.withLock { $0.onLifecycleChange = newValue } }
  }

  public func submit(_ input: SurfaceInput) async -> SurfaceInputResult {
    let refusal = state.withLock { s -> InputRefusal? in
      if s.lifecycle.isFinal { return .closed }
      guard s.lifecycle == .active else { return .notActive(.idle) }
      return s.outboundBytes + input.operation.expansionBound > writeLimit
        ? .backpressure : nil
    }
    if let refusal { return .refused(refusal) }
    do { try input.operation.validate() } catch { return .refused(.invalid) }
    // Encoded with the local emulator's modes, then `onWrite`.
    session.send(input.terminalInput)
    return .accepted(sequence: nil)
  }

  /// Resizes the local emulator; the resulting grid change resizes the
  /// remote PTY, in order with writes.
  public func proposeGrid(columns: Int, rows: Int) async {
    guard columns > 0, rows > 0 else { return }
    session.resize(columns: columns, rows: rows)
  }

  public func close() async {
    setLifecycle(.closed)
    session.onWrite = nil
    session.onStateChange = nil
    await channel.close()
    session.programExited()
  }
}
