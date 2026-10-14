import Foundation
import SSHClient
import XCTest

/// Exercises the data-protection Keychain from a signed, app-hosted test
/// with a keychain-access-group entitlement
/// (Scripts/test-keychain-signed.sh), where unsigned SwiftPM runners skip.
final class KeychainRuntimeTests: XCTestCase {
  private enum FixtureFailure: Error { case body }

  func testConcurrentStoresCreateOneNamedIdentity() async throws {
    let service = "swiftty.runtime." + UUID().uuidString
    let store = KeychainEd25519KeyStore(service: service)
    let identities = try await withOwnedKeys(store, labels: ["shared"]) {
      try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0 ..< 32 {
          group.addTask {
            let store = KeychainEd25519KeyStore(service: service)
            return try await store.loadOrCreateKey(label: "shared").publicKey
              .rawRepresentation
          }
        }
        var publicKeys: Set<Data> = []
        for try await key in group { publicKeys.insert(key) }
        return publicKeys
      }
    }
    XCTAssertEqual(identities.count, 1)
  }

  func testEd25519KeysPersistInTheSignedKeychain() async throws {
    let store = KeychainEd25519KeyStore(
      service: "swiftty.runtime." + UUID().uuidString
    )
    try await withOwnedKeys(store, labels: ["probe", "fresh"]) {
      let key = SSHEd25519Key.generate()
      try await store.storeKey(key, label: "probe")
      let loaded = try await store.loadKey(label: "probe")
      XCTAssertEqual(loaded?.rawRepresentation, key.rawRepresentation)
      // A second label is independent; replacing a label overwrites it.
      let other = SSHEd25519Key.generate()
      try await store.storeKey(other, label: "probe")
      let replaced = try await store.loadKey(label: "probe")
      XCTAssertEqual(replaced?.rawRepresentation, other.rawRepresentation)
      let created = try await store.loadOrCreateKey(label: "fresh")
      let again = try await store.loadOrCreateKey(label: "fresh")
      XCTAssertEqual(created.rawRepresentation, again.rawRepresentation)
    }
    let gone = try await store.loadKey(label: "probe")
    XCTAssertNil(gone)
    let freshGone = try await store.loadKey(label: "fresh")
    XCTAssertNil(freshGone)
  }

  func testFailedPersistenceStillDeletesBothOwnedLabels() async throws {
    try await verifyFailureCleanup(labels: ["probe", "fresh"]) { store in
      try await store.storeKey(SSHEd25519Key.generate(), label: "probe")
      try await store.storeKey(SSHEd25519Key.generate(), label: "fresh")
      throw FixtureFailure.body
    }
  }

  func testFailedGroupSettlesItsCancelledWriterBeforeDeletion() async throws {
    try await verifyFailureCleanup(labels: ["shared"]) { store in
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          _ = try await store.loadOrCreateKey(label: "shared")
          throw FixtureFailure.body
        }
        group.addTask {
          // Ignore cancellation here to exercise a writer that must settle.
          try? await Task.sleep(for: .milliseconds(20))
          _ = try await store.loadOrCreateKey(label: "shared")
        }
        for try await _ in group {}
      }
    }
  }

  private func withOwnedKeys<T>(
    _ store: KeychainEd25519KeyStore,
    labels: [String],
    _ work: () async throws -> T
  ) async throws -> T {
    try await KeychainRuntimeCleanup.withCleanup(
      labels: labels,
      work: work,
      delete: { try await store.deleteKey(label: $0) },
      report: { label, error in
        XCTFail("Failed to clean owned Keychain label \(label): \(error)")
      }
    )
  }

  private func verifyFailureCleanup(
    labels: [String],
    work: (KeychainEd25519KeyStore) async throws -> Void
  ) async throws {
    let store = KeychainEd25519KeyStore(
      service: "swiftty.runtime." + UUID().uuidString
    )
    // Keep a separate awaited fallback so a failing baseline probe cannot
    // leave its intentionally created labels in the simulator's Keychain.
    try await RuntimeFixture.withCleanup {
      do {
        try await withOwnedKeys(store, labels: labels) { try await work(store) }
        XCTFail("Expected fixture body failure")
      } catch { XCTAssertTrue(error is FixtureFailure) }
      for label in labels {
        let key = try await store.loadKey(label: label)
        XCTAssertNil(key, "Owned label remains after a failed body: \(label)")
      }
    } cleanup: {
      for label in labels {
        do { try await store.deleteKey(label: label) } catch {
          XCTFail("Fallback cleanup failed for owned label \(label): \(error)")
        }
      }
    }
  }
}
