#if os(macOS)
import AppleTransport
import Foundation
import Synchronization
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import SwiftMuxClient
@testable import TerminalHost
import TestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SessionRegistryTests {
  private static let grid = GridSize(columns: 80, rows: 24)

  @Test
  func
    `dispatch delays clamp negative durations and saturate nanosecond overflow`()
  {
    #expect(Duration.milliseconds(-500).dispatchInterval == .nanoseconds(0))
    #expect(Duration.seconds(-1).dispatchInterval == .nanoseconds(0))
    #expect(Duration.zero.dispatchInterval == .nanoseconds(0))
    #expect(
      Duration.milliseconds(500).dispatchInterval == .nanoseconds(500_000_000)
    )
    let wholeSeconds = Int64.max / 1_000_000_000
    let remainder = Int64.max % 1_000_000_000
    let maximum = Duration.seconds(wholeSeconds) + .nanoseconds(remainder)
    #expect(maximum.dispatchInterval == .nanoseconds(Int.max))
    #expect((maximum + .nanoseconds(1)).dispatchInterval == .never)
    #expect(Duration.seconds(wholeSeconds + 1).dispatchInterval == .never)
  }

  @Test
  func
    `grants carry the injected identity, service epoch and bounded token lifetime`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(grid: Self.grid)
      #expect(grant.protocol == "RST/1")
      #expect(grant.serverInstanceID == registry.serverInstanceID)
      // One service epoch for both transports.
      #expect(
        grant.serverInstanceID
          == SessionCore.ServerInstanceID(registry.service.instance)
      )
      // The session is a SwiftMux workspace.
      #expect(
        try await registry.workspaces().map(\.id) == [grant.sessionID.workspace]
      )
      #expect(grant.endpoint == testIdentity().endpoint)
      #expect(grant.serverCertificateDER == testIdentity().certificate.der)
      let certificate = HostCertificate(
        der: grant.serverCertificateDER,
        sha256Hex: grant.serverCertificateSHA256
      )
      #expect(certificate != nil)
      // Every grant carries the SPKI pin of the delivered certificate.
      #expect(grant.serverSPKISHA256 != nil)
      #expect(grant.serverSPKISHA256 == certificate?.spkiSHA256Hex)
      #expect(
        try CertificatePin(
          certificateDER: grant.serverCertificateDER,
          sha256: grant.serverCertificateSHA256,
          spkiSHA256: grant.serverSPKISHA256
        )
        .spkiSHA256 == grant.serverSPKISHA256
      )
      let lifetime = grant.tokenExpiresAt - Date().timeIntervalSince1970
      #expect(lifetime > 8 * 3600 - 60 && lifetime <= 8 * 3600)
      #expect(grant.initialGrid == Self.grid)
      #expect(
        !grant.description.contains(grant.applicationToken.bytes.description)
      )
    }
  }

  @Test(arguments: [Duration.zero, .seconds(-1)])
  func invalidTokenLifetimeRefusesCreateBeforeLaunching(
    _ lifetime: Duration
  ) async throws {
    var policy = RegistryPolicy()
    policy.tokenLifetime = lifetime
    let launches = Mutex(0)
    try await withRegistry(
      policy: policy,
      launch: {
        launches.withLock { $0 += 1 }
        return shellLaunch()
      },
      { registry async throws in
        await #expect(throws: BootstrapErrorCode.internalError) {
          try await registry.create(grid: Self.grid)
        }
        #expect(launches.withLock { $0 } == 0)
        #expect(try await registry.workspaces().isEmpty)
      }
    )
  }

  @Test(arguments: [Duration.zero, .seconds(-1)])
  func invalidTokenLifetimeRefusesResumeBeforePublishing(
    _ lifetime: Duration
  ) async throws {
    try await withRegistry { healthy in
      let grant = try await healthy.create(grid: Self.grid)
      var policy = RegistryPolicy()
      policy.tokenLifetime = lifetime
      let invalid = SessionRegistry(
        service: healthy.service,
        identity: healthy.identity,
        policy: policy
      )
      await #expect(throws: BootstrapErrorCode.internalError) {
        try await invalid.resume(grant.sessionID)
      }
      let published = invalid.session(grant.sessionID) != nil
      #expect(!published)
      #expect(
        try await healthy.workspaces().first?.id == grant.sessionID.workspace
      )
      let current = TestClient(healthy)
      defer { current.connection.close() }
      #expect(try await current.attached(grant).attachmentEpoch == 1)
    }
  }

  @Test
  func failedCreateReleasesItsReservedCapacity() async throws {
    var policy = RegistryPolicy()
    policy.maxSessions = 1
    try await withRegistry(policy: policy) { registry in
      let local = try await MuxConnection.connect(
        endpoint: registry.service.listenAnonymously(),
        frontend: .control
      )
      do {
        _ = try await local.execute(.quiesce(true))
        await #expect(throws: BootstrapErrorCode.internalError) {
          try await registry.create(grid: Self.grid)
        }
        #expect(registry.pendingCreationCount == 0)
        #expect(try await registry.workspaces().isEmpty)
        _ = try await local.execute(.quiesce(false))
        _ = try await registry.create(grid: Self.grid)
        #expect(registry.pendingCreationCount == 0)
        #expect(try await registry.workspaces().count == 1)
      } catch {
        _ = try? await local.execute(.quiesce(false))
        await local.close()
        throw error
      }
      await local.close()
    }
  }

  @Test
  func freshResumeCannotConsumeAPendingCreateSlot() async throws {
    var policy = RegistryPolicy()
    policy.maxSessions = 1
    let release = DispatchSemaphore(value: 0)
    let blocked = Mutex(false)
    try await withRegistry(
      policy: policy,
      launch: {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("create launch quota gate timed out")
        }
        return shellLaunch()
      },
      { registry in
        let local = try await MuxConnection.connect(
          endpoint: registry.service.listenAnonymously(),
          frontend: .control
        )
        do {
          guard
            case .created(let native) = try await local.execute(
              .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
            )
          else { throw HostTestTimeout(what: "external workspace") }
          let creating = Task { try await registry.create(grid: Self.grid) }
          defer {
            release.signal()
            creating.cancel()
          }
          do {
            try await hostEventually("create launch quota gate") {
              blocked.withLock { $0 } ? true : nil
            }
            #expect(registry.pendingCreationCount == 1)
            await #expect(throws: BootstrapErrorCode.sessionLimit) {
              try await registry.resume(SessionID(native.id))
            }
            let adopted = registry.session(SessionID(native.id)) != nil
            #expect(!adopted)
            release.signal()
            _ = try await creating.value
            #expect(registry.pendingCreationCount == 0)
            #expect(try await registry.workspaces().count == 2)
          } catch {
            release.signal()
            _ = try? await creating.value
            throw error
          }
        } catch {
          await local.close()
          throw error
        }
        await local.close()
      }
    )
  }

  @Test
  func concurrentCreatesReserveCapacityBeforeServiceAllocation() async throws {
    let launches = Mutex(0)
    try await withRegistry(
      launch: {
        launches.withLock { $0 += 1 }
        return shellLaunch()
      },
      { registry in
        let release = DispatchSemaphore(value: 0)
        let blocked = Mutex(false)
        registry.service.queue.async {
          blocked.withLock { $0 = true }
          if release.wait(timeout: .now() + 10) == .timedOut {
            Issue.record("create capacity service gate timed out")
          }
        }
        defer { release.signal() }
        try await hostEventually("create capacity service gate") {
          blocked.withLock { $0 } ? true : nil
        }
        var creating: [Task<BootstrapGrant, any Error>] = []
        defer { for task in creating { task.cancel() } }
        var excess: Task<Void, Never>?
        do {
          for count in 1 ... 8 {
            creating.append(Task { try await registry.create(grid: Self.grid) })
            try await hostEventually("pending creation \(count)") {
              registry.pendingControlRequestCount == count ? true : nil
            }
          }
          let refusal = Mutex<BootstrapErrorCode?>(nil)
          let excessTask = Task {
            do throws(BootstrapErrorCode) {
              _ = try await registry.create(grid: Self.grid)
              Issue.record("excess create published a grant")
            } catch { refusal.withLock { $0 = error } }
          }
          excess = excessTask
          defer { excessTask.cancel() }
          _ = try await hostEventually(
            "create capacity refusal before service allocation",
            timeout: .milliseconds(300)
          ) { refusal.withLock { $0 } }
          #expect(refusal.withLock { $0 } == .sessionLimit)
          #expect(launches.withLock { $0 } == 8)
          #expect(registry.pendingCreationCount == 8)
          #expect(registry.pendingControlRequestCount == 8)
          release.signal()
          var grants: [BootstrapGrant] = []
          for task in creating { grants.append(try await task.value) }
          await excessTask.value
          #expect(Set(grants.map(\.sessionID)).count == 8)
          #expect(registry.pendingCreationCount == 0)
          #expect(try await registry.workspaces().count == 8)
          // Removing an entry makes its slot available again.
          #expect(await registry.terminate(grants[0].sessionID))
          _ = try await registry.create(grid: Self.grid)
          #expect(launches.withLock { $0 } == 9)
          #expect(try await registry.workspaces().count == 8)
        } catch {
          release.signal()
          for task in creating { _ = try? await task.value }
          await excess?.value
          throw error
        }
      }
    )
  }

  @Test
  func `at most eight sessions`() async throws {
    try await withRegistry { registry in
      for _ in 0 ..< 8 { _ = try await registry.create(grid: Self.grid) }
      await #expect(throws: BootstrapErrorCode.sessionLimit) {
        try await registry.create(grid: Self.grid)
      }
      #expect(try await registry.list().count == 8)
      #expect(try await registry.list().allSatisfy { $0.state == .reserved })
    }
  }

  @Test
  func `unattached reservations expire and end the workspace created for them`()
    async throws
  {
    var policy = RegistryPolicy()
    policy.reservationLifetime = .milliseconds(100)
    try await withRegistry(policy: policy) { registry in
      let grant = try await registry.create(grid: Self.grid)
      #expect(await registry.sweep().isEmpty)
      #expect(
        await registry.sweep(now: .now + .seconds(1)) == [grant.sessionID]
      )
      try await hostEventuallyAsync("workspace ended") {
        try await registry.workspaces().isEmpty ? true : nil
      }
      let client = TestClient(registry)
      try await client.attach(grant)
      #expect(try await client.errorCode() == .unknownSession)
    }
  }

  @Test(arguments: [Duration.milliseconds(10), .zero, .milliseconds(-1)])
  func periodicSweepsStayBoundedAcrossTimerReplacement(
    _ interval: Duration
  ) async throws {
    var policy = RegistryPolicy()
    policy.sweepInterval = interval
    try await withRegistry(policy: policy) { registry in
      _ = try await registry.create(grid: Self.grid)
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      registry.service.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("periodic sweep service gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("periodic sweep service gate") {
        blocked.withLock { $0 } ? true : nil
      }
      registry.startSweeping()
      defer { registry.stopSweeping() }
      try await hostEventually("first periodic sweep request") {
        registry.pendingControlRequestCount > 0 ? true : nil
      }
      for _ in 0 ..< 5 {
        registry.stopSweeping()
        registry.startSweeping()
        try await Task.sleep(for: .milliseconds(50))
        #expect(registry.pendingControlRequestCount == 1)
      }
      registry.stopSweeping()
      release.signal()
      try await hostEventually("periodic sweep requests drained") {
        registry.pendingControlRequestCount == 0 ? true : nil
      }
      blocked.withLock { $0 = false }
      registry.service.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("periodic sweep recovery gate timed out")
        }
      }
      try await hostEventually("periodic sweep recovery gate") {
        blocked.withLock { $0 } ? true : nil
      }
      registry.startSweeping()
      try await hostEventually("periodic sweep after previous completion") {
        registry.pendingControlRequestCount == 1 ? true : nil
      }
      registry.stopSweeping()
      release.signal()
      try await hostEventually("recovered sweep drained") {
        registry.pendingControlRequestCount == 0 ? true : nil
      }
    }
  }

  @Test
  func endingWorkspaceRefusesResumeBeforeServiceReplies() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(grid: Self.grid)
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      registry.service.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("workspace termination service gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("workspace termination service gate") {
        blocked.withLock { $0 } ? true : nil
      }
      let termination = Task { await registry.terminate(grant.sessionID) }
      try await hostEventually("termination revoked registry entry") {
        registry.session(grant.sessionID) == nil ? true : nil
      }
      let refusal = Mutex<BootstrapErrorCode?>(nil)
      let resume = Task {
        do throws(BootstrapErrorCode) {
          _ = try await registry.resume(grant.sessionID)
          Issue.record("ending workspace published a new grant")
        } catch { refusal.withLock { $0 = error } }
      }
      defer { resume.cancel() }
      try await hostEventually(
        "ending workspace resume refusal",
        timeout: .milliseconds(300)
      ) { refusal.withLock { $0 } }
      #expect(refusal.withLock { $0 } == .unknownSession)
      release.signal()
      #expect(await termination.value)
      await resume.value
      #expect(try await registry.workspaces().isEmpty)
      await #expect(throws: BootstrapErrorCode.unknownSession) {
        try await registry.resume(grant.sessionID)
      }
    }
  }

  @Test
  func `detached retention revokes the grant but keeps the shell`() async throws
  {
    try await withRegistry { registry in
      let grant = try await registry.create(grid: Self.grid)
      let client = TestClient(registry)
      _ = try await client.attached(grant)
      let session = try #require(registry.session(grant.sessionID))
      let pid = try #require(await shellPID(registry, session))
      client.connection.sever()
      try await hostEventually("detached") {
        session.status.state == .detached ? true : nil
      }
      #expect(await registry.sweep(now: .now + .seconds(3600)).isEmpty)
      #expect(
        await registry.sweep(now: .now + .seconds(24 * 3600 + 1)) == [
          grant.sessionID
        ]
      )
      // Remote authorization ended; the local shell lifetime is separate.
      #expect(isAlive(pid))
      #expect(try await registry.workspaces().count == 1)
      let late = TestClient(registry)
      try await late.attach(grant)
      #expect(try await late.errorCode() == .unknownSession)
      // A fresh resume authorizes the same workspace again.
      let again = try await registry.resume(grant.sessionID)
      let next = TestClient(registry)
      _ = try await next.attached(again)
      let resumed = try #require(registry.session(grant.sessionID))
      #expect(await shellPID(registry, resumed) == pid)
    }
  }

  @Test
  func sweptAuthorizationCannotAttachThroughARetainedSession() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(grid: Self.grid)
      let first = TestClient(registry)
      defer { first.connection.close() }
      _ = try await first.attached(grant)
      let retired = try #require(registry.session(grant.sessionID))
      let pid = try #require(await shellPID(registry, retired))
      first.connection.close()
      try await hostEventually("detached before retirement") {
        retired.status.state == .detached ? true : nil
      }
      let floor = retired.floor
      #expect(
        await registry.sweep(now: .now + .seconds(24 * 3600 + 1)) == [
          grant.sessionID
        ]
      )
      // Registry authorization captures this session before awaiting its
      // owner queue. Model that retained reference crossing retirement.
      let pair = InMemoryRSTConnection.pair()
      defer {
        pair.client.close()
        pair.server.close()
      }
      let attachment = HostAttachment(
        connection: pair.server,
        registry: registry
      )
      let result = await retired.attach(attachment, writer: grant.writerID)
      if case .failure(.unknownSession) = result {
      } else {
        Issue.record("retired authorization admitted an attachment: \(result)")
      }
      #expect(retired.status.state == .terminated)
      #expect(retired.floor == floor)
      #expect(isAlive(pid))
      #expect(try await registry.workspaces().first?.leaseHolder == nil)
      // Retirement affects remote authorization; a fresh grant still reaches
      // the same live workspace above the previous revision/epoch floor.
      pair.server.close()
      retired.detach(attachment)
      let resumed = try await registry.resume(grant.sessionID)
      let next = TestClient(registry)
      defer { next.connection.close() }
      let attached = try await next.attached(resumed)
      #expect(attached.attachmentEpoch > floor.epoch)
      let current = try #require(registry.session(grant.sessionID))
      #expect(await shellPID(registry, current) == pid)
    }
  }

  @Test(arguments: [false, true])
  func `attachment failures fail closed`(delayedWriter: Bool) async throws {
    // These cases require a current credential. Expiration has its own
    // short-lived fixture below, independent of the preceding round trips.
    try await withRegistry { registry in
      let grant = try await registry.create(grid: Self.grid)
      let session = try #require(registry.session(grant.sessionID))

      let early = TestClient(registry)
      try await early.send(
        .input(
          .init(attachmentEpoch: 1, sequence: 1, operation: .committedText("x"))
        )
      )
      #expect(try await early.errorCode() == .notAttached)
      try await hostEventually("closed") { early.isClosed ? true : nil }

      let forged = TestClient(registry)
      try await forged.attach(grant, token: .random())
      #expect(try await forged.errorCode() == .unauthorized)
      try await hostEventually("closed") { forged.isClosed ? true : nil }

      let instance = TestClient(registry)
      try await instance.attach(grant, instance: .random())
      #expect(try await instance.errorCode() == .wrongInstance)

      let unknown = TestClient(registry)
      var other = grant
      other.sessionID = .random()
      try await unknown.attach(other)
      #expect(try await unknown.errorCode() == .unknownSession)

      let writer = TestClient(registry)
      var wrongWriter = grant
      wrongWriter.writerID = .random()
      if delayedWriter { try await Task.sleep(for: .milliseconds(200)) }
      try await writer.attach(wrongWriter)
      let writerError = try await writer.errorCode()
      #expect(writerError == .unauthorized)
      try await hostEventually("closed") { writer.isClosed ? true : nil }

      #expect(session.status.state == .reserved)
      // Nothing attached: no lease was taken.
      #expect(try await registry.workspaces().first?.isAttached == false)
    }
  }

  @Test(arguments: [false, true])
  func expiredCredentialsTakePrecedenceOverWriterMismatch(
    wrongWriter: Bool
  ) async throws {
    var policy = RegistryPolicy()
    policy.tokenLifetime = .milliseconds(150)
    try await withRegistry(policy: policy) { registry in
      let grant = try await registry.create(grid: Self.grid)
      let session = try #require(registry.session(grant.sessionID))
      var expiredGrant = grant
      if wrongWriter { expiredGrant.writerID = .random() }
      try await Task.sleep(for: .milliseconds(200))
      let expired = TestClient(registry)
      try await expired.attach(expiredGrant)
      let rejection = try await expired.errorCode()
      #expect(rejection == .expired)
      try await hostEventually("closed") { expired.isClosed ? true : nil }
      #expect(session.status.state == .reserved)
      #expect(try await registry.workspaces().first?.isAttached == false)
    }
  }

  @Test
  func `attachment attempts are rate limited`() async throws {
    var policy = RegistryPolicy()
    policy.attachFailureLimit = 3
    try await withRegistry(policy: policy) { registry in
      let grant = try await registry.create(grid: Self.grid)
      for _ in 0 ..< 3 {
        let bad = TestClient(registry)
        try await bad.attach(grant, token: .random())
        #expect(try await bad.errorCode() == .unauthorized)
      }
      let good = TestClient(registry)
      try await good.attach(grant)
      #expect(try await good.errorCode() == .limitExceeded)
    }
  }

  @Test
  func expiredSupersededResumeDoesNotReplaceNewerCredential() async throws {
    var policy = RegistryPolicy()
    policy.tokenLifetime = .seconds(1)
    try await withRegistry(policy: policy) { registry in
      let initial = try await registry.create(grid: Self.grid)
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      registry.service.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("superseded resume aging gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("superseded resume aging gate") {
        blocked.withLock { $0 } ? true : nil
      }
      let older = Task {
        try await registry.resume(initial.sessionID, writerID: initial.writerID)
      }
      defer { older.cancel() }
      try await hostEventually("older credential awaiting verification") {
        registry.pendingControlRequestCount == 1 ? true : nil
      }
      try await Task.sleep(for: .milliseconds(1100))
      let newer = Task { try await registry.resume(initial.sessionID) }
      defer { newer.cancel() }
      try await hostEventually("newer credential awaiting verification") {
        registry.pendingControlRequestCount == 2 ? true : nil
      }
      release.signal()
      await #expect(throws: BootstrapErrorCode.internalError) {
        try await older.value
      }
      let grant = try await newer.value
      let current = TestClient(registry)
      defer { current.connection.close() }
      let attached = try await current.attached(grant)
      #expect(attached.writerID == grant.writerID)
      #expect(attached.attachmentEpoch == 1)
    }
  }

  @Test(arguments: [false, true])
  func delayedResumeReturnsAUsableCredential(_ keepWriter: Bool) async throws {
    var policy = RegistryPolicy()
    policy.tokenLifetime = .seconds(1)
    try await withRegistry(policy: policy) { registry in
      let initial = try await registry.create(grid: Self.grid)
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      registry.service.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("resume credential aging gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("resume credential aging gate") {
        blocked.withLock { $0 } ? true : nil
      }
      let resuming = Task {
        try await registry.resume(
          initial.sessionID,
          writerID: keepWriter ? initial.writerID : nil
        )
      }
      defer { resuming.cancel() }
      try await hostEventually("resume credential awaiting verification") {
        registry.pendingControlRequestCount == 1 ? true : nil
      }
      try await Task.sleep(for: .milliseconds(1100))
      release.signal()
      let grant = try await resuming.value
      #expect(grant.tokenExpiresAt - Date().timeIntervalSince1970 > 0.5)
      #expect((grant.writerID == initial.writerID) == keepWriter)
      let current = TestClient(registry)
      defer { current.connection.close() }
      try await current.attach(grant)
      let reply = try await current.message(
        "delayed resume credential admission"
      ) {
        if case .attached = $0 { return true }
        if case .error = $0 { return true }
        return false
      }
      if case .attached(let attached) = reply {
        #expect(attached.attachmentEpoch == 1)
      } else {
        Issue.record("delayed resume returned unusable credential")
      }
    }
  }

  @Test
  func expiredQueuedAttachDoesNotFenceTheCurrentConnection() async throws {
    var policy = RegistryPolicy()
    policy.tokenLifetime = .seconds(1)
    try await withRegistry(policy: policy) { registry in
      let grant = try await registry.create(grid: Self.grid)
      let session = try #require(registry.session(grant.sessionID))
      let current = TestClient(registry)
      defer { current.connection.close() }
      let attached = try await current.attached(grant)
      try await hostEventually("initial attachment admission completed") {
        registry.pendingAttachmentCount == 0 ? true : nil
      }
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      session.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("active connection expiry gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("active connection expiry gate") {
        blocked.withLock { $0 } ? true : nil
      }
      let expired = TestClient(registry)
      defer { expired.connection.close() }
      try await expired.attach(grant)
      try await hostEventually("expired replacement awaiting owner") {
        registry.pendingAttachmentCount == 1 ? true : nil
      }
      try await Task.sleep(for: .milliseconds(1100))
      release.signal()
      #expect(try await expired.errorCode() == .expired)
      #expect(session.floor.epoch == attached.attachmentEpoch)
      #expect(session.status.isAttached)
      // Token expiry limits new admission, not an established connection.
      try await current.send(.ping(epoch: attached.attachmentEpoch, nonce: 7))
      _ = try await current.message(
        "current connection survives expired replacement"
      ) {
        if case .pong(let epoch, let nonce) = $0 {
          return epoch == attached.attachmentEpoch && nonce == 7
        }
        return false
      }
    }
  }

  @Test(arguments: [false, true])
  func expiredCredentialCannotCompleteAPendingLease(
    _ gateOwner: Bool
  ) async throws {
    var policy = RegistryPolicy()
    policy.tokenLifetime = .seconds(1)
    try await withRegistry(policy: policy) { registry in
      let grant = try await registry.create(grid: Self.grid)
      let session = try #require(registry.session(grant.sessionID))
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      let gate = gateOwner ? session.queue : registry.service.queue
      gate.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("credential expiry gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("credential expiry gate") {
        blocked.withLock { $0 } ? true : nil
      }
      let stale = TestClient(registry)
      defer { stale.connection.close() }
      try await stale.attach(grant)
      if gateOwner {
        try await hostEventually("expiry request awaiting owner") {
          registry.pendingAttachmentCount == 1 ? true : nil
        }
      } else {
        try await hostEventually("expiry request awaiting service lease") {
          session.isAcquiringLease ? true : nil
        }
      }
      try await Task.sleep(for: .milliseconds(1100))
      release.signal()
      let reply = try await stale.message("expired pending lease result") {
        if case .attached = $0 { return true }
        if case .error = $0 { return true }
        return false
      }
      if case .error(let error) = reply {
        #expect(error.code == .expired)
      } else {
        Issue.record("expired pending lease was admitted")
      }
      #expect(session.floor.epoch == 0)
      #expect(!session.status.everAttached)
      try await hostEventuallyAsync("expired lease released") {
        try await registry.workspaces().first?.leaseHolder == nil ? true : nil
      }
      let fresh = try await registry.resume(grant.sessionID)
      let current = TestClient(registry)
      defer { current.connection.close() }
      #expect(try await current.attached(fresh).attachmentEpoch == 1)
    }
  }

  @Test(arguments: [false, true])
  func revokedCredentialCannotCompleteAPendingLease(
    _ keepWriter: Bool
  ) async throws {
    try await withRegistry { registry in
      let initial = try await registry.create(grid: Self.grid)
      let generation = try #require(
        try await registry.workspaces().first?.leaseGeneration
      )
      let session = try #require(registry.session(initial.sessionID))
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      registry.service.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("service lease gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("service lease gate") {
        blocked.withLock { $0 } ? true : nil
      }
      let stale = TestClient(registry)
      defer { stale.connection.close() }
      try await stale.attach(initial)
      try await hostEventually("pending service lease") {
        session.isAcquiringLease ? true : nil
      }
      let resuming = Task {
        try await registry.resume(
          initial.sessionID,
          writerID: keepWriter ? initial.writerID : nil
        )
      }
      defer { resuming.cancel() }
      try await hostEventually("resume verification after credential rotation")
      { registry.pendingControlRequestCount == 1 ? true : nil }
      let revoked = TestClient(registry)
      defer { revoked.connection.close() }
      try await revoked.attach(initial)
      #expect(try await revoked.errorCode() == .unauthorized)
      release.signal()
      let fresh = try await resuming.value
      #expect((fresh.writerID == initial.writerID) == keepWriter)
      let reply = try await stale.message("revoked pending lease result") {
        if case .attached = $0 { return true }
        if case .error = $0 { return true }
        return false
      }
      if case .error(let error) = reply {
        #expect(error.code == .unauthorized)
      } else {
        Issue.record("revoked pending lease was admitted")
      }
      #expect(session.floor.epoch == 0)
      stale.connection.close()
      try await hostEventuallyAsync("pending lease released") {
        try await registry.workspaces().first?.leaseHolder == nil ? true : nil
      }
      #expect(
        try await registry.workspaces().first?.leaseGeneration == generation
      )
      let current = TestClient(registry)
      defer { current.connection.close() }
      let attached = try await current.attached(fresh)
      #expect(attached.writerID == fresh.writerID)
      #expect(attached.attachmentEpoch == 1)
    }
  }

  @Test
  func closedConnectionCannotCompleteAPendingLease() async throws {
    try await withRegistry { registry in
      let grant = try await registry.create(grid: Self.grid)
      let generation = try #require(
        try await registry.workspaces().first?.leaseGeneration
      )
      let session = try #require(registry.session(grant.sessionID))
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      registry.service.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("closed connection lease gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("closed connection service gate") {
        blocked.withLock { $0 } ? true : nil
      }
      let closed = TestClient(registry)
      defer { closed.connection.close() }
      try await closed.attach(grant)
      try await hostEventually("closed connection pending lease") {
        session.isAcquiringLease ? true : nil
      }
      closed.connection.close()
      release.signal()
      try await hostEventually("closed connection lease result") {
        !session.isAcquiringLease ? true : nil
      }
      #expect(session.floor.epoch == 0)
      #expect(!session.status.everAttached)
      try await hostEventuallyAsync("closed connection lease released") {
        try await registry.workspaces().first?.leaseHolder == nil ? true : nil
      }
      #expect(
        try await registry.workspaces().first?.leaseGeneration == generation
      )
      let next = TestClient(registry)
      defer { next.connection.close() }
      #expect(try await next.attached(grant).attachmentEpoch == 1)
    }
  }

  @Test
  func unfinishedAttachmentsHaveABoundUntilTheirOwnerReplies() async throws {
    var policy = RegistryPolicy()
    policy.attachFailureLimit = 128
    try await withRegistry(policy: policy) { registry in
      let grant = try await registry.create(grid: Self.grid)
      let session = try #require(registry.session(grant.sessionID))
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      session.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("attachment owner gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("attachment owner gate") {
        blocked.withLock { $0 } ? true : nil
      }
      for count in 1 ... 32 {
        let closed = TestClient(registry)
        defer { closed.connection.close() }
        try await closed.attach(grant)
        try await hostEventually("reserved attachment \(count)") {
          registry.pendingAttachmentCount == count ? true : nil
        }
        closed.connection.close()
      }
      let excess = TestClient(registry)
      defer { excess.connection.close() }
      try await excess.attach(grant)
      let reply = try await excess.message(
        "attachment admission refusal",
        timeout: .milliseconds(300)
      ) {
        if case .error = $0 { return true }
        return false
      }
      if case .error(let error) = reply {
        #expect(error.code == .limitExceeded)
      }
      #expect(registry.pendingAttachmentCount == 32)
      release.signal()
      try await hostEventually("unfinished attachment slots released") {
        registry.pendingAttachmentCount == 0 ? true : nil
      }
      let next = TestClient(registry)
      defer { next.connection.close() }
      #expect(try await next.attached(grant).attachmentEpoch == 1)
    }
  }

  @Test
  func replacementWaitsForServiceDisconnectionBeforeQueuingAnotherClient()
    async throws
  {
    var policy = RegistryPolicy()
    policy.attachFailureLimit = 128
    try await withRegistry(policy: policy) { registry in
      let grant = try await registry.create(grid: Self.grid)
      let generation = try #require(
        try await registry.workspaces().first?.leaseGeneration
      )
      let session = try #require(registry.session(grant.sessionID))
      let release = DispatchSemaphore(value: 0)
      let blocked = Mutex(false)
      registry.service.queue.async {
        blocked.withLock { $0 = true }
        if release.wait(timeout: .now() + 10) == .timedOut {
          Issue.record("service disconnection gate timed out")
        }
      }
      defer { release.signal() }
      try await hostEventually("service disconnection gate") {
        blocked.withLock { $0 } ? true : nil
      }
      var clients: [TestClient] = []
      defer { for client in clients { client.connection.close() } }
      for generation in 1 ... 33 {
        let client = TestClient(registry)
        clients.append(client)
        try await client.attach(grant)
        try await hostEventually("replacement generation \(generation)") {
          session.attachmentAttemptGeneration == UInt64(generation) ? true : nil
        }
        if generation == 2 { _ = try await clients[0].errorCode() }
      }
      #expect(registry.pendingAttachmentCount == 32)
      #expect(!session.isAcquiringLease)
      release.signal()
      let reply = try await clients[32]
        .message("latest replacement attachment") {
          if case .attached = $0 { return true }
          if case .error = $0 { return true }
          return false
        }
      guard case let .attached(attached) = reply else {
        throw MuxError(.invalidRequest, "latest replacement was rejected")
      }
      #expect(attached.attachmentEpoch == 1)
      #expect(
        try await registry.workspaces().first?.leaseGeneration == generation + 1
      )
      try await hostEventually("replacement attachment slots released") {
        registry.pendingAttachmentCount == 0 ? true : nil
      }
    }
  }

  @Test
  func concurrentResumesPublishTheAuthorizedWriterWithTheirCredential()
    async throws
  {
    try await withRegistry { registry in
      let initial = try await registry.create(grid: Self.grid)
      let session = try #require(registry.session(initial.sessionID))
      for round in 0 ..< 64 {
        let grants = try await withThrowingTaskGroup(of: BootstrapGrant.self) {
          group in
          for _ in 0 ..< 16 {
            group.addTask { try await registry.resume(initial.sessionID) }
          }
          var grants: [BootstrapGrant] = []
          for try await grant in group { grants.append(grant) }
          return grants
        }
        let writer = try #require(session.writerID)
        let grant = try #require(grants.first { $0.writerID == writer })
        let client = TestClient(registry)
        do {
          try await client.attach(grant)
          let reply = try await client.message(
            "current writer attach in round \(round)"
          ) {
            if case .attached = $0 { return true }
            if case .error = $0 { return true }
            return false
          }
          guard case .attached = reply else {
            throw MuxError(
              .invalidRequest,
              "current writer credential rejected: \(reply)"
            )
          }
          client.connection.close()
          try await hostEventually("concurrent resume detach") {
            session.status.state == .detached ? true : nil
          }
        } catch {
          client.connection.close()
          throw error
        }
      }
    }
  }

  @Test
  func `resume issues fresh credentials and revokes the previous ones`()
    async throws
  {
    try await withRegistry { registry in
      let first = try await registry.create(grid: Self.grid)
      let kept = try await registry.resume(
        first.sessionID,
        writerID: first.writerID
      )
      #expect(kept.writerID == first.writerID)
      #expect(kept.applicationToken != first.applicationToken)
      let fresh = try await registry.resume(first.sessionID)
      #expect(fresh.writerID != first.writerID)

      let revoked = TestClient(registry)
      try await revoked.attach(kept)
      #expect(try await revoked.errorCode() == .unauthorized)

      let client = TestClient(registry)
      let attached = try await client.attached(fresh)
      #expect(attached.writerID == fresh.writerID)
      #expect(attached.lastFullyAppliedInputSequence == 0)

      await #expect(throws: BootstrapErrorCode.unknownSession) {
        try await registry.resume(.random())
      }
    }
  }

  @Test
  func `bootstrap requests are validated before anything is created`()
    async throws
  {
    try await withRegistry { registry async throws in
      let unsupported = await registry.handle(
        BootstrapRequest(
          operation: .create,
          protocols: ["RST/2"],
          initialGrid: Self.grid
        )
      )
      #expect(unsupported == .failure(.unsupportedVersion))
      let badGrid = await registry.handle(
        BootstrapRequest(
          operation: .create,
          initialGrid: GridSize(columns: 0, rows: 24)
        )
      )
      #expect(badGrid == .failure(.malformed))
      #expect(try await registry.list().isEmpty)

      let created = await registry.handle(
        BootstrapRequest(operation: .create, initialGrid: Self.grid)
      )
      guard case let .granted(grant) = created else {
        Issue.record("create failed")
        return
      }
      #expect(
        await registry.handle(BootstrapRequest(operation: .list))
          == .sessions(try await registry.list())
      )
      #expect(
        await registry.handle(
          BootstrapRequest(operation: .terminate, sessionID: grant.sessionID)
        ) == .terminated(grant.sessionID)
      )
      #expect(
        await registry.handle(
          BootstrapRequest(operation: .terminate, sessionID: grant.sessionID)
        ) == .failure(.unknownSession)
      )
      #expect(try await registry.list().isEmpty)
    }
  }
}
#endif
