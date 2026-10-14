import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOSSH
@testable import SSHClient
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HostTrustAtomicityTests {
  @Test
  func fileAliasesUseTheTargetSizeAndPreserveTheReadBound() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("host-trust-bound-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target.json")
    let alias = directory.appendingPathComponent("alias.json")
    let host = try #require(HostIdentity(host: "bounds.example", port: 22))
    let line = String(
      openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    )
    try await FileHostTrustStore(fileURL: target).setTrustedKey(line, for: host)
    var contents = try Data(contentsOf: target)
    contents.append(
      Data(
        repeating: 0x20,
        count: FileHostTrustStore.maxFileBytes - contents.count
      )
    )
    try contents.write(to: target)
    try FileManager.default.createSymbolicLink(
      at: alias,
      withDestinationURL: target
    )
    let store = FileHostTrustStore(fileURL: alias)
    #expect(try await store.trustedKey(for: host) == line)
    contents.append(0x20)
    try contents.write(to: target)
    await #expect(throws: FileHostTrustStore.StoreError.tooLarge) {
      _ = try await store.trustedKey(for: host)
    }
    await #expect(throws: FileHostTrustStore.StoreError.tooLarge) {
      _ = try await store.trustKeyIfAbsent(line, for: host)
    }
    #expect(try Data(contentsOf: target) == contents)
    try FileManager.default.removeItem(at: target)
    await #expect(throws: FileHostTrustStore.StoreError.corrupt) {
      _ = try await store.trustedKey(for: host)
    }
  }

  @Test(arguments: [false, true])
  func nonregularTrustFileFailsClosed(fifo: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("host-trust-nonregular-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = fifo ? directory.appendingPathComponent("fifo") : directory
    if fifo { try #require(mkfifo(file.path, 0o600) == 0) }
    let store = FileHostTrustStore(fileURL: file)
    let host = try #require(HostIdentity(host: "bounds.example", port: 22))
    await #expect(throws: FileHostTrustStore.StoreError.corrupt) {
      _ = try await store.trustedKey(for: host)
    }
  }

  @Test(arguments: [false, true])
  func builtInStoresChooseOneKeyAcrossConcurrentApprovals(
    file: Bool,
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("host-trust-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("known_hosts.json")
    let host = try #require(HostIdentity(host: "race.example", port: 22))
    let memory = InMemoryHostTrustStore()
    let lines = (0 ..< 32)
      .map { _ in
        String(
          openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        )
      }
    let results = try await withThrowingTaskGroup(of: String.self) { group in
      for line in lines {
        let store: any HostTrustStore =
          file ? FileHostTrustStore(fileURL: url) : memory
        group.addTask { try await store.trustKeyIfAbsent(line, for: host) }
      }
      var results: [String] = []
      for try await result in group { results.append(result) }
      return results
    }
    #expect(results.count == lines.count)
    #expect(Set(results).count == 1)
    let winner = try #require(results.first)
    #expect(lines.contains(winner))
    let store: any HostTrustStore =
      file ? FileHostTrustStore(fileURL: url) : memory
    #expect(try await store.trustedKey(for: host) == winner)
    #expect(try await store.trustKeyIfAbsent(winner, for: host) == winner)
    // Explicit replacement and removal remain deliberate operations.
    let replacement = try #require(lines.first { $0 != winner })
    try await store.setTrustedKey(replacement, for: host)
    #expect(try await store.trustKeyIfAbsent(winner, for: host) == replacement)
    try await store.removeTrustedKey(for: host)
    #expect(try await store.trustKeyIfAbsent(winner, for: host) == winner)
  }

  @Test
  func fileInstancesPreserveConcurrentUpdates() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("host-trust-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("known_hosts.json")
    let line = String(
      openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    )
    let hosts = (0 ..< 32)
      .map { HostIdentity(host: "host-\($0).example", port: 22, )! }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for host in hosts {
        group.addTask {
          try await FileHostTrustStore(fileURL: file)
            .setTrustedKey(line, for: host, )
        }
      }
      try await group.waitForAll()
    }
    let store = FileHostTrustStore(fileURL: file)
    for host in hosts { #expect(try await store.trustedKey(for: host) == line) }
  }

  @Test
  func existingFileStoreFailsClosedAfterCorruption() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("host-trust-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("known_hosts.json")
    let host = try #require(HostIdentity(host: "race.example", port: 22))
    let line = String(
      openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    )
    let store = FileHostTrustStore(fileURL: file)
    try await store.setTrustedKey(line, for: host)
    #expect(try await store.trustedKey(for: host) == line)
    let corrupt = Data("{invalid".utf8)
    try corrupt.write(to: file)
    await #expect(throws: FileHostTrustStore.StoreError.corrupt) {
      _ = try await store.trustedKey(for: host)
    }
    await #expect(throws: FileHostTrustStore.StoreError.corrupt) {
      _ = try await store.trustKeyIfAbsent(line, for: host)
    }
    #expect(try Data(contentsOf: file) == corrupt)
  }

  @Test
  func concurrentApprovalsCannotRememberDifferentKeysForOneHost() async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let host = try #require(HostIdentity(host: "race.example", port: 22))
    let store = SnapshotRaceStore()
    let barrier = ApprovalBarrier()
    let keys = [
      NIOSSHPrivateKey(ed25519Key: .init()).publicKey,
      NIOSSHPrivateKey(ed25519Key: .init()).publicKey,
    ]
    let verifiers = keys.map { _ in
      HostKeyVerifier(host: host, store: store, decider: barrier)
    }
    let promises = keys.map { _ in group.next().makePromise(of: Void.self) }
    for index in keys.indices {
      group.next()
        .execute {
          verifiers[index]
            .validateHostKey(
              hostKey: keys[index],
              validationCompletePromise: promises[index],
            )
        }
    }
    var successes = 0
    for promise in promises {
      do {
        try await promise.futureResult.get();
        successes += 1
      } catch {
        guard case SSHClientError.hostKeyChanged = error else {
          Issue.record("Unexpected trust error: \(error)")
          continue
        }
      }
    }
    #expect(successes == 1)
    #expect(await store.commits.count == 1)
    let remembered = await store.trustedKey(for: host)
    let accepted = verifiers.compactMap { $0.accepted.withLock { $0 } }
    #expect(accepted == [remembered].compactMap(\.self))
    try await group.shutdownGracefully()
  }

  @Test
  func fileInstancesObserveUpdatesAndPreserveOtherHosts() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("host-trust-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("known_hosts.json")
    let first = FileHostTrustStore(fileURL: file)
    let second = FileHostTrustStore(fileURL: file)
    let hosts = try [
      #require(HostIdentity(host: "first.example", port: 22)),
      #require(HostIdentity(host: "second.example", port: 22)),
    ]
    let line = String(
      openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    )
    #expect(try await first.trustedKey(for: hosts[0]) == nil)
    #expect(try await second.trustedKey(for: hosts[0]) == nil)
    try await first.setTrustedKey(line, for: hosts[0])
    #expect(try await second.trustedKey(for: hosts[0]) == line)
    try await second.setTrustedKey(line, for: hosts[1])
    let fresh = FileHostTrustStore(fileURL: file)
    #expect(try await fresh.trustedKey(for: hosts[0]) == line)
    #expect(try await fresh.trustedKey(for: hosts[1]) == line)
    try await second.removeTrustedKey(for: hosts[0])
    #expect(try await first.trustedKey(for: hosts[0]) == nil)
    #expect(try await first.trustedKey(for: hosts[1]) == line)
  }
}

