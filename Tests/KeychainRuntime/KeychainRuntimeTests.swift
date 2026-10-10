import Foundation
import SSHClient
import XCTest

/// Exercises the data-protection Keychain from a signed, app-hosted test
/// with a keychain-access-group entitlement
/// (Scripts/test-keychain-signed.sh), where unsigned SwiftPM runners skip.
final class KeychainRuntimeTests: XCTestCase {
  func testEd25519KeysPersistInTheSignedKeychain() async throws {
    let store = KeychainEd25519KeyStore(service: "swiftty.runtime." + UUID().uuidString)
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
    try await store.deleteKey(label: "probe")
    try await store.deleteKey(label: "fresh")
    let gone = try await store.loadKey(label: "probe")
    XCTAssertNil(gone)
  }
}
