#if os(macOS)
import CryptoKit
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import Synchronization

/// The QUIC server certificate delivered through SSH (spec §5.2).
public struct HostCertificate: Sendable, Hashable {
  public var der: Data
  /// Lowercase hex SHA-256 of `der`.
  public var sha256Hex: String

  public init(der: Data) {
    self.der = der
    sha256Hex = hexString(SHA256.hash(data: der))
  }

  /// Fails unless `sha256Hex` is the lowercase fingerprint of `der`.
  public init?(der: Data, sha256Hex: String) {
    let expected = hexString(SHA256.hash(data: der))
    guard expected == sha256Hex else { return nil }
    self.der = der
    self.sha256Hex = sha256Hex
  }
}

/// What every grant advertises: the approved endpoint and certificate.
public struct HostIdentity: Sendable, Hashable {
  public var endpoint: BootstrapEndpoint
  public var certificate: HostCertificate

  public init(endpoint: BootstrapEndpoint, certificate: HostCertificate) {
    self.endpoint = endpoint
    self.certificate = certificate
  }
}

/// Session limits and lifetimes (spec §4, §5.2, §12).
public struct RegistryPolicy: Sendable {
  public var maxSessions = RSTLimits.maxSessionsPerAccount
  public var reservationLifetime = RSTLimits.reservationLifetime
  public var detachedRetention = RSTLimits.detachedRetention
  public var exitedRetention = RSTLimits.exitedRetention
  /// Clamped to `RSTLimits.maxTokenLifetime`.
  public var tokenLifetime = RSTLimits.maxTokenLifetime
  /// Failed attachment attempts allowed per window before every attempt
  /// is refused until the window passes.
  public var attachFailureLimit = 16
  public var attachFailureWindow: Duration = .seconds(10)
  /// Each escalation phase (SIGHUP, SIGTERM, SIGKILL) waits this long.
  public var terminationGrace: Duration = .seconds(2)
  public var sweepInterval: Duration = .seconds(1)

  public init() {}
}

/// Owns every host session of this agent lifetime: reservation, grants,
/// capabilities, attachment authorization, retention and termination.
public final class SessionRegistry: @unchecked Sendable {
  private struct Credential {
    var token: ApplicationToken
    var writer: WriterID
    var expiresAt: ContinuousClock.Instant
  }

  private struct Entry {
    var session: HostTerminalSession
    var credential: Credential?
    var createdAt: ContinuousClock.Instant
  }

  private struct State {
    var entries: [SessionID: Entry] = [:]
    var failures: [ContinuousClock.Instant] = []
  }

  /// Random identifier for this agent lifetime.
  public let serverInstanceID: ServerInstanceID
  public let identity: HostIdentity
  public let policy: RegistryPolicy
  private let makeLaunch: @Sendable () -> ShellLaunch
  private let writer: any PTYWriting
  private let state = Mutex(State())
  private let timer = Mutex<DispatchSourceTimer?>(nil)

  public init(
    identity: HostIdentity,
    policy: RegistryPolicy = RegistryPolicy(),
    launch: @escaping @Sendable () -> ShellLaunch = { .loginShell() },
    writer: any PTYWriting = DarwinPTYWriter()
  ) {
    serverInstanceID = .random()
    self.identity = identity
    var policy = policy
    policy.tokenLifetime = min(policy.tokenLifetime, RSTLimits.maxTokenLifetime)
    self.policy = policy
    makeLaunch = launch
    self.writer = writer
  }

  deinit { timer.withLock { $0?.cancel() } }

  // MARK: Bootstrap operations

  /// Reserves a session and grants its first capability. The shell does
  /// not start until the first successful attachment.
  public func create(grid: GridSize) throws(BootstrapErrorCode) -> BootstrapGrant {
    guard grid.isValid else { throw .malformed }
    let session = HostTerminalSession(
      grid: grid,
      launch: makeLaunch(),
      writer: writer
    )
    let writerID = WriterID.random()
    do {
      try session.authorize(writer: writerID)
    } catch {
      throw .internalError
    }
    session.onTerminateRequested = { [weak self] id in
      guard let self else { return }
      Task { _ = await self.terminate(id) }
    }
    let now = ContinuousClock.now
    let credential = issue(writer: writerID, now: now)
    let admitted = state.withLock { s -> Bool in
      guard s.entries.count < policy.maxSessions else { return false }
      s.entries[session.id] = Entry(
        session: session,
        credential: credential,
        createdAt: now
      )
      return true
    }
    guard admitted else { throw .sessionLimit }
    return grant(session.id, credential: credential, grid: grid)
  }

