import Foundation
import MuxNavigation
import SwiftMuxProtocol
import Testing
import TestSupport

@MainActor
extension NavigatorTests {
  @Test(arguments: ["open", "select", "retry"])
  func cancellingFromConnectingDoesNotContactTheConnector(
    entry: String
  ) async throws {
    let chosen = NavigationHost(id: UUID(), name: "Selected host")
    let h = Harness(
      hosts: entry == "select" ? [chosen] : [],
      includeLinkedHost: entry != "select"
    )
    var initialConnections = 0
    try await RuntimeFixture.withCleanup {
      if entry == "select" {
        await h.navigator.open(h.url)
        #expect(h.navigator.state == .needsHostSelection([chosen]))
      } else if entry == "retry" {
        await h.service.setLocateError(.offline("Retry available"))
        await h.navigator.open(h.url)
        #expect(h.navigator.state == .unavailable(reason: "Retry available"))
        initialConnections = 1
      }
      let callsBefore = await h.service.calls
      let navigator = h.navigator
      var sawConnecting = false
      navigator.onStateChange = { [weak navigator] state in
        if case .connecting = state {
          sawConnecting = true
          navigator?.cancel()
        }
      }
      switch entry {
      case "select": await navigator.selectHost(chosen)
      case "retry": await navigator.retry()
      default: await navigator.open(h.url)
      }
      #expect(sawConnecting)
      #expect(navigator.state == .idle)
      #expect(navigator.destination == nil)
      #expect(await h.connector.connectedHosts.count == initialConnections)
      let metadataAfter = await h.service.calls.filter { $0 != .close }
      #expect(metadataAfter == callsBefore)
      #expect(await h.opens().isEmpty)
      #expect(await h.seen().isEmpty)
    } cleanup: {
      h.navigator.onStateChange = nil
      h.navigator.cancel()
      if initialConnections > 0 { await verifyClosedOnce(h.service) }
    }
  }

  @Test(arguments: [false, true])
  func obsoleteRetryDoesNotConnectAfterPreviousServiceCloses(
    replace: Bool
  ) async throws {
    let h = Harness()
    let replacement = FakeService(epoch: h.destination.serviceEpoch)
    var retry: Task<Void, Never>?
    var replacementConnected = false
    try await RuntimeFixture.withCleanup {
      await h.service.setLocateError(.offline("Retry available"))
      await h.navigator.open(h.url)
      try #require(h.navigator.state == .unavailable(reason: "Retry available"))
      await h.service.setHoldClose()
      retry = Task { await h.navigator.retry() }
      try await RuntimeFixture.wait(
        "previous service close",
        timeout: .seconds(2)
      ) { await h.service.isHoldingClose }
      var destination = h.destination
      destination.occurrenceID = OccurrenceID()
      if replace {
        await replacement.set(
          h.location(.available, item: sampleItem(for: destination)),
          for: destination.occurrenceID
        )
        await h.connector.setNextService(replacement)
        await h.navigator.open(destination)
        replacementConnected = true
        #expect(
          h.navigator.state == .ready(h.preview(sampleItem(for: destination)))
        )
      } else {
        h.navigator.cancel()
      }
      let currentState = h.navigator.state
      await h.service.releaseClose()
      await retry?.value
      #expect(h.navigator.state == currentState)
      #expect(await h.connector.connectedHosts.count == (replace ? 2 : 1))
      #expect(
        await h.service.calls == [
          .epoch, .locate(h.destination.reference), .close,
        ]
      )
      #expect(
        await replacement.calls
          == (replace ? [.epoch, .locate(destination.reference)] : [])
      )
      #expect(await h.opens().isEmpty)
      #expect(await h.seen().isEmpty)
    } cleanup: {
      h.navigator.cancel()
      await h.service.releaseClose()
      await retry?.value
      if replacementConnected { await verifyClosedOnce(replacement) }
    }
  }

  private func verifyClosedOnce(_ service: FakeService) async {
    do {
      try await RuntimeFixture.wait("service close", timeout: .seconds(2)) {
        await service.calls.contains(.close)
      }
    } catch { Issue.record(error) }
    #expect(await service.calls.filter { $0 == .close } == [.close])
  }
}
