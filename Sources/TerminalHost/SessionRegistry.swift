#if os(macOS)
import AppleTransport
import CryptoKit
import Dispatch
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftMuxService
import Synchronization

/// The QUIC server certificate delivered through SSH (spec §5.2) and its
/// SPKI pin (spec.inbox.md §1.8).
public struct HostCertificate: Sendable, Hashable {
  public var der: Data
  /// Lowercase hex SHA-256 of `der`.
  public var sha256Hex: String
  /// Lowercase hex SHA-256 of the certificate's DER SubjectPublicKeyInfo
  /// (the QUIC pin). Nil only when `der` is not an X.509 certificate,
  /// which `init?(der:sha256Hex:)` — the production path — refuses.
  public var spkiSHA256Hex: String?

  public init(der: Data) {
    self.der = der
    sha256Hex = hexString(SHA256.hash(data: der))
    spkiSHA256Hex = try? CertificatePin.spkiFingerprint(der)
  }

  /// Fails unless `sha256Hex` is the lowercase fingerprint of `der` and
  /// `der` is a certificate whose SPKI pin can be computed.
  public init?(der: Data, sha256Hex: String) {
    let expected = hexString(SHA256.hash(data: der))
    guard expected == sha256Hex,
      let spki = try? CertificatePin.spkiFingerprint(der)
    else { return nil }
    self.der = der
    self.sha256Hex = sha256Hex
    spkiSHA256Hex = spki
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

/// Session limits and lifetimes (spec §4, §5.2, §12). Lifetimes govern
/// remote authorization only: a SwiftMux workspace outlives them unless
/// this host created it and it was never attached or its shell exited
/// (spec.inbox.md §1–2: "local shell lifetime is separate").
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
  public var sweepInterval: Duration = .seconds(1)

  public init() {}
}

/// Remote authorization for SwiftMux workspaces: bootstrap grants,
/// capabilities, attachment authorization and retention. It owns no
/// shells; RST/1 session identifiers are workspace identities and the
/// grant's server instance is the SwiftMux service epoch.
public final class SessionRegistry: @unchecked Sendable {
  private struct Credential {
    var token: ApplicationToken
    var writer: WriterID
    var expiresAt: ContinuousClock.Instant
    var takeover: Bool
    var target: ResumeTarget?
  }

  private struct Entry {
    var session: RoamingSession
    var credential: Credential?
    var createdAt: ContinuousClock.Instant
    /// Created by a bootstrap `create`, so an abandoned reservation or
    /// exited shell may be ended here. Workspaces from elsewhere are not.
    var createdHere: Bool
  }

  private struct State {
    var entries: [SessionID: Entry] = [:]
    var failures: [ContinuousClock.Instant] = []
    /// Revision floors of removed entries whose workspace may be resumed
    /// again (bounded, oldest dropped first).
    var floors: [SessionID: RoamingSession.Floor] = [:]
    var floorOrder: [SessionID] = []

    mutating func retire(_ id: SessionID, _ floor: RoamingSession.Floor) {
      if floors.updateValue(floor, forKey: id) == nil { floorOrder.append(id) }
      while floorOrder.count > 1024 {
        floors.removeValue(forKey: floorOrder.removeFirst())
      }
    }
  }

  /// The SwiftMux service epoch.
  public let serverInstanceID: SessionCore.ServerInstanceID
  /// The endpoint and certificate every new grant advertises; replaced
  /// when the QUIC certificate is renewed.
  public var identity: HostIdentity { identityBox.withLock { $0 } }
  private let identityBox: Mutex<HostIdentity>
  public let policy: RegistryPolicy
  public let service: MuxService
  private let makeLaunch: @Sendable () -> LaunchSpec
  private let control: MuxLocalSession
  private let state = Mutex(State())
  private let timer = Mutex<DispatchSourceTimer?>(nil)

  public init(
    service: MuxService,
    identity: HostIdentity,
    policy: RegistryPolicy = RegistryPolicy(),
    launch: @escaping @Sendable () -> LaunchSpec = { LaunchSpec() }
  ) {
    self.service = service
    serverInstanceID = SessionCore.ServerInstanceID(service.instance)
    identityBox = Mutex(identity)
    var policy = policy
    policy.tokenLifetime = min(policy.tokenLifetime, RSTLimits.maxTokenLifetime)
    self.policy = policy
    makeLaunch = launch
    let queue = DispatchQueue(label: "swiftmux.roaming.registry")
    control = MuxLocalSession(queue: queue)
    queue.sync {
      control.connect(to: service, frontend: .control, remote: true)
    }
  }