  /// Issues fresh credentials for a retained session and revokes the
  /// previous capability. The writer is kept only when `writerID` names
  /// the current writer; a different writer cannot take over while
  /// admitted input is incomplete.
  public func resume(
    _ id: SessionID,
    writerID: WriterID? = nil
  ) throws(BootstrapErrorCode) -> BootstrapGrant {
    guard let session = state.withLock({ $0.entries[id]?.session }) else {
      throw .unknownSession
    }
    let writer: WriterID
    if let requested = writerID, requested == session.writerID {
      writer = requested
    } else {
      writer = WriterID.random()
      do {
        try session.authorize(writer: writer)
      } catch {
        throw .writerBusy
      }
    }
    let credential = issue(writer: writer, now: .now)
    let found = state.withLock { s -> Bool in
      guard s.entries[id] != nil else { return false }
      s.entries[id]?.credential = credential
      return true
    }
    guard found else { throw .unknownSession }
    let status = session.status
    return grant(
      id,
      credential: credential,
      grid: GridSize(columns: status.columns, rows: status.rows)
    )
  }

  public func list() -> [SessionSummary] {
    let sessions = state.withLock { s in s.entries.values.map(\.session) }
    return sessions.map { session in
      let status = session.status
      let state: SessionSummary.State =
        switch status.state {
        case .reserved: .reserved
        case .attached: .attached
        case .detached: .detached
        case .exited, .terminated: .exited
        }
      return SessionSummary(
        sessionID: session.id,
        state: state,
        columns: status.columns,
        rows: status.rows,
        lastActivity: status.lastActivityWall,
        exitStatus: status.exitStatus
      )
    }
    .sorted { $0.lastActivity > $1.lastActivity }
  }

  /// Revokes credentials and destroys the session. Returns false when it
  /// does not exist.
  @discardableResult
  public func terminate(_ id: SessionID) async -> Bool {
    guard
      let session = state.withLock({ $0.entries.removeValue(forKey: id) })?
        .session
    else { return false }
    await session.terminate(grace: policy.terminationGrace)
    return true
  }

  /// Answers one validated bootstrap request (spec §5.1).
  public func handle(_ request: BootstrapRequest) async -> BootstrapResponse {
    do {
      try request.validate()
    } catch {
      switch error {
      case .unsupportedProtocol, .tooManyProtocols:
        return .failure(.unsupportedVersion)
      case .missingSession, .invalidGrid:
        return .failure(.malformed)
      }
    }
    do throws(BootstrapErrorCode) {
      switch request.operation {
      case .create:
        guard let grid = request.initialGrid else { throw .malformed }
        return .granted(try create(grid: grid))
      case .resume:
        guard let id = request.sessionID else { throw .malformed }
        return .granted(try resume(id, writerID: request.writerID))
      case .list:
        return .sessions(list())
      case .terminate:
        guard let id = request.sessionID else { throw .malformed }
        guard await terminate(id) else { throw .unknownSession }
        return .terminated(id)
      }
    } catch {
      return .failure(error)
    }
  }

  /// The session for `id`, if retained (diagnostics and tests).
  public func session(_ id: SessionID) -> HostTerminalSession? {
    state.withLock { $0.entries[id]?.session }
  }

  // MARK: Attachments

  /// Serves one authenticated RST/1 connection. Pass every connection the
  /// listener accepts.
  public func accept(_ connection: any RSTConnection) {
    HostAttachment(connection: connection, registry: self).start()
  }

