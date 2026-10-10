import Foundation
import MuxNavigation
import SwiftMuxProtocol
import Testing

/// Scriptable service: records every call so tests can prove what was
/// (and was not) sent.
actor FakeService: AttentionService {
  enum Call: Equatable {
    case epoch, locate(AttentionReference), lease(WorkspaceID)
    case open(PaneTarget, takeover: UInt64?), markSeen(AttentionReference), close
  }

  var epoch: ServerInstanceID
  var locations: [OccurrenceID: AttentionLocation] = [:]
  var locateError: AttentionServiceError?
  var lease = LeaseState(generation: 4, holder: nil)
  /// Results for successive `open` calls; empty means success.
  var openResults: [AttentionServiceError?] = []
  /// Suspends `locate` until released (delayed results).
  var locateGate: CheckedContinuation<Void, Never>?
  var holdLocate = false
  private(set) var calls: [Call] = []

  init(epoch: ServerInstanceID) { self.epoch = epoch }

  func set(_ location: AttentionLocation, for occurrence: OccurrenceID) {
    locations[occurrence] = location
  }
  func setLocateError(_ e: AttentionServiceError?) { locateError = e }
  func setOpenResults(_ r: [AttentionServiceError?]) { openResults = r }
  func setLease(_ l: LeaseState) { lease = l }
  func setHoldLocate(_ h: Bool) { holdLocate = h }
  func release() {
    locateGate?.resume()
    locateGate = nil
  }
  var isHolding: Bool { locateGate != nil }

  func serviceEpoch() async throws(AttentionServiceError) -> ServerInstanceID {
    calls.append(.epoch)
    return epoch
  }

  func locate(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) -> AttentionLocation {
    calls.append(.locate(reference))
    if holdLocate {
      await withCheckedContinuation { locateGate = $0 }
    }
    if let locateError { throw locateError }
    return locations[reference.occurrence] ?? AttentionLocation(availability: .missing)
  }

  func leaseState(of workspace: WorkspaceID) async throws(AttentionServiceError) -> LeaseState {
    calls.append(.lease(workspace))
    return lease
  }

  func open(_ target: PaneTarget, takeover: UInt64?) async throws(AttentionServiceError) {
    calls.append(.open(target, takeover: takeover))
    if !openResults.isEmpty, let error = openResults.removeFirst() { throw error }
  }

  func markSeen(_ reference: AttentionReference) async throws(AttentionServiceError) {
    calls.append(.markSeen(reference))
  }

  func close() async { calls.append(.close) }
}

final class FakeConnector: AttentionServiceConnector, @unchecked Sendable {
  let service: FakeService
  var error: AttentionServiceError?
  private(set) var connectedHosts: [UUID] = []

  init(service: FakeService) { self.service = service }

  func connect(to host: NavigationHost) async throws(AttentionServiceError) -> any AttentionService {
    connectedHosts.append(host.id)
    if let error { throw error }
    return service
  }
}

@MainActor
struct Harness {
  let destination: AttentionDestination
  let host: NavigationHost
  let service: FakeService
  let connector: FakeConnector
  let navigator: AttentionNavigator

  init(hosts extra: [NavigationHost] = [], includeLinkedHost: Bool = true) {
    var d = sampleDestination()
    let host = NavigationHost(id: d.localHostProfileID, name: "Office Mac")
    d.localHostProfileID = host.id
    destination = d
    self.host = host
    service = FakeService(epoch: d.serviceEpoch)
    connector = FakeConnector(service: service)
    navigator = AttentionNavigator(
      configuration: AttentionLinkConfiguration(),
      hosts: StaticHostDirectory((includeLinkedHost ? [host] : []) + extra),
      connector: connector
    )
  }

  var url: URL { AttentionLink.customURL(for: destination) }

  var target: PaneTarget {
    PaneTarget(workspace: destination.workspaceID, tab: destination.tabID, pane: destination.paneID)
  }