  deinit {
    timer.withLock { $0?.cancel() }
    let control = control
    control.queue.async { control.close() }
  }

  // MARK: Bootstrap operations

  /// Starts a new workspace (one pane, kept after exit so the final
  /// screen survives) and grants its first capability.
  public func create(
    grid: GridSize
  ) async throws(BootstrapErrorCode) -> BootstrapGrant {
    guard grid.isValid else { throw .malformed }
    let full = state.withLock { $0.entries.count >= policy.maxSessions }
    guard !full else { throw .sessionLimit }
    let result = await control.request(
      .newWorkspace(
        NewWorkspaceRequest(
          columns: grid.columns,
          rows: grid.rows,
          launch: makeLaunch(),
          remainOnExit: true
        )
      )
    )
    guard case let .success(.created(ws)) = result else {
      if case let .failure(error) = result, error.code == .resourceLimit {
        throw .sessionLimit
      }
      throw .internalError
    }
    let id = SessionID(ws.id)
    let session = makeSession(id, grid: grid)
    let writerID = WriterID.random()
    do {
      try session.authorize(writer: writerID)
    } catch {
      throw .internalError
    }
    let now = ContinuousClock.now
    let credential = issue(writer: writerID, takeover: false, now: now)
    let admitted = state.withLock { s -> Bool in
      guard s.entries.count < policy.maxSessions else { return false }
      s.entries[id] = Entry(
        session: session,
        credential: credential,
        createdAt: now,
        createdHere: true
      )
      return true
    }
    guard admitted else {
      _ = await control.request(.endWorkspace(.id(ws.id)))
      throw .sessionLimit
    }
    return grant(id, credential: credential, grid: grid)
  }

  /// Issues fresh credentials for a workspace and revokes the previous
  /// capability. Any workspace of the service can be resumed, including
  /// one created by the Mac app. The writer is kept only when `writerID`
  /// names the current writer; a different writer cannot take over while
  /// admitted input is incomplete.
  public func resume(
    _ id: SessionID,
    writerID: WriterID? = nil,
    takeover: Bool = false,
    target: ResumeTarget? = nil,
    grid: GridSize? = nil
  ) async throws(BootstrapErrorCode) -> BootstrapGrant {
    var session = state.withLock { $0.entries[id]?.session }
    if session == nil {
      guard await workspaces().contains(where: { $0.id == id.workspace }) else {
        throw .unknownSession
      }
      let candidate = makeSession(id, grid: grid ?? GridSize(columns: 80, rows: 24))
      session = state.withLock { s -> RoamingSession? in
        if let existing = s.entries[id] { return existing.session }
        guard s.entries.count < policy.maxSessions else { return nil }
        s.entries[id] = Entry(
          session: candidate,
          credential: nil,
          createdAt: .now,
          createdHere: false
        )
        return candidate
      }
      guard session != nil else { throw .sessionLimit }
    }
    guard let session else { throw .unknownSession }
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
    var credential = issue(writer: writer, takeover: takeover, now: .now)
    credential.target = target
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
      grid: GridSize(
        columns: min(max(status.columns, 1), RSTLimits.maxColumns),
        rows: min(max(status.rows, 1), RSTLimits.maxRows)
      )
    )
  }

  /// The service's workspaces, most recently active first (bounded by
  /// the wire limit).
  public func list() async -> [SessionSummary] {
    let summaries = await workspaces()
    let entries = state.withLock { $0.entries }
    let list = summaries.map { ws -> SessionSummary in
      let id = SessionID(ws.id)
      guard let status = entries[id]?.session.status else {
        return SessionSummary(
          sessionID: id,
          state: ws.isAttached ? .attached : .detached,
          columns: 80,
          rows: 24,
          lastActivity: ws.createdAt.timeIntervalSince1970
        )
      }
      let state: SessionSummary.State =
        switch status.state {
        case .reserved: .reserved
        case .attached: .attached
        case .detached: ws.isAttached ? .attached : .detached
        case .exited, .terminated: .exited
        }
      return SessionSummary(
        sessionID: id,
        state: state,
        columns: min(max(status.columns, 1), RSTLimits.maxColumns),
        rows: min(max(status.rows, 1), RSTLimits.maxRows),
        lastActivity: status.lastActivityWall,
        exitStatus: status.exitStatus
      )
    }
    return Array(
      list.sorted { $0.lastActivity > $1.lastActivity }
        .prefix(RSTLimits.maxSessionsPerAccount)
    )
  }

