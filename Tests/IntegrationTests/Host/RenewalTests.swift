#if os(macOS)
import AppleTransport
import Foundation
import ScreenProtocol
import SessionCore
@testable import TerminalHost
import TestSupport
import Testing

/// The service never idle-exits while roaming, so the QUIC certificate
/// must be renewed while it runs (spec.inbox.md §1.8).
@Suite(.timeLimit(.minutes(1)))
struct RenewalTests {
  @Test
  func `the certificate is renewed before it expires and new grants pin it`()
    async throws
  {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = HostConfiguration(
      bindAddress: "127.0.0.1",
      port: 0,
      advertisedHost: "127.0.0.1",
      stateDirectory: directory.appendingPathComponent("state").path
    )
    let host = try await RoamingHost.start(service: try makeService(), configuration: config)
    let before = host.registry.identity.certificate
    // Not yet within the renewal margin: nothing changes.
    #expect(await host.renewIfNeeded() == false)
    #expect(host.registry.identity.certificate == before)

    // Four weeks on, inside the three-day margin of a 30-day certificate.
    #expect(await host.renewIfNeeded(now: Date().addingTimeInterval(28 * 24 * 3600)))
    let after = host.registry.identity.certificate
    #expect(after != before)
    let grant = try await host.registry.create(grid: GridSize(columns: 80, rows: 24))
    #expect(grant.serverCertificateDER == after.der)
    #expect(grant.endpoint.port == host.registry.identity.endpoint.port)
    await host.registry.terminate(grant.sessionID)
  }
}
#endif
