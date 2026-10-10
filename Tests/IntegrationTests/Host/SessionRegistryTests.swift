#if os(macOS)
import Foundation
import ScreenProtocol
import SessionCore
@testable import TerminalHost
import TestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SessionRegistryTests {
  @Test
  func `grants carry the injected identity and bounded token lifetime`() throws {
    let registry = SessionRegistry(identity: testIdentity())
    let grant = try registry.create(grid: GridSize(columns: 80, rows: 24))
    #expect(grant.protocol == "RST/1")
    #expect(grant.serverInstanceID == registry.serverInstanceID)
    #expect(grant.endpoint == testIdentity().endpoint)
    #expect(grant.serverCertificateDER == testIdentity().certificate.der)
    #expect(grant.serverCertificateSHA256.count == 64)
    #expect(
      HostCertificate(
        der: grant.serverCertificateDER,
        sha256Hex: grant.serverCertificateSHA256
      ) != nil
    )
    let lifetime = grant.tokenExpiresAt - Date().timeIntervalSince1970
    #expect(lifetime > 8 * 3600 - 60 && lifetime <= 8 * 3600)
    #expect(grant.initialGrid == GridSize(columns: 80, rows: 24))
    #expect(!grant.description.contains(grant.applicationToken.bytes.description))
  }

  @Test
  func `at most eight sessions`() throws {
    let registry = SessionRegistry(identity: testIdentity())
    for _ in 0 ..< 8 {
      _ = try registry.create(grid: GridSize(columns: 80, rows: 24))
    }
    #expect(throws: BootstrapErrorCode.sessionLimit) {
      try registry.create(grid: GridSize(columns: 80, rows: 24))
    }
    #expect(registry.list().count == 8)
    #expect(registry.list().allSatisfy { $0.state == .reserved })
  }

  @Test
  func `unattached reservations expire`() async throws {
    var policy = RegistryPolicy()
    policy.reservationLifetime = .milliseconds(100)
    try await withRegistry(policy: policy) { registry in
      let grant = try registry.create(grid: GridSize(columns: 80, rows: 24))
      #expect(await registry.sweep().isEmpty)
      #expect(await registry.sweep(now: .now + .seconds(1)) == [grant.sessionID])
      let client = TestClient(registry)
      try await client.attach(grant)
      #expect(try await client.errorCode() == .unknownSession)
    }
  }

  @Test
  func `detached sessions are retained until idle past the retention`()
    async throws
  {
    try await withRegistry { registry in
      let grant = try registry.create(grid: GridSize(columns: 80, rows: 24))
      let client = TestClient(registry)
      _ = try await client.attached(grant)
      client.connection.sever()
      let session = try #require(registry.session(grant.sessionID))
      try await hostEventually("detached") {
        session.status.state == .detached ? true : nil
      }
      #expect(await registry.sweep(now: .now + .seconds(3600)).isEmpty)
      #expect(
        await registry.sweep(now: .now + .seconds(24 * 3600 + 1))
          == [grant.sessionID]
      )
      #expect(session.status.state == .terminated)
    }
  }

  @Test
  func `attachment failures fail closed without starting a shell`() async throws
  {
    var policy = RegistryPolicy()
    policy.tokenLifetime = .milliseconds(150)
    try await withRegistry(policy: policy) { registry in
      let grant = try registry.create(grid: GridSize(columns: 80, rows: 24))
      let session = try #require(registry.session(grant.sessionID))

      let early = TestClient(registry)
      try await early.send(
        .input(.init(attachmentEpoch: 1, sequence: 1, operation: .committedText("x")))
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
      try await writer.attach(wrongWriter)
      #expect(try await writer.errorCode() == .unauthorized)

      try await Task.sleep(for: .milliseconds(200))
      let expired = TestClient(registry)
      try await expired.attach(grant)
      #expect(try await expired.errorCode() == .expired)

      #expect(session.status.pid == nil)
      #expect(session.status.state == .reserved)
    }
  }

  @Test
  func `attachment attempts are rate limited`() async throws {
    var policy = RegistryPolicy()
    policy.attachFailureLimit = 3
    try await withRegistry(policy: policy) { registry in
      let grant = try registry.create(grid: GridSize(columns: 80, rows: 24))
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
  func `resume issues fresh credentials and revokes the previous ones`()
    async throws
  {
    try await withRegistry { registry in
      let first = try registry.create(grid: GridSize(columns: 80, rows: 24))
      let kept = try registry.resume(first.sessionID, writerID: first.writerID)
      #expect(kept.writerID == first.writerID)
      #expect(kept.applicationToken != first.applicationToken)
      let fresh = try registry.resume(first.sessionID)
      #expect(fresh.writerID != first.writerID)

      let revoked = TestClient(registry)
      try await revoked.attach(kept)
      #expect(try await revoked.errorCode() == .unauthorized)

      let client = TestClient(registry)
      let attached = try await client.attached(fresh)
      #expect(attached.writerID == fresh.writerID)
      #expect(attached.lastFullyAppliedInputSequence == 0)

      #expect(throws: BootstrapErrorCode.unknownSession) {
        try registry.resume(.random())
      }
    }
  }

  @Test
  func `bootstrap requests are validated before anything is created`() async {
    let registry = SessionRegistry(identity: testIdentity())
    let unsupported = await registry.handle(
      BootstrapRequest(
        operation: .create,
        protocols: ["RST/2"],
        initialGrid: GridSize(columns: 80, rows: 24)
      )
    )
    #expect(unsupported == .failure(.unsupportedVersion))
    let badGrid = await registry.handle(
      BootstrapRequest(operation: .create, initialGrid: GridSize(columns: 0, rows: 24))
    )
    #expect(badGrid == .failure(.malformed))
    #expect(registry.list().isEmpty)

    let created = await registry.handle(
      BootstrapRequest(operation: .create, initialGrid: GridSize(columns: 80, rows: 24))
    )
    guard case let .granted(grant) = created else {
      Issue.record("create failed")
      return
    }
    #expect(await registry.handle(BootstrapRequest(operation: .list)) == .sessions(registry.list()))
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
    #expect(registry.list().isEmpty)
  }
}
#endif