  /// Revokes credentials and ends the workspace (an explicit user
  /// request). Returns false when it does not exist.
  @discardableResult
  public func terminate(_ id: SessionID) async -> Bool {
    let entry = state.withLock { $0.entries.removeValue(forKey: id) }
    entry?.session.markTerminated()
    let result = await control.request(.endWorkspace(.id(id.workspace)))
    if case .success = result { return true }
    return entry != nil
  }

  /// Answers one validated bootstrap request (spec §5.1).
  public func handle(_ request: BootstrapRequest) async -> BootstrapResponse {
    do {
      try request.validate()
    } catch {
      switch error {
      case .unsupportedProtocol, .tooManyProtocols:
        return .failure(.unsupportedVersion)
      case .missingSession, .invalidGrid, .missingAttention:
        return .failure(.malformed)
      }
    }
    do throws(BootstrapErrorCode) {
      switch request.operation {
      case .create:
        guard let grid = request.initialGrid else { throw .malformed }
        return .granted(try await create(grid: grid))
      case .resume:
        guard let id = request.sessionID else { throw .malformed }
        return .granted(
          try await resume(
            id,
            writerID: request.writerID,
            takeover: request.takeover ?? false,
            target: request.target,
            grid: request.initialGrid
          )
        )
      case .list:
        return .sessions(await list())
      case .terminate:
        guard let id = request.sessionID else { throw .malformed }
        guard await terminate(id) else { throw .unknownSession }
        return .terminated(id)
      case .attention:
        guard let attention = request.attention else { throw .malformed }
        return .metadata(try await metadata(attention))
      }
    } catch {
      return .failure(error)
    }
  }

  /// Answers lease-free metadata through the control client, which never
  /// holds a lease, so `leaseHeldElsewhere` reports any holder.
  public func metadata(
    _ request: AttentionRequest
  ) async throws(BootstrapErrorCode) -> HostMetadata {
    var metadata = HostMetadata(serviceEpoch: service.instance)
    switch request {
    case .workspaces:
      metadata.workspaces = await workspaces()
    case let .inbox(query):
      metadata.inbox = try await inboxPage(query)
    case let .locate(reference):
      guard case let .success(.attention(location)) = await control.request(
        .locateAttention(reference)
      ) else { throw .internalError }
      metadata.location = location
    case let .markSeen(reference):
      try await acknowledge(.markSeen(reference))
    case let .snooze(reference, until):
      try await acknowledge(.snooze(reference, until: until))
    case let .markReviewed(reference):
      try await acknowledge(.markReviewed(reference))
    }
    return metadata
  }

  private func acknowledge(_ command: MuxCommand) async throws(BootstrapErrorCode) {
    switch await control.request(command) {
    case .success: return
    case let .failure(error) where error.code == .notFound:
      throw .unknownSession
    case let .failure(error) where error.code == .invalidRequest:
      throw .malformed
    case .failure: throw .internalError
    }
  }

  /// One inbox page that fits the bootstrap envelope: the row limit is
  /// halved until the encoded response fits, so the cursor stays exact.
  private func inboxPage(
    _ query: InboxQuery
  ) async throws(BootstrapErrorCode) -> InboxPage {
    var query = query
    query.limit = min(max(query.limit, 1), 100)
    while true {
      guard case let .success(.inbox(page)) = await control.request(
        .inbox(query)
      ) else { throw .internalError }
      let response = BootstrapResponse.metadata(
        HostMetadata(serviceEpoch: service.instance, inbox: page)
      )
      if (try? BootstrapEnvelope.encode(response)) != nil { return page }
      guard query.limit > 1 else { throw .internalError }
      query.limit /= 2
    }
  }

  /// The roaming session for `id`, if retained (diagnostics and tests).
  public func session(_ id: SessionID) -> RoamingSession? {
    state.withLock { $0.entries[id]?.session }
  }

