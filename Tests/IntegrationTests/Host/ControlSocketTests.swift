#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol
import SessionCore
@testable import TerminalHost
import TestSupport
import Testing

private func envelope(_ request: BootstrapRequest) throws -> [UInt8] {
  try BootstrapEnvelope.encode(request)
}

private func response(_ bytes: [UInt8]) throws -> BootstrapResponse {
  try BootstrapEnvelope.decode(BootstrapResponse.self, from: bytes)
}

@Suite(.timeLimit(.minutes(1)))
struct ControlSocketTests {
  @Test
  func `bootstrap envelope round trip over the control socket`() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try ControlDirectory.prepare(directory)
    let registry = SessionRegistry(service: try makeService(), identity: testIdentity())
    let service = BootstrapService(registry: registry)
    let server = try ControlSocketServer(directory: directory) {
      await service.respond(toEnvelope: $0)
    }
    try server.start()
    defer { server.stop() }

    var info = stat()
    #expect(lstat(server.path, &info) == 0)
    #expect(info.st_mode & S_IFMT == S_IFSOCK)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(info.st_uid == getuid())
    #expect(lstat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)

    let request = BootstrapRequest(
      operation: .create,
      initialGrid: GridSize(columns: 100, rows: 30)
    )
    let reply = try response(
      BootstrapService.forward(
        envelope: try envelope(request),
        socketPath: server.path
      )
    )
    guard case let .granted(grant) = reply else {
      Issue.record("expected a grant, got \(reply)")
      return
    }
    #expect(grant.endpoint == testIdentity().endpoint)
    #expect(grant.serverCertificateSHA256 == testIdentity().certificate.sha256Hex)
    #expect(grant.initialGrid == GridSize(columns: 100, rows: 30))
    #expect((await registry.list()).count == 1)

    let listed = try response(
      BootstrapService.forward(
        envelope: try envelope(BootstrapRequest(operation: .list)),
        socketPath: server.path
      )
    )
    #expect(listed == .sessions((await registry.list())))
    await registry.terminate(grant.sessionID)
  }

  @Test
  func `malformed and unsupported requests create nothing`() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = SessionRegistry(service: try makeService(), identity: testIdentity())
    let service = BootstrapService(registry: registry)
    let server = try ControlSocketServer(directory: directory) {
      await service.respond(toEnvelope: $0)
    }
    try server.start()
    defer { server.stop() }

    let oversized: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF] + Array("{}".utf8)
    #expect(
      try response(BootstrapService.forward(envelope: oversized, socketPath: server.path))
        == .failure(.malformed)
    )
    let truncated = Array(try envelope(BootstrapRequest(operation: .list)).dropLast())
    #expect(
      try response(BootstrapService.forward(envelope: truncated, socketPath: server.path))
        == .failure(.malformed)
    )
    let unsupported = try envelope(
      BootstrapRequest(
        operation: .create,
        protocols: ["RST/9"],
        initialGrid: GridSize(columns: 80, rows: 24)
      )
    )
    #expect(
      try response(BootstrapService.forward(envelope: unsupported, socketPath: server.path))
        == .failure(.unsupportedVersion)
    )
    // The agent validates independently of the stdio client.
    #expect(
      try response(await service.respond(toEnvelope: unsupported))
        == .failure(.unsupportedVersion)
    )
    #expect((await registry.list()).isEmpty)
  }

  @Test
  func `peers with another UID are refused`() async throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let registry = SessionRegistry(service: try makeService(), identity: testIdentity())
    let service = BootstrapService(registry: registry)
    let server = try ControlSocketServer(
      directory: directory,
      expectedUID: getuid() + 1
    ) { await service.respond(toEnvelope: $0) }
    try server.start()
    defer { server.stop() }
    let request = try envelope(
      BootstrapRequest(operation: .create, initialGrid: GridSize(columns: 80, rows: 24))
    )
    #expect(
      try response(BootstrapService.forward(envelope: request, socketPath: server.path))
        == .failure(.agentUnavailable)
    )
    #expect((await registry.list()).isEmpty)
  }

  @Test
  func `insecure directories and missing agents are rejected`() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    chmod(directory.path, 0o755)
    #expect(throws: ControlSocketError.insecureDirectory) {
      try ControlSocketServer(directory: directory) { $0 }
    }
    chmod(directory.path, 0o700)
    let request = try envelope(BootstrapRequest(operation: .list))
    let missing = directory.appendingPathComponent("control.sock").path
    #expect(
      try response(BootstrapService.forward(envelope: request, socketPath: missing))
        == .failure(.agentUnavailable)
    )
  }

  @Test
  func `stdin envelopes are bounded before the body is read`() throws {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    defer {
      close(fds[0])
      close(fds[1])
    }
    let prefix: [UInt8] = [0x00, 0x10, 0x00, 0x01]  // 1 MiB + 1
    _ = prefix.withUnsafeBytes { write(fds[1], $0.baseAddress, 4) }
    #expect(throws: FramingError.recordTooLarge(0x0010_0001)) {
      try BootstrapService.readEnvelope(from: fds[0])
    }
    let good = try envelope(BootstrapRequest(operation: .list))
    _ = good.withUnsafeBytes { write(fds[1], $0.baseAddress, good.count) }
    #expect(try BootstrapService.readEnvelope(from: fds[0]) == good)
  }

  @Test
  func `service and bootstrap helper resolve the same configuration`() {
    #expect(
      HostConfiguration.resolvedConfigurationURL(environment: [:])
        == HostConfiguration.defaultConfigurationURL
    )
    #expect(
      HostConfiguration.resolvedConfigurationURL(
        environment: [HostConfiguration.environmentKey: "/tmp/rst.json"]
      ).path == "/tmp/rst.json"
    )
  }

  @Test
  func `configuration requires an explicit bind address`() throws {
    let json = #"{"bindAddress":"192.168.1.5","advertisedHost":"mac.local"}"#
    let config = try JSONDecoder().decode(
      HostConfiguration.self,
      from: Data(json.utf8)
    )
    #expect(config.port == 51222)
    #expect(config.bindAddress == "192.168.1.5")
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(
        HostConfiguration.self,
        from: Data(#"{"advertisedHost":"mac.local"}"#.utf8)
      )
    }
  }
}
#endif