/// Both unknown-key prompts resolve together. On the old verifier, both
/// subsequent reads capture nil before either separate write is allowed.
private actor SnapshotRaceStore: HostTrustStore {
  var keys: [HostIdentity: String] = [:]
  var reads = 0
  var heldRead: CheckedContinuation<Void, Never>?
  var commits: [String] = []
  var atomicCommitUsed = false

  func trustedKey(for host: HostIdentity) async -> String? {
    let snapshot = keys[host]
    if atomicCommitUsed { return snapshot }
    reads += 1
    if reads == 3 {
      await withCheckedContinuation { heldRead = $0 }
    } else if reads == 4 {
      heldRead?.resume()
      heldRead = nil
    }
    return snapshot
  }

  func setTrustedKey(_ line: String, for host: HostIdentity) {
    keys[host] = line
    commits.append(line)
  }

  func trustKeyIfAbsent(_ line: String, for host: HostIdentity) -> String {
    atomicCommitUsed = true
    if let existing = keys[host] { return existing }
    setTrustedKey(line, for: host)
    return line
  }

  func removeTrustedKey(for host: HostIdentity) { keys[host] = nil }
}

private actor ApprovalBarrier: HostTrustDecider {
  var waiting: CheckedContinuation<HostTrustDecision, Never>?
  func decide(_: HostTrustRequest) async -> HostTrustDecision {
    if let waiting {
      self.waiting = nil
      waiting.resume(returning: .trustAndRemember)
      return .trustAndRemember
    }
    return await withCheckedContinuation { waiting = $0 }
  }
}
