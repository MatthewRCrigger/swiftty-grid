#if os(macOS)
  @testable import AppleTransport
  import Foundation
  import Network
  import ScreenProtocol
  import SessionCore
  import Synchronization
  import Testing

  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct QUICTransportTests {
    @Test func `control records round trip in both directions`() async throws {
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      #expect(listener.port != 0)

      let client = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
      )
      defer { client.close() }
      #expect(client.negotiatedALPN == RSTLimits.alpn)
      let clientInbox = Inbox()
      client.start(clientInbox.handler)

      for nonce in 1 ... 3 as ClosedRange<UInt64> {
        try await client.sendControl(
          ControlRecord.encode(.ping(epoch: 1, nonce: nonce))
        )
      }
      try await eventually { accepted.all.first?.1.messages.count == 3 }
      let (server, serverInbox) = try #require(accepted.all.first)
      #expect(
        serverInbox.messages
          == (1 ... 3).map { ControlMessage.ping(epoch: 1, nonce: $0) }
      )

      // Several records in one write still decode in order.
      var batch: [UInt8] = []
      for nonce in 1 ... 3 as ClosedRange<UInt64> {
        batch += try ControlRecord.encode(.pong(epoch: 1, nonce: nonce))
      }
      try await server.sendControl(batch)
      try await eventually { clientInbox.messages.count == 3 }
      #expect(
        clientInbox.messages
          == (1 ... 3).map { ControlMessage.pong(epoch: 1, nonce: $0) }
      )

      client.close()
      try await eventually { serverInbox.closed && clientInbox.closed }
      try await eventually { listener.activeConnectionCount == 0 }
    }

    @Test func `slow onControl applies backpressure in order`() async throws {
      // A slow consumer: concurrent onControl calls would overlap.
      let tracker = OverlapTracker()
      let listener = QUICRSTListener(
        identity: loopbackIdentity, configuration: .init(host: "127.0.0.1")
      )
      try await listener.start { connection in
        connection.start(
          RSTConnectionHandler(
            onControl: { bytes in
              tracker.enter(bytes.count)
              try? await Task.sleep(for: .milliseconds(20))
              tracker.leave()
              tracker.consumed(bytes.count)
            },
            onClosed: { _ in }
          )
        )
      }
      defer { listener.stop() }
      let client = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
      )
      defer { client.close() }
      var total = 0
      for nonce in 1 ... 10 as ClosedRange<UInt64> {
        let record = try ControlRecord.encode(.ping(epoch: 1, nonce: nonce))
        total += record.count
        try await client.sendControl(record)
      }
      try await eventually { tracker.bytes == total }
      #expect(tracker.maxConcurrent == 1)
    }

    @Test func `one connection carries far more snapshots than the stream limit`()
      async throws
    {
      // QUIC stream credit is cumulative: the client must keep extending
      // it or the server stalls after its initial allowance.
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      let client = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
      )
      defer { client.close() }
      let inbox = Inbox()
      client.start(inbox.handler)
      try await client.sendControl(ControlRecord.encode(.ping(epoch: 1, nonce: 1)))
      try await transportEventually { accepted.count == 1 }
      let (server, _) = try #require(accepted.all.first)
      for id in 1 ... 60 as ClosedRange<UInt64> {
        try await server.sendSnapshot(
          snapshotPayload(bodyLength: 200, fill: UInt8(id)),
          stream: id
        )
        try await transportEventually { inbox.snapshots.count == Int(id) }
      }
    }

    @Test func `snapshot streams deliver complete payloads and drop a canceled one`()
      async throws
    {
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      let client = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
      )
      defer { client.close() }
      let inbox = Inbox()
      client.start(inbox.handler)
      try await client.sendControl(ControlRecord.encode(.ping(epoch: 1, nonce: 1)))
      try await eventually { accepted.count == 1 }
      let (server, _) = try #require(accepted.all.first)

      let small = snapshotPayload(bodyLength: 1000, fill: 0xA1)
      let medium = snapshotPayload(bodyLength: 300_000, fill: 0xB2)
      let huge = snapshotPayload(
        bodyLength: RSTLimits.maxSnapshotEncodedBytes, fill: 0xC3
      )
      let last = snapshotPayload(bodyLength: 50_000, fill: 0xD4)

      try await server.sendSnapshot(small, stream: 1)
      try await server.sendSnapshot(medium, stream: 2)
      // Cancel the 4 MiB stream while it is still in flight.
      let hugeSend = Task { try await server.sendSnapshot(huge, stream: 3) }
      try await Task.sleep(for: .milliseconds(5))
      server.cancelSnapshot(stream: 3)
      let hugeResult = await hugeSend.result
      try await server.sendSnapshot(last, stream: 4)

      try await eventually { inbox.snapshots.contains(last) }
      try await Task.sleep(for: .milliseconds(200))
      let received = inbox.snapshots
      #expect(received.contains(small))
      #expect(received.contains(medium))
      // Never a partial payload: anything delivered is one of the sends.
      for payload in received {
        #expect([small, medium, huge, last].contains(payload))
      }
      #expect(received.count(where: { $0 == huge }) <= 1)
      // Canceled before its send completed (bytes already queued in QUIC
      // may still arrive whole, which is allowed).
      if case let .failure(error) = hugeResult {
        #expect(error as? RSTTransportError == .canceled)
      }
      // A pre-canceled id never opens a stream.
      server.cancelSnapshot(stream: 9)
      await #expect(throws: RSTTransportError.canceled) {
        try await server.sendSnapshot(small, stream: 9)
      }
    }

    @Test func `a reset partial stream is never delivered`() async throws {
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      let client = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
      )
      defer { client.close() }
      let inbox = Inbox()
      client.start(inbox.handler)
      try await client.sendControl(ControlRecord.encode(.ping(epoch: 1, nonce: 1)))
      try await eventually { accepted.count == 1 }
      let (server, _) = try #require(accepted.all.first)

      let full = snapshotPayload(bodyLength: 10_000, fill: 0x11)
      let partial = try await server.sendRawStreamForTesting(
        Array(full.prefix(5_000)), finish: false
      )
      try await Task.sleep(for: .milliseconds(100))
      partial.cancel()
      // FIN after a truncated body is not a complete snapshot either.
      _ = try await server.sendRawStreamForTesting(
        Array(full.prefix(7_000)), finish: true
      )
      let good = snapshotPayload(bodyLength: 64, fill: 0x22)
      try await server.sendSnapshot(good, stream: 1)
      try await eventually { !inbox.snapshots.isEmpty }
      try await Task.sleep(for: .milliseconds(200))
      #expect(inbox.snapshots == [good])
    }

    @Test func `oversized and overlong snapshot streams are discarded`()
      async throws
    {
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      let client = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
      )
      defer { client.close() }
      let inbox = Inbox()
      client.start(inbox.handler)
      try await client.sendControl(ControlRecord.encode(.ping(epoch: 1, nonce: 1)))
      try await eventually { accepted.count == 1 }
      let (server, _) = try #require(accepted.all.first)

      // Header claims more than the 4 MiB bound.
      var oversized = snapshotPayload(bodyLength: 16, fill: 0)
      let tooBig = UInt32(RSTLimits.maxSnapshotEncodedBytes + 1)
      for offset in [1, 5] {
        oversized[offset] = UInt8(tooBig >> 24)
        oversized[offset + 1] = UInt8(tooBig >> 16 & 0xFF)
        oversized[offset + 2] = UInt8(tooBig >> 8 & 0xFF)
        oversized[offset + 3] = UInt8(tooBig & 0xFF)
      }
      _ = try await server.sendRawStreamForTesting(oversized, finish: true)
      // More bytes than the header announced.
      let overlong = snapshotPayload(bodyLength: 100, fill: 1) + [1, 2, 3]
      _ = try await server.sendRawStreamForTesting(overlong, finish: true)
      // The sender refuses to exceed the bound itself.
      await #expect(throws: RSTTransportError.snapshotTooLarge) {
        try await server.sendSnapshot(
          [UInt8](repeating: 0, count: SnapshotStreamAccumulator.hardLimit + 1),
          stream: 7
        )
      }

      let good = snapshotPayload(bodyLength: 32, fill: 0x33)
      try await server.sendSnapshot(good, stream: 1)
      try await eventually { !inbox.snapshots.isEmpty }
      try await Task.sleep(for: .milliseconds(200))
      #expect(inbox.snapshots == [good])
      #expect(!inbox.closed)
    }

    @Test func `wrong pin fails closed before application data`() async throws {
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      let other = try HostIdentity.generate(hostnames: ["localhost"])

      await #expect(throws: RSTTransportError.pinMismatch) {
        _ = try await connector().connect(
          host: "127.0.0.1", port: listener.port, pin: other.pin
        )
      }
      try await Task.sleep(for: .milliseconds(200))
      #expect(accepted.count == 0)
      #expect(listener.activeConnectionCount == 0)
    }

    @Test func `changed SPKI pin fails the handshake before application data`()
      async throws
    {
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      // The grant names another key: the server's leaf fails the SPKI
      // check in the verify block, so no connection (and no Attach with
      // the token) ever reaches the server.
      let other = try HostIdentity.generate(hostnames: ["localhost"])
      let pin = try CertificatePin(
        certificateDER: other.certificateDER,
        sha256: other.certificateSHA256,
        spkiSHA256: other.spkiSHA256
      )
      #expect(throws: CertificatePinError.spkiMismatch) {
        try pin.validate(leafDER: loopbackIdentity.certificateDER)
      }
      await #expect(throws: RSTTransportError.pinMismatch) {
        _ = try await connector().connect(
          host: "127.0.0.1", port: listener.port, pin: pin
        )
      }
      try await Task.sleep(for: .milliseconds(200))
      #expect(accepted.count == 0)
      #expect(listener.activeConnectionCount == 0)
    }

    @Test func `pin with matching hash but different DER cannot be built`()
      throws
    {
      let other = try HostIdentity.generate()
      #expect(throws: CertificatePinError.inconsistentPin) {
        try CertificatePin(
          certificateDER: other.certificateDER,
          sha256: loopbackIdentity.certificateSHA256
        )
      }
    }

    @Test func `ALPN mismatch fails the handshake`() async throws {
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      await #expect(throws: RSTTransportError.self) {
        _ = try await connector("rst/0", timeout: .seconds(2)).connect(
          host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
        )
      }
      try await Task.sleep(for: .milliseconds(200))
      #expect(accepted.count == 0)
    }

    @Test func `listener caps concurrent connections`() async throws {
      let (listener, accepted) = try await startListener(
        .init(host: "127.0.0.1", maxConnections: 2)
      )
      defer { listener.stop() }
      let pin = loopbackIdentity.pin
      let first = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: pin
      )
      let second = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: pin
      )
      try await eventually { accepted.count == 2 }

      // The third group is refused; depending on when Network hands the
      // group to the listener the client either fails to connect or sees
      // the connection closed straight away.
      let inbox = Inbox()
      do {
        let third = try await connector(timeout: .seconds(2)).connectQUIC(
          host: "127.0.0.1", port: listener.port, pin: pin
        )
        third.start(inbox.handler)
        try await eventually { inbox.closed }
      } catch {}
      #expect(listener.rejectedConnectionCount >= 1)
      #expect(listener.activeConnectionCount == 2)
      #expect(accepted.count == 2)

      first.close()
      try await eventually { listener.activeConnectionCount == 1 }
      let fourth = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: pin
      )
      try await eventually { accepted.count == 3 }
      fourth.close()
      second.close()
    }

    @Test func `listener rate-limits new handshakes`() async throws {
      let (listener, accepted) = try await startListener(
        .init(host: "127.0.0.1", handshakesPerSecond: 0.01, handshakeBurst: 1)
      )
      defer { listener.stop() }
      let first = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
      )
      defer { first.close() }
      do {
        let second = try await connector(timeout: .seconds(2)).connectQUIC(
          host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
        )
        let inbox = Inbox()
        second.start(inbox.handler)
        try await eventually { inbox.closed }
      } catch {}
      #expect(listener.rejectedConnectionCount >= 1)
      try await eventually { accepted.count == 1 }
    }

    @Test func `closing the listener closes its connections`() async throws {
      let (listener, accepted) = try await startListener()
      let client = try await connector().connectQUIC(
        host: "127.0.0.1", port: listener.port, pin: loopbackIdentity.pin
      )
      let inbox = Inbox()
      client.start(inbox.handler)
      try await eventually { accepted.count == 1 }
      listener.stop()
      try await eventually { inbox.closed }
      await #expect(throws: (any Error).self) {
        try await client.sendControl(
          ControlRecord.encode(.ping(epoch: 1, nonce: 1))
        )
      }
    }
  }

  final class OverlapTracker: Sendable {
    private struct State {
      var current = 0
      var maxConcurrent = 0
      var bytes = 0
    }

    private let state = Mutex(State())

    func enter(_ count: Int) {
      state.withLock {
        $0.current += 1
        $0.maxConcurrent = max($0.maxConcurrent, $0.current)
      }
    }

    func leave(_ count: Int = 0) {
      state.withLock { $0.current -= 1 }
    }

    /// Bytes fully consumed (counted on exit so a test waits for the end).
    func consumed(_ count: Int) { state.withLock { $0.bytes += count } }
    var maxConcurrent: Int { state.withLock { $0.maxConcurrent } }
    var bytes: Int { state.withLock { $0.bytes } }
  }
#endif