  func location(
    _ availability: AttentionLocation.Availability,
    item: AttentionItem? = nil,
    leaseHeldElsewhere: Bool = false
  ) -> AttentionLocation {
    AttentionLocation(
      availability: availability,
      item: item ?? sampleItem(for: destination),
      workspace: destination.workspaceID,
      tab: destination.tabID,
      pane: destination.paneID,
      leaseHeldElsewhere: leaseHeldElsewhere
    )
  }

  func preview(_ item: AttentionItem? = nil, lease: Bool = false) -> AttentionPreview {
    AttentionPreview(item: item ?? sampleItem(for: destination), target: target, leaseHeldElsewhere: lease)
  }

  func seen() async -> [AttentionReference] {
    await service.calls.compactMap {
      if case let .markSeen(r) = $0 { r } else { nil }
    }
  }

  func opens() async -> [FakeService.Call] {
    await service.calls.filter { if case .open = $0 { true } else { false } }
  }
}

@Suite("Attention navigator")
@MainActor
struct NavigatorTests {
  @Test func exactOccurrenceOpensAndMarksSeen() async {
    let h = Harness()
    await h.service.set(h.location(.available), for: h.destination.occurrenceID)
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .ready(h.preview()))
    // Reading metadata takes no lease and acknowledges nothing.
    #expect(await h.opens().isEmpty)
    #expect(await h.seen().isEmpty)
    await h.navigator.openInPane()
    #expect(h.navigator.state == .opened(h.target))
    #expect(await h.opens() == [.open(h.target, takeover: nil)])
    #expect(await h.seen() == [h.destination.reference])
    // Viewing again does not acknowledge twice.
    await h.navigator.didView()
    #expect(await h.seen().count == 1)
  }

  @Test func rejectedLinkContactsNothing() async {
    let h = Harness()
    await h.navigator.open(URL(string: "swiftty://attention/open?ref=x&host=evil.example")!)
    #expect(h.navigator.state == .rejected(.unexpectedQuery))
    #expect(h.connector.connectedHosts.isEmpty)
    #expect(await h.service.calls.isEmpty)
  }

  @Test func unknownHostRequiresExplicitSelection() async {
    let other = NavigationHost(id: UUID(), name: "Laptop")
    let h = Harness(hosts: [other], includeLinkedHost: false)
    await h.service.set(h.location(.available), for: h.destination.occurrenceID)
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .needsHostSelection([other]))
    #expect(h.connector.connectedHosts.isEmpty)
    // A host that is not configured is ignored.
    await h.navigator.selectHost(NavigationHost(id: UUID(), name: "Injected"))
    #expect(h.connector.connectedHosts.isEmpty)
    await h.navigator.selectHost(other)
    #expect(h.connector.connectedHosts == [other.id])
    #expect(h.navigator.state == .ready(h.preview()))
  }

  @Test func staleOccurrenceIsShownNotRedirected() async {
    let h = Harness()
    let item = sampleItem(for: h.destination, resolution: .superseded)
    await h.service.set(h.location(.stale, item: item), for: h.destination.occurrenceID)
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .stale(h.preview(item)))
    // No Open in pane from a stale item.
    await h.navigator.openInPane()
    #expect(await h.opens().isEmpty)
    await h.navigator.didView()
    #expect(await h.seen() == [h.destination.reference])
  }

  @Test func resolvedButAvailableIsStale() async {
    let h = Harness()
    let item = sampleItem(for: h.destination, resolution: .resolved)
    await h.service.set(h.location(.available, item: item), for: h.destination.occurrenceID)
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .stale(h.preview(item)))
  }

  @Test func differentOccurrenceIsNeverSubstituted() async {
    let h = Harness()
    // A misbehaving service answers with a newer occurrence of the same
    // source (same label): it must not be shown or acknowledged.
    let newer = sampleItem(for: h.destination, occurrence: OccurrenceID())
    await h.service.set(h.location(.available, item: newer), for: h.destination.occurrenceID)
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .missing(.notFound))
    await h.navigator.didView()
    await h.navigator.openInPane()
    #expect(await h.seen().isEmpty)
    #expect(await h.opens().isEmpty)
  }

  @Test func otherPaneIsNeverSubstituted() async {
    let h = Harness()
    var location = h.location(.available)
    location.pane = PaneID()
    await h.service.set(location, for: h.destination.occurrenceID)
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .missing(.notFound))
  }

  @Test func serviceRestartIsMissingBeforeAnyLookup() async {
    let h = Harness()
    await h.service.set(h.location(.available), for: h.destination.occurrenceID)
    await h.service.setEpochForTest(ServerInstanceID())
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .missing(.serviceRestarted))
    // Nothing was looked up or disclosed under the new epoch.
    #expect(await h.service.calls == [.epoch])
  }

  @Test func missingOccurrence() async {
    let h = Harness()
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .missing(.notFound))
    await h.service.setLocateError(.notFound)
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .missing(.notFound))
  }

  @Test func leaseElsewhereRequiresConfirmedTakeover() async {
    let h = Harness()
    let holder = LeaseHolder(transport: .remote, frontend: .native, since: Date(timeIntervalSince1970: 5))
    await h.service.set(h.location(.available, leaseHeldElsewhere: true), for: h.destination.occurrenceID)
    await h.service.setLease(LeaseState(generation: 7, holder: holder))
    await h.navigator.open(h.url)
    // Metadata stays viewable while another device controls the pane.
    #expect(h.navigator.state == .ready(h.preview(lease: true)))
    await h.navigator.openInPane()
    let offer = TakeoverOffer(preview: h.preview(lease: true), expectedLease: 7, holder: holder)
    #expect(h.navigator.state == .confirmTakeover(offer))
    #expect(await h.opens().isEmpty)
    h.navigator.declineTakeover()
    #expect(h.navigator.state == .ready(h.preview(lease: true)))
    #expect(await h.opens().isEmpty)
    await h.navigator.openInPane()
    await h.navigator.confirmTakeover()
    #expect(h.navigator.state == .opened(h.target))
    #expect(await h.opens() == [.open(h.target, takeover: 7)])
  }

  @Test func leaseTakenWhileOpeningOffersTakeover() async {
    let h = Harness()
    await h.service.set(h.location(.available), for: h.destination.occurrenceID)
    await h.service.setOpenResults([.leaseHeld, .leaseChanged])
    await h.navigator.open(h.url)
    await h.navigator.openInPane()
    guard case let .confirmTakeover(offer) = h.navigator.state else {
      Issue.record("expected takeover offer, got \(h.navigator.state)")
      return
    }
    #expect(offer.expectedLease == 4 && !offer.controllerChanged)
    // The controller changed again before the user confirmed: re-offer
    // with the new generation instead of displacing the newer holder.
    await h.service.setLease(LeaseState(generation: 5, holder: nil))
    await h.navigator.confirmTakeover()
    guard case let .confirmTakeover(again) = h.navigator.state else {
      Issue.record("expected a fresh offer, got \(h.navigator.state)")
      return
    }
    #expect(again.expectedLease == 5 && again.controllerChanged)
    await h.navigator.confirmTakeover()
    #expect(h.navigator.state == .opened(h.target))
    #expect(
      await h.opens() == [
        .open(h.target, takeover: nil), .open(h.target, takeover: 4),
        .open(h.target, takeover: 5),
      ]
    )
  }

  @Test func offlineIsRecoverable() async {
    let h = Harness()
    h.connector.error = .offline("no route")
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .unavailable(reason: "no route"))
    h.connector.error = nil
    await h.service.set(h.location(.available), for: h.destination.occurrenceID)
    await h.navigator.retry()
    #expect(h.navigator.state == .ready(h.preview()))
  }

  @Test func unsupportedTransportIsUnavailable() async {
    let h = Harness()
    let navigator = AttentionNavigator(
      configuration: AttentionLinkConfiguration(),
      hosts: StaticHostDirectory([h.host]),
      connector: UnavailableAttentionConnector(reason: "attention not yet available over roaming")
    )
    await navigator.open(h.url)
    #expect(navigator.state == .unavailable(reason: "attention not yet available over roaming"))
  }

  @Test func paneExitedOpensRetainedResult() async {
    let h = Harness()
    let item = sampleItem(for: h.destination, resolution: .paneExited)
    await h.service.set(h.location(.paneExited, item: item), for: h.destination.occurrenceID)
    await h.navigator.open(h.url)
    #expect(h.navigator.state == .paneExited(h.preview(item)))
    await h.navigator.openInPane()
    #expect(h.navigator.state == .opened(h.target))
    #expect(await h.seen() == [h.destination.reference])
  }

  @Test func paneExitingDuringOpen() async {
    let h = Harness()
    await h.service.set(h.location(.available), for: h.destination.occurrenceID)
    await h.service.setOpenResults([.paneExited])
    await h.navigator.open(h.url)
    await h.navigator.openInPane()
    #expect(h.navigator.state == .paneExited(h.preview()))
    #expect(await h.seen().isEmpty)
  }

  /// blocked → working → blocked gives occurrences O1 and O2. A delayed
  /// notification for O1 must acknowledge O1 only, never O2.
  @Test func delayedNotificationDoesNotAcknowledgeNewer() async {
    let h = Harness()
    let o1 = h.destination
    var o2 = o1
    o2.occurrenceID = OccurrenceID()
    let o1Item = sampleItem(for: o1, resolution: .superseded)
    await h.service.set(h.location(.stale, item: o1Item), for: o1.occurrenceID)
    await h.service.set(h.location(.available, item: sampleItem(for: o2)), for: o2.occurrenceID)
    await h.navigator.open(AttentionLink.customURL(for: o1))
    #expect(h.navigator.state == .stale(h.preview(o1Item)))
    await h.navigator.didView()
    #expect(await h.seen() == [o1.reference])
  }

  /// A slow lookup for an older link must not overwrite or acknowledge
  /// the navigation that replaced it.
  @Test func newerNavigationCancelsDelayedResult() async {
    let h = Harness()
    let o1 = h.destination
    var o2 = o1
    o2.occurrenceID = OccurrenceID()
    await h.service.set(h.location(.available), for: o1.occurrenceID)
    await h.service.set(h.location(.available, item: sampleItem(for: o2)), for: o2.occurrenceID)
    await h.service.setHoldLocate(true)
    let first = Task { await h.navigator.open(AttentionLink.customURL(for: o1)) }
    while !(await h.service.isHolding) { await Task.yield() }
    await h.service.setHoldLocate(false)
    await h.navigator.open(AttentionLink.customURL(for: o2))
    let o2Preview = h.preview(sampleItem(for: o2))
    #expect(h.navigator.state == .ready(o2Preview))
    await h.service.release()
    await first.value
    // The late O1 result was dropped.
    #expect(h.navigator.state == .ready(o2Preview))
    await h.navigator.didView()
    #expect(await h.seen() == [o2.reference])
  }

  @Test func cancelDropsEverything() async {
    let h = Harness()
    await h.service.set(h.location(.available), for: h.destination.occurrenceID)
    await h.navigator.open(h.url)
    h.navigator.cancel()
    #expect(h.navigator.state == .idle)
    await h.navigator.didView()
    await h.navigator.openInPane()
    #expect(await h.seen().isEmpty)
    #expect(await h.opens().isEmpty)
  }
}

extension FakeService {
  func setEpochForTest(_ e: ServerInstanceID) { epoch = e }
}
