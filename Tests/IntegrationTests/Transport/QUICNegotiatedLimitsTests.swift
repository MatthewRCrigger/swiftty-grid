#if os(macOS)
@testable import AppleTransport
import Foundation
import ScreenProtocol
import SessionCore
import TerminalSurface
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct QUICNegotiatedLimitsTests {
  @Test(arguments: [false, true], [false, true])
  func negotiatedSnapshotLimitsReachNativeReceiver(
    _ throughGrant: Bool,
    _ decoded: Bool
  ) async throws {
    let (listener, accepted) = try await startListener()
    defer { listener.stop() }
    var limits = NegotiatedLimits()
    limits.maxSnapshotEncodedBytes = decoded ? 128 : 32
    limits.maxSnapshotDecodedBytes = decoded ? 32 : 128
    let client: QUICRSTConnection
    if throughGrant {
      let grant = BootstrapGrant(
        serverInstanceID: .random(),
        sessionID: .random(),
        writerID: .random(),
        endpoint: .init(host: "127.0.0.1", port: listener.port),
        serverCertificateDER: loopbackIdentity.certificateDER,
        serverCertificateSHA256: loopbackIdentity.certificateSHA256,
        applicationToken: .random(),
        tokenExpiresAt: Date().timeIntervalSince1970 + 3600,
        initialGrid: .init(columns: 20, rows: 4),
        limits: limits
      )
      let connection = try await QUICGrantConnector(connector: connector())
        .connect(to: grant)
      client = try #require(connection as? QUICRSTConnection)
    } else {
      client = try await connector()
        .connectQUIC(
          host: "127.0.0.1",
          port: listener.port,
          pin: loopbackIdentity.pin,
          limits: limits
        )
    }
    defer { client.close() }
    let inbox = Inbox()
    client.start(inbox.handler)
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 1))
    )
    try await transportEventually { accepted.count == 1 }
    let (server, serverInbox) = try #require(accepted.all.first)
    let restoredCredit = QUICOptions.concurrentSnapshotStreams + 1
    try await server.sendSnapshot(
      snapshotPayload(bodyLength: 64, fill: 1),
      stream: 1
    )
    // Returned stream credit proves rejection was processed, without a
    // sleep-based assertion that an oversized payload never arrived.
    try await transportEventually {
      client.snapshotDiagnosticsForTesting.contains(
        "localMaxStreams=Optional(\(restoredCredit))"
      )
    }
    #expect(inbox.snapshots.isEmpty)
    let valid = snapshotPayload(bodyLength: 32, fill: 2)
    try await server.sendSnapshot(valid, stream: 2)
    try await transportEventually { inbox.snapshots == [valid] }
    try await client.sendControl(
      ControlRecord.encode(.ping(epoch: 1, nonce: 2))
    )
    try await transportEventually { serverInbox.messages.count == 2 }
    #expect(!client.isClosed)
    #expect(!server.isClosed)
  }
}
#endif
