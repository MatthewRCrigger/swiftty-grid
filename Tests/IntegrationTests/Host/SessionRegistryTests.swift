#if os(macOS)
import AppleTransport
import Foundation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
@testable import TerminalHost
import TestSupport
import Testing

@Suite(.timeLimit(.minutes(1)))
struct SessionRegistryTests {
  private static let grid = GridSize(columns: 80, rows: 24)

  @Test
  func `grants carry the injected identity, service epoch and bounded token lifetime`()
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
        await registry.workspaces().map(\.id) == [grant.sessionID.workspace]
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
        ).spkiSHA256 == grant.serverSPKISHA256
      )
      let lifetime = grant.tokenExpiresAt - Date().timeIntervalSince1970
      #expect(lifetime > 8 * 3600 - 60 && lifetime <= 8 * 3600)
      #expect(grant.initialGrid == Self.grid)
      #expect(!grant.description.contains(grant.applicationToken.bytes.description))
    }
  }

  @Test
  func `at most eight sessions`() async throws {
    try await withRegistry { registry in
      for _ in 0 ..< 8 { _ = try await registry.create(grid: Self.grid) }
      await #expect(throws: BootstrapErrorCode.sessionLimit) {
        try await registry.create(grid: Self.grid)
      }
      #expect(await registry.list().count == 8)
      #expect(await registry.list().allSatisfy { $0.state == .reserved })
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
      #expect(await registry.sweep(now: .now + .seconds(1)) == [grant.sessionID])
      try await hostEventuallyAsync("workspace ended") {
        await registry.workspaces().isEmpty ? true : nil
      }
      let client = TestClient(registry)
      try await client.attach(grant)
      #expect(try await client.errorCode() == .unknownSession)
    }
  }

  @Test
  func `detached retention revokes the grant but keeps the shell`()
    async throws
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
        await registry.sweep(now: .now + .seconds(24 * 3600 + 1))
          == [grant.sessionID]
      )
      // Remote authorization ended; the local shell lifetime is separate.
      #expect(isAlive(pid))
      #expect(await registry.workspaces().count == 1)
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
  func `attachment failures fail closed`() async throws {
    var policy = RegistryPolicy()
    policy.tokenLifetime = .milliseconds(150)
    try await withRegistry(policy: policy) { registry in
      let grant = try await registry.create(grid: Self.grid)
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

      #expect(session.status.state == .reserved)
      // Nothing attached: no lease was taken.
      #expect(await registry.workspaces().first?.isAttached == false)
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
  func `resume issues fresh credentials and revokes the previous ones`()
    async throws
  {
    try await withRegistry { registry in
      let first = try await registry.create(grid: Self.grid)
      let kept = try await registry.resume(first.sessionID, writerID: first.writerID)
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
    try await withRegistry { registry in
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
      #expect(await registry.list().isEmpty)

      let created = await registry.handle(
        BootstrapRequest(operation: .create, initialGrid: Self.grid)
      )
      guard case let .granted(grant) = created else {
        Issue.record("create failed")
        return
      }
      #expect(
        await registry.handle(BootstrapRequest(operation: .list))
          == .sessions(await registry.list())
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
      #expect(await registry.list().isEmpty)
    }
  }
}
#endif
