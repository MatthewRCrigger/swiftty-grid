#if os(macOS)
  @testable import AppleTransport
  import Darwin
  import Foundation
  import ScreenProtocol
  import SessionCore
  import Synchronization
  import Testing

  /// A loopback UDP relay between one QUIC client and the server. `rebind()`
  /// moves the server-facing side to a new local port, so the server sees
  /// the client's address change mid-connection, as when a phone moves
  /// from Wi-Fi to cellular behind NAT (RFC 9000 §9).
  ///
  /// Old server-facing sockets stay open and silently discard traffic, as
  /// a NAT drops packets for an abandoned mapping. (Closing them makes the
  /// loopback stack answer with ICMP port-unreachable, which a real path
  /// change seldom produces.)
  final class RebindingUDPRelay: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let server: sockaddr_in
    private let state = Mutex<(upstream: Int32, client: sockaddr_in?, rebinds: Int, retired: [Int32])>((-1, nil, 0, []))
    private let running = Atomic<Bool>(true)
    private let thread: Thread

    init(serverPort: UInt16) throws {
      func loopback(_ port: UInt16) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return a
      }
      let fd = socket(AF_INET, SOCK_DGRAM, 0)
      var local = loopback(0)
      _ = withUnsafePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      var bound = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      _ = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          getsockname(fd, $0, &length)
        }
      }
      listenFD = fd
      port = UInt16(bigEndian: bound.sin_port)
      server = loopback(serverPort)
      let upstream = Self.newUpstream()
      state.withLock { $0.upstream = upstream }
      thread = Thread {}
      let relay = Unmanaged.passUnretained(self)
      let worker = Thread { relay.takeUnretainedValue().pump() }
      worker.start()
    }

    private static func newUpstream() -> Int32 {
      let fd = socket(AF_INET, SOCK_DGRAM, 0)
      var any = sockaddr_in()
      any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      any.sin_family = sa_family_t(AF_INET)
      any.sin_addr.s_addr = inet_addr("127.0.0.1")
      _ = withUnsafePointer(to: &any) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      return fd
    }

    /// The server now sees packets from a different address (new port).
    func rebind() {
      let fresh = Self.newUpstream()
      state.withLock { s in
        s.retired.append(s.upstream)
        s.upstream = fresh
        s.rebinds += 1
      }
    }

    func stop() {
      running.store(false, ordering: .relaxed)
      close(listenFD)
      state.withLock { s in
        close(s.upstream)
        for fd in s.retired { close(fd) }
      }
    }

    private func pump() {
      var buffer = [UInt8](repeating: 0, count: 65536)
      var server = server
      while running.load(ordering: .relaxed) {
        let upstream = state.withLock { $0.upstream }
        var fds = [
          pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
          pollfd(fd: upstream, events: Int16(POLLIN), revents: 0),
        ]
        guard poll(&fds, 2, 50) > 0 else { continue }
        if fds[0].revents & Int16(POLLIN) != 0 {
          var from = sockaddr_in()
          var length = socklen_t(MemoryLayout<sockaddr_in>.size)
          let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              recvfrom(listenFD, &buffer, buffer.count, 0, $0, &length)
            }
          }
          if n > 0 {
            state.withLock { $0.client = from }
            _ = withUnsafePointer(to: &server) {
              $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(upstream, buffer, n, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
              }
            }
          }
        }
        if fds[1].revents & Int16(POLLIN) != 0 {
          let n = recv(upstream, &buffer, buffer.count, 0)
          if n > 0, var client = state.withLock({ $0.client }) {
            _ = withUnsafePointer(to: &client) {
              $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(listenFD, buffer, n, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
              }
            }
          }
        }
      }
    }
  }

  /// Network framework's QUIC listener (OS 27 SDK) accepts packets from a
  /// client's new address on the same connection, but keeps sending to the
  /// old address: server-to-client traffic does not follow the migration.
  /// The roaming client therefore relies on reattachment after a path
  /// change (spec §7.1, §9), covered end to end by `RoamingEndToEndTests`.
  @Suite(.serialized)
  struct MigrationTests {
    @Test func `client traffic reaches the same connection after its address changes`()
      async throws
    {
      let (listener, accepted) = try await startListener()
      defer { listener.stop() }
      let relay = try RebindingUDPRelay(serverPort: listener.port)
      defer { relay.stop() }

      let client = try await connector().connectQUIC(
        host: "127.0.0.1", port: relay.port, pin: loopbackIdentity.pin
      )
      defer { client.close() }
      let clientInbox = Inbox()
      client.start(clientInbox.handler)

      try await client.sendControl(ControlRecord.encode(.ping(epoch: 1, nonce: 1)))
      try await transportEventually { accepted.count == 1 }
      let (_, serverInbox) = try #require(accepted.all.first)
      try await transportEventually { serverInbox.messages.count == 1 }

      // After the move the server still receives on the same connection.
      // (With no acknowledgements reaching the client's new address, its
      // sending soon stalls; that is the reattachment case.)
      relay.rebind()
      try await client.sendControl(ControlRecord.encode(.ping(epoch: 1, nonce: 2)))
      try await transportEventually { serverInbox.messages.count == 2 }
      #expect(accepted.count == 1)
      #expect(!serverInbox.closed)
      #expect(serverInbox.messages == [.ping(epoch: 1, nonce: 1), .ping(epoch: 1, nonce: 2)])
    }
  }
#endif