  /// Validates an `Attach` (rate limit, instance, session, constant-time
  /// token comparison, expiry, writer) and attaches on success.
  func attach(
    _ request: ControlMessage.Attach,
    attachment: HostAttachment
  ) async -> AttachOutcome<HostTerminalSession> {
    let now = ContinuousClock.now
    let checked = state.withLock { s -> AttachOutcome<HostTerminalSession> in
      s.failures.removeAll { $0 + policy.attachFailureWindow <= now }
      guard s.failures.count < policy.attachFailureLimit else {
        return .failure(.limitExceeded)
      }
      let result = Self.authorize(request, entries: s.entries, instance: serverInstanceID, now: now)
      if case .failure = result { s.failures.append(now) }
      return result
    }
    guard case let .success(session) = checked else { return checked }
    switch await session.attach(attachment, writer: request.writerID) {
    case .success: return .success(session)
    case let .failure(code):
      state.withLock { $0.failures.append(now) }
      return .failure(code)
    }
  }

  private static func authorize(
    _ request: ControlMessage.Attach,
    entries: [SessionID: Entry],
    instance: ServerInstanceID,
    now: ContinuousClock.Instant
  ) -> AttachOutcome<HostTerminalSession> {
    guard request.serverInstanceID == instance else {
      return .failure(.wrongInstance)
    }
    guard let entry = entries[request.sessionID] else {
      return .failure(.unknownSession)
    }
    guard let credential = entry.credential,
      credential.token.matches(request.applicationToken)
    else { return .failure(.unauthorized) }
    guard now < credential.expiresAt else { return .failure(.expired) }
    guard credential.writer == request.writerID else {
      return .failure(.unauthorized)
    }
    return .success(entry.session)
  }

  // MARK: Retention

  /// Expires unattached reservations, idle detached sessions and exited
  /// sessions past their retention. Returns the removed identifiers.
  @discardableResult
  public func sweep(now: ContinuousClock.Instant = .now) async -> [SessionID] {
    let expired = state.withLock { s -> [HostTerminalSession] in
      var out: [HostTerminalSession] = []
      for (id, entry) in s.entries {
        let status = entry.session.status
        let expire: Bool =
          switch status.state {
          case .reserved:
            now - entry.createdAt >= policy.reservationLifetime
          case .detached:
            now - status.lastActivity >= policy.detachedRetention
          case .exited:
            now - (status.exitedAt ?? status.lastActivity)
              >= policy.exitedRetention
          case .terminated: true
          case .attached: false
          }
        if expire {
          out.append(entry.session)
          s.entries.removeValue(forKey: id)
        }
      }
      return out
    }
    for session in expired {
      await session.terminate(grace: policy.terminationGrace)
    }
    return expired.map(\.id)
  }

  /// Sweeps periodically until the registry is released.
  public func startSweeping() {
    let source = DispatchSource.makeTimerSource(
      queue: .global(qos: .utility)
    )
    let interval = policy.sweepInterval.dispatchInterval
    source.schedule(deadline: .now() + interval, repeating: interval)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      Task { await self.sweep() }
    }
    source.resume()
    timer.withLock { previous in
      previous?.cancel()
      previous = source
    }
  }

  // MARK: Helpers

  private func issue(
    writer: WriterID,
    now: ContinuousClock.Instant
  ) -> Credential {
    Credential(
      token: .random(),
      writer: writer,
      expiresAt: now + policy.tokenLifetime
    )
  }

  private func grant(
    _ id: SessionID,
    credential: Credential,
    grid: GridSize
  ) -> BootstrapGrant {
    let remaining = ContinuousClock.now.duration(to: credential.expiresAt)
    let seconds =
      Double(remaining.components.seconds)
      + Double(remaining.components.attoseconds) / 1e18
    return BootstrapGrant(
      serverInstanceID: serverInstanceID,
      sessionID: id,
      writerID: credential.writer,
      endpoint: identity.endpoint,
      serverCertificateDER: identity.certificate.der,
      serverCertificateSHA256: identity.certificate.sha256Hex,
      applicationToken: credential.token,
      tokenExpiresAt: Date().timeIntervalSince1970 + max(0, seconds),
      initialGrid: grid
    )
  }
}
#endif