  private func makeSession(_ id: SessionID, grid: GridSize) -> RoamingSession {
    let floor = state.withLock { $0.floors[id] } ?? RoamingSession.Floor()
    let session = RoamingSession(id: id, service: service, grid: grid, floor: floor)
    session.onTerminateRequested = { [weak self] id in
      guard let self else { return }
      Task { _ = await self.terminate(id) }
    }
    return session
  }

  /// The service's workspaces, as the control client sees them.
  package func workspaces() async -> [WorkspaceSummary] {
    guard case let .success(.workspaces(list)) = await control.request(
      .listWorkspaces
    ) else { return [] }
    return list
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
  ) async -> AttachOutcome<RoamingSession> {
    let now = ContinuousClock.now
    let checked = state.withLock { s -> AttachOutcome<(RoamingSession, Credential)> in
      s.failures.removeAll { $0 + policy.attachFailureWindow <= now }
      guard s.failures.count < policy.attachFailureLimit else {
        return .failure(.limitExceeded)
      }
      let result = Self.authorize(
        request,
        entries: s.entries,
        instance: serverInstanceID,
        now: now
      )
      if case .failure = result { s.failures.append(now) }
      return result
    }
    guard case let .success((session, credential)) = checked else {
      if case let .failure(code) = checked { return .failure(code) }
      return .failure(.internalError)
    }
    switch await session.attach(
      attachment,
      writer: request.writerID,
      takeover: credential.takeover,
      target: credential.target
    ) {
    case .success:
      // Takeover and focus apply to the confirmed attachment only; a
      // later reconnect with the same token neither displaces a newer
      // holder nor moves focus back.
      state.withLock { s in
        guard s.entries[request.sessionID]?.credential?.token == credential.token
        else { return }
        s.entries[request.sessionID]?.credential?.takeover = false
        s.entries[request.sessionID]?.credential?.target = nil
      }
      return .success(session)
    case let .failure(code):
      state.withLock { $0.failures.append(now) }
      return .failure(code)
    }
  }

  private static func authorize(
    _ request: ControlMessage.Attach,
    entries: [SessionID: Entry],
    instance: SessionCore.ServerInstanceID,
    now: ContinuousClock.Instant
  ) -> AttachOutcome<(RoamingSession, Credential)> {
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
    return .success((entry.session, credential))
  }

  // MARK: Retention

  /// Expires remote authorization. Ends only workspaces this host
  /// created that were never attached, or whose shell exited; every
  /// other workspace keeps running and only loses its remote grant.
  @discardableResult
  public func sweep(now: ContinuousClock.Instant = .now) async -> [SessionID] {
    let (removed, end) = state.withLock { s -> ([SessionID], [SessionID]) in
      var removed: [SessionID] = []
      var end: [SessionID] = []
      for (id, entry) in s.entries {
        let status = entry.session.status
        // An attached entry is never dropped: its session holds the lease.
        if status.isAttached, status.state != .terminated { continue }
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
        guard expire else { continue }
        s.entries.removeValue(forKey: id)
        s.retire(id, entry.session.floor)
        removed.append(id)
        // Only a workspace this host created, and only when nothing in it
        // still runs (a never-attached reservation, or every pane exited).
        if entry.createdHere,
          status.state == .reserved
            || (status.state == .exited && status.allPanesExited)
        {
          end.append(id)
        }
      }
      return (removed, end)
    }
    for id in end {
      _ = await control.request(.endWorkspace(.id(id.workspace)))
    }
    return removed
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
    takeover: Bool,
    now: ContinuousClock.Instant
  ) -> Credential {
    Credential(
      token: .random(),
      writer: writer,
      expiresAt: now + policy.tokenLifetime,
      takeover: takeover
    )
  }

  /// Advertises a renewed certificate (and endpoint) in later grants.
  /// Grants already issued keep their pin; their clients fetch a fresh
  /// grant when the old pin stops matching.
  public func replaceIdentity(_ identity: HostIdentity) {
    identityBox.withLock { $0 = identity }
  }

  private func grant(
    _ id: SessionID,
    credential: Credential,
    grid: GridSize
  ) -> BootstrapGrant {
    let identity = identity
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
      serverSPKISHA256: identity.certificate.spkiSHA256Hex,
      applicationToken: credential.token,
      tokenExpiresAt: Date().timeIntervalSince1970 + max(0, seconds),
      initialGrid: grid
    )
  }
}
#endif
