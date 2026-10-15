import Foundation
import ScreenProtocol
import SessionCore
import TerminalSurface
import Testing

@testable import RoamingApp

/// SSH succeeded and granted an attachment; the grant's QUIC endpoint did
/// not answer (spec.connection-setup.md T12).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RoamingEndpointStageTests {
  @Test
  func unreachableEndpointIsReportedAsItsOwnStageWithTheGrantedEndpoint()
    async throws
  {
    let host = try FakeHost()
    let connector = FakeConnector(host: host)
    await connector.fail(next: 100)
    let clock = TestClock(factor: 20)
    let client = RoamingClient(
      bootstrapper: FakeBootstrapper(host: host),
      connector: connector,
      configuration: testConfiguration(),
      timing: clock.timing
    )
    try await client.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(
      await eventually {
        await client.status.lastFailure == .endpointUnreachable
      }
    )
    let status = await client.status
    #expect(status.state == .attaching || status.state == .reconnecting)
    // The grant's endpoint, verbatim; never the SSH host.
    #expect(
      status.roamingEndpoint
        == BootstrapEndpoint(host: "127.0.0.1", port: 51222)
    )
    #expect(status.lastFailure != .authenticationFailed)
    #expect(!String(describing: status).contains("applicationToken"))
    await client.close()
  }

  @Test
  func noticeNamesTheStageAndEndpointWithoutGuessingTheCause() throws {
    let endpoint = BootstrapEndpoint(host: "macbook.local", port: 51222)
    let notice = try #require(
      EndpointStageNotice(
        state: .reconnecting,
        failure: .endpointUnreachable,
        endpoint: endpoint
      )
    )
    #expect(
      EndpointStageNotice.title == "SSH connected; roaming endpoint unavailable"
    )
    #expect(notice.endpoint == "macbook.local:51222 (UDP)")
    #expect(notice.detail.contains("macbook.local:51222"))
    for blamed in ["firewall", "permission", "password", "Authentication"] {
      #expect(!notice.detail.localizedCaseInsensitiveContains(blamed))
    }
    let timeout = try #require(
      EndpointStageNotice(
        state: .attaching,
        failure: .attachTimedOut,
        endpoint: BootstrapEndpoint(host: "fd00::5", port: 4000)
      )
    )
    #expect(timeout.endpoint == "[fd00::5]:4000 (UDP)")
    #expect(timeout.detail.contains("did not answer in time"))
  }

  @Test
  func noticeIsAbsentForOtherStages() {
    let endpoint = BootstrapEndpoint(host: "mac.local", port: 1)
    #expect(
      EndpointStageNotice(
        state: .active,
        failure: .endpointUnreachable,
        endpoint: endpoint
      ) == nil
    )
    #expect(
      EndpointStageNotice(
        state: .reconnecting,
        failure: .authenticationFailed,
        endpoint: endpoint
      ) == nil
    )
    #expect(
      EndpointStageNotice(
        state: .reconnecting,
        failure: .unreachable,
        endpoint: endpoint
      ) == nil
    )
    #expect(
      EndpointStageNotice(
        state: .attaching,
        failure: .endpointUnreachable,
        endpoint: nil
      ) == nil
    )
  }
}
