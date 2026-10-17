import Foundation
import HostConnection
import Synchronization
import Testing

@testable import RoamingApp

/// A resolver whose answers the test releases, one per request.
private actor HeldResolver: ServiceResolving {
  private var waiting:
    [(
      BrowsedService,
      CheckedContinuation<Result<ResolvedEndpoint, ResolveError>, Never>
    )] = []
  private(set) var requests: [String] = []

  nonisolated func resolve(
    _ service: BrowsedService
  ) async throws(ResolveError) -> ResolvedEndpoint {
    let result = await hold(service)
    return try result.get()
  }

  private func hold(
    _ service: BrowsedService
  ) async -> Result<ResolvedEndpoint, ResolveError> {
    requests.append(service.name)
    return await withCheckedContinuation { waiting.append((service, $0)) }
  }

  var pending: Int { waiting.count }

  func answer(
    _ name: String,
    with result: Result<ResolvedEndpoint, ResolveError>
  ) {
    guard let index = waiting.firstIndex(where: { $0.0.name == name }) else {
      return
    }
    waiting.remove(at: index).1.resume(returning: result)
  }
}

/// Bonjour results are validated, bounded and never act on their own
/// (spec.connection-setup.md T5).
extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct NearbyDiscoveryTests {
    func service(
      _ name: String,
      txt: [String: String]? = HostDiscovery.advertisedTXT,
      bytes: Int = 24,
      interface: UInt32 = 4,
      type: String = "_swiftty._tcp.",
      domain: String = "local."
    ) -> BrowsedService {
      BrowsedService(
        name: name,
        type: type,
        domain: domain,
        interfaceIndex: interface,
        txt: txt,
        txtBytes: bytes
      )
    }

    @Test
    func malformedAndForeignRecordsAreDropped() {
      let candidates = NearbyCandidateList.make([
        service("Good Mac"), service("No TXT", txt: nil),
        service("Big TXT", bytes: 513),
        service("Other product", txt: ["txtvers": "1", "product": "other"]),
        service("Future", txt: ["txtvers": "2", "product": "swiftty"]),
        service("Wrong type", type: "_ssh._tcp."),
        service("Wide area", domain: "example.com."), service("\u{0}\u{1}"),
        service(String(repeating: "x", count: 64)),
      ])
      #expect(candidates.map(\.displayName) == ["Good Mac"])
    }

    @Test
    func namesAreSanitizedAndCollisionsGroupedForDisplayOnly() {
      let candidates = NearbyCandidateList.make([
        service("Chris\u{202E}'s\nMac", interface: 4),
        service("Chris\u{202E}'s\nMac", interface: 9),
        service("Chris's Mac", interface: 4),
      ])
      // Distinct raw names stay distinct even when their display matches.
      #expect(candidates.count == 2)
      #expect(candidates.allSatisfy { $0.displayName == "Chris's Mac" })
      let grouped = candidates.first { $0.services.count == 2 }
      #expect(grouped?.services.map(\.interfaceIndex) == [4, 9])
    }

    @Test
    func candidateCountIsBounded() {
      let many = (0 ..< 400).map { service("Mac \($0)") }
      #expect(
        NearbyCandidateList.make(many).count == HostDiscovery.maxCandidates
      )
    }

    @Test
    func browsingResultsNeverStartResolutionOrConnections() async throws {
      let resolver = HeldResolver()
      let browser = NearbyMacBrowser(resolver: resolver)
      browser.update([service("A"), service("B")])
      try await Task.sleep(for: .milliseconds(50))
      #expect(await resolver.requests.isEmpty)
      #expect(browser.resolving == nil)
      #expect(browser.candidates.count == 2)
    }

    @Test
    func supersededAndLateResolutionsAreIgnored() async throws {
      let resolver = HeldResolver()
      let browser = NearbyMacBrowser(resolver: resolver)
      browser.update([service("A"), service("B")])
      let selected = Mutex<[HostCandidate]>([])
      let record: @MainActor @Sendable (HostCandidate) -> Void = { candidate in
        selected.withLock { $0.append(candidate) }
      }
      let a = try #require(browser.candidates.first { $0.id == "A" })
      let b = try #require(browser.candidates.first { $0.id == "B" })
      browser.choose(a, then: record)
      try await waitFor { await resolver.pending == 1 }
      browser.choose(b, then: record)
      try await waitFor { await resolver.pending == 2 }
      #expect(browser.resolving == "B")
      // A's late answer arrives after it was superseded.
      await resolver.answer(
        "A",
        with: .success(.init(host: "a.local", port: 22))
      )
      try await Task.sleep(for: .milliseconds(50))
      #expect(selected.withLock { $0 }.isEmpty)
      await resolver.answer(
        "B",
        with: .success(.init(host: "b.local", port: 2222))
      )
      try await waitFor { selected.withLock { $0.count } == 1 }
      let chosen = try #require(selected.withLock { $0.first })
      #expect(chosen.host == "b.local")
      #expect(chosen.port == 2222)
      #expect(chosen.source == .nearby)
      #expect(chosen.username.isEmpty)
      #expect(chosen.expectedHostKeys == nil)
      #expect(browser.resolving == nil)
    }

    @Test
    func stoppingCancelsResolutionAndDropsItsAnswer() async throws {
      let resolver = HeldResolver()
      let browser = NearbyMacBrowser(resolver: resolver)
      browser.update([service("A")])
      let selected = Mutex(0)
      browser.choose(try #require(browser.candidates.first)) { _ in
        selected.withLock { $0 += 1 }
      }
      try await waitFor { await resolver.pending == 1 }
      browser.stop()
      await resolver.answer(
        "A",
        with: .success(.init(host: "a.local", port: 22))
      )
      try await Task.sleep(for: .milliseconds(50))
      #expect(selected.withLock { $0 } == 0)
      #expect(browser.state == .idle)
    }

    @Test
    func vanishedRecordDropsItsResolution() async throws {
      let resolver = HeldResolver()
      let browser = NearbyMacBrowser(resolver: resolver)
      browser.update([service("A")])
      let selected = Mutex(0)
      browser.choose(try #require(browser.candidates.first)) { _ in
        selected.withLock { $0 += 1 }
      }
      try await waitFor { await resolver.pending == 1 }
      browser.update([])
      #expect(browser.resolving == nil)
      await resolver.answer(
        "A",
        with: .success(.init(host: "a.local", port: 22))
      )
      try await Task.sleep(for: .milliseconds(50))
      #expect(selected.withLock { $0 } == 0)
    }

    @Test
    func resolutionFailuresAreDistinguished() async throws {
      for (failure, denied) in [
        (ResolveError.policyDenied, true), (.timedOut, false),
        (.unsupported, false), (.failed(-65537), false),
      ] {
        let resolver = HeldResolver()
        let browser = NearbyMacBrowser(resolver: resolver)
        browser.update([service("A")])
        browser.choose(try #require(browser.candidates.first)) { _ in }
        try await waitFor { await resolver.pending == 1 }
        await resolver.answer("A", with: .failure(failure))
        try await waitFor { browser.resolving == nil }
        #expect((browser.state == .denied) == denied)
        #expect((browser.resolveError != nil) == !denied)
      }
    }

    @Test
    func policyDenialIsRecognizedOnlyFromItsCode() {
      #expect(NearbyMacBrowser.isPolicyDenial(.dns(-65570)))
      #expect(!NearbyMacBrowser.isPolicyDenial(.dns(-65537)))
      #expect(!NearbyMacBrowser.isPolicyDenial(.posix(.ETIMEDOUT)))
    }

    func waitFor(_ condition: () async -> Bool) async throws {
      let deadline = ContinuousClock.now + .seconds(5)
      while !(await condition()) {
        guard ContinuousClock.now < deadline else {
          Issue.record("condition not reached")
          return
        }
        try await Task.sleep(for: .milliseconds(5))
      }
    }
  }

  /// Pasted or scanned codes become temporary candidates only (T6, T8).
  @MainActor
  struct ConnectionCodeTests {
    @Test
    func decodedCodeIsATemporaryCandidateWithPins() throws {
      let print = "SHA256:" + String(repeating: "A", count: 43)
      let descriptor = HostConnectionDescriptor(
        name: "Studio",
        host: "studio.local",
        port: 2222,
        username: "me",
        hostKeys: [.init(algorithm: "ssh-ed25519", sha256: print)]
      )
      let decoded = try HostConnectionDescriptor.decode(
        descriptor.encodedString()
      )
      let candidate = HostCandidate(descriptor: decoded)
      #expect(candidate.source == .code)
      #expect(candidate.host == "studio.local")
      #expect(candidate.port == 2222)
      #expect(candidate.username == "me")
      #expect(candidate.expectedHostKeys == [print])
      #expect(candidate.suggestedNickname == "Studio")
      let app = RoamingAppModel(
        store: ConnectionStore(
          fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("hosts.json")
        )
      )
      #expect(app.hosts.isEmpty)
    }

    @Test
    func profileStoreHasNoPlaceForPinsOrSecrets() throws {
      let host = HostProfile(
        nickname: "Studio",
        host: "studio.local",
        username: "me"
      )
      let text = try String(decoding: JSONEncoder().encode(host), as: UTF8.self)
      // `password` appears only as the auth method's name, never a value.
      for field in ["hostKeys", "sha256", "SHA256:", "token", "secret"] {
        #expect(!text.contains(field))
      }
    }
  }
}
