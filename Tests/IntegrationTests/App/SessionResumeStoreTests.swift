import Foundation
@testable import RoamingApp
import SessionCore
import Testing

struct SessionResumeStoreTests {
  private func owner(_ id: UUID, account: String) -> HostDataOwner {
    let host = HostProfile(
      id: id,
      nickname: "A",
      host: "a.local",
      username: "me"
    )
    return HostDataOwner(
      HostConnectionSelection(
        host: host,
        context: HostMutationContext(
          id: id,
          original: host,
          revision: nil,
          conflict: nil,
          scope: account,
          accountGeneration: 0
        ),
        identity: nil
      )
    )
  }

  @Test
  func concurrentOwnersOfTheSameHostKeepTheirChoices() throws {
    let suite = "resume-owned-concurrency-\(UUID().uuidString)"
    let first = try #require(UserDefaults(suiteName: suite))
    let second = try #require(UserDefaults(suiteName: suite))
    defer { first.removePersistentDomain(forName: suite) }
    let stores = [
      SessionResumeStore(defaults: first), SessionResumeStore(defaults: second),
    ]
    let host = UUID()
    let owners = (0 ..< 64).map { owner(host, account: "account-\($0)") }
    let sessions = owners.map { _ in SessionID.random() }
    DispatchQueue.concurrentPerform(iterations: owners.count) { index in
      stores[index % 2].set(sessions[index], for: owners[index])
    }
    for index in owners.indices {
      #expect(stores[0].sessionID(for: owners[index]) == sessions[index])
      #expect(stores[1].sessionID(for: owners[index]) == sessions[index])
    }
    let replacement = SessionID.random()
    DispatchQueue.concurrentPerform(iterations: owners.count) { index in
      stores[index % 2]
        .set(index.isMultiple(of: 2) ? nil : replacement, for: owners[index])
    }
    for index in owners.indices {
      #expect(
        stores[0].sessionID(for: owners[index])
          == (index.isMultiple(of: 2) ? nil : replacement)
      )
      #expect(
        stores[1].sessionID(for: owners[index])
          == (index.isMultiple(of: 2) ? nil : replacement)
      )
    }
  }

  @Test(arguments: ["not-a-session", 42] as [any Sendable])
  func malformedOwnedValuesDoNotFallBackToLegacy(value: any Sendable) throws {
    let suite = "resume-owned-malformed-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SessionResumeStore(defaults: defaults)
    let host = UUID()
    let owned = owner(host, account: "account-a")
    let old = SessionID.random()
    store.set(old, for: host)
    store.set(.random(), for: owned)
    let key = SessionResumeStore.key + ".owners.v1"
    let raw = try #require(defaults.dictionary(forKey: key))
    let name = try #require(raw.keys.first)
    defaults.set([name: value], forKey: key)
    #expect(store.sessionID(for: owned) == nil)
    #expect(store.sessionID(for: host) == old)
    let other = owner(host, account: "account-b")
    let choice = SessionID.random()
    store.set(choice, for: other)
    #expect(store.sessionID(for: other) == choice)
    #expect(store.sessionID(for: owned) == nil)
    #expect(defaults.dictionary(forKey: key)?[name] != nil)
  }

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
