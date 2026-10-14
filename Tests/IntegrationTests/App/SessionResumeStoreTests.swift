import Foundation
@testable import RoamingApp
import SessionCore
import Testing

struct SessionResumeStoreTests {
  @Test
  func malformedEntriesDoNotEraseValidSessions() throws {
    let suite = "resume-malformed-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SessionResumeStore(defaults: defaults)
    let host = UUID()
    let other = UUID()
    let session = SessionID.random()
    let invalidTypeHost = UUID()
    let invalidSessionHost = UUID()
    let raw: [String: Any] = [
      host.uuidString: session.hex, invalidTypeHost.uuidString: 42,
      invalidSessionHost.uuidString: "invalid-session",
      "invalid-host": session.hex,
    ]
    defaults.set(raw, forKey: SessionResumeStore.key)

    #expect(store.all() == [host: session])
    store.set(session, for: other)
    #expect(store.all() == [host: session, other: session])
    store.set(nil, for: other)
    #expect(store.all() == [host: session])
  }

  @Test
  func concurrentStoresKeepEveryHost() throws {
    let suite = "resume-concurrency-\(UUID().uuidString)"
    let first = try #require(UserDefaults(suiteName: suite))
    let second = try #require(UserDefaults(suiteName: suite))
    defer { first.removePersistentDomain(forName: suite) }
    let stores = [
      SessionResumeStore(defaults: first), SessionResumeStore(defaults: second),
    ]
    let hosts = (0 ..< 64).map { _ in UUID() }
    let sessions = hosts.map { _ in SessionID.random() }

    DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
      stores[index % stores.count].set(sessions[index], for: hosts[index])
    }

    let result = stores[0].all()
    #expect(result.count == hosts.count)
    for index in hosts.indices {
      #expect(result[hosts[index]] == sessions[index])
    }
    #expect(stores[1].all() == result)
  }

  @Test
  func concurrentRemovalsAndUpdatesKeepOtherHosts() throws {
    let suite = "resume-removal-\(UUID().uuidString)"
    let first = try #require(UserDefaults(suiteName: suite))
    let second = try #require(UserDefaults(suiteName: suite))
    defer { first.removePersistentDomain(forName: suite) }
    let stores = [
      SessionResumeStore(defaults: first), SessionResumeStore(defaults: second),
    ]
    let hosts = (0 ..< 64).map { _ in UUID() }
    let initial = SessionID.random()
    let updated = SessionID.random()
    for host in hosts { stores[0].set(initial, for: host) }

    DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
      stores[index % stores.count]
        .set(index.isMultiple(of: 2) ? nil : updated, for: hosts[index], )
    }

    let result = stores[1].all()
    #expect(result.count == hosts.count / 2)
    for index in hosts.indices {
      #expect(result[hosts[index]] == (index.isMultiple(of: 2) ? nil : updated))
    }
  }
}
