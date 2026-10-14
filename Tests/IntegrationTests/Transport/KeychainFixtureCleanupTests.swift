import Foundation
import SSHClient
import Synchronization
import TestSupport
import Testing

struct KeychainFixtureCleanupTests {
  enum Failure: Error, Equatable {
    case body
    case cleanup(String)
  }

  @Test
  func successfulBodyReturnsItsValueAfterAllLabelsAreDeleted() async throws {
    let store = InMemoryEd25519KeyStore()
    let deletions = Mutex<[String]>([])
    let errors = Mutex<[String]>([])
    let value = try await KeychainRuntimeCleanup.withCleanup(
      labels: ["probe", "fresh"],
      work: {
        await store.storeKey(SSHEd25519Key.generate(), label: "probe")
        return 42
      },
      delete: { label in
        deletions.withLock { $0.append(label) }
        await store.deleteKey(label: label)
      },
      report: { label, _ in errors.withLock { $0.append(label) } }
    )
    #expect(value == 42)
    #expect(deletions.withLock { $0 } == ["probe", "fresh"])
    #expect(errors.withLock { $0.isEmpty })
    #expect(try await store.loadKey(label: "probe") == nil)
  }

  @Test
  func failedBodyRetiresAlreadyStoredAndNotYetStoredLabels() async throws {
    let store = InMemoryEd25519KeyStore()
    let deletions = Mutex<[String]>([])
    await #expect(throws: Failure.body) {
      try await KeychainRuntimeCleanup.withCleanup(
        labels: ["probe", "fresh"],
        work: {
          await store.storeKey(SSHEd25519Key.generate(), label: "probe")
          throw Failure.body
        },
        delete: { label in
          deletions.withLock { $0.append(label) }
          await store.deleteKey(label: label)
        },
        report: { _, error in Issue.record("Unexpected cleanup error: \(error)")
        }
      )
    }
    #expect(deletions.withLock { $0 } == ["probe", "fresh"])
    #expect(try await store.loadKey(label: "probe") == nil)
  }

  @Test(arguments: [false, true], [[], ["probe"], ["probe", "fresh"]])
  func deletionFailuresAreReportedWithoutReplacingTheBodyOrSkippingLabels(
    bodyFails: Bool,
    failures: [String]
  ) async throws {
    let attempted = Mutex<[String]>([])
    let reported = Mutex<[String]>([])
    do {
      let value = try await KeychainRuntimeCleanup.withCleanup(
        labels: ["probe", "fresh"],
        work: {
          if bodyFails { throw Failure.body }
          return 42
        },
        delete: { label in
          attempted.withLock { $0.append(label) }
          if failures.contains(label) { throw Failure.cleanup(label) }
        },
        report: { label, error in
          #expect(error as? Failure == .cleanup(label))
          reported.withLock { $0.append(label) }
        }
      )
      #expect(!bodyFails && value == 42)
    } catch { #expect(bodyFails && error as? Failure == .body) }
    #expect(attempted.withLock { $0 } == ["probe", "fresh"])
    #expect(reported.withLock { $0 } == failures)
  }

  @Test
  func throwingGroupSettlesItsCancelledWriterBeforeCleanup() async throws {
    let store = InMemoryEd25519KeyStore()
    let writers = Mutex(0)
    let deletedAfterSettlement = Mutex(false)
    await #expect(throws: Failure.body) {
      try await KeychainRuntimeCleanup.withCleanup(
        labels: ["shared"],
        work: {
          try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
              await store.storeKey(SSHEd25519Key.generate(), label: "shared")
              writers.withLock { $0 += 1 }
              throw Failure.body
            }
            group.addTask {
              // This writer deliberately finishes even after group cancellation.
              try? await Task.sleep(for: .milliseconds(20))
              await store.storeKey(SSHEd25519Key.generate(), label: "shared")
              writers.withLock { $0 += 1 }
            }
            for try await _ in group {}
          }
        },
        delete: { label in
          deletedAfterSettlement.withLock { $0 = writers.withLock { $0 == 2 } }
          await store.deleteKey(label: label)
        },
        report: { _, error in Issue.record("Unexpected cleanup error: \(error)")
        }
      )
    }
    #expect(deletedAfterSettlement.withLock { $0 })
    #expect(writers.withLock { $0 } == 2)
    #expect(try await store.loadKey(label: "shared") == nil)
  }

  @Test
  func cancellationAfterWritingStillDeletesTheOwnedLabel() async throws {
    let store = InMemoryEd25519KeyStore()
    let wrote = Mutex(false)
    let task = Task {
      try await KeychainRuntimeCleanup.withCleanup(
        labels: ["probe"],
        work: {
          await store.storeKey(SSHEd25519Key.generate(), label: "probe")
          wrote.withLock { $0 = true }
          try await Task.sleep(for: .seconds(30))
        },
        delete: { await store.deleteKey(label: $0) },
        report: { _, error in Issue.record("Unexpected cleanup error: \(error)")
        }
      )
    }
    defer { task.cancel() }
    try await RuntimeFixture.withCleanup {
      try await RuntimeFixture.wait("fixture write", timeout: .seconds(1)) {
        wrote.withLock { $0 }
      }
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(try await store.loadKey(label: "probe") == nil)
    } cleanup: {
      task.cancel()
      _ = try? await task.value
    }
  }

  @Test
  func alreadyCancelledTaskDoesNotRunWorkButStillCleansItsLabel() async throws {
    let store = InMemoryEd25519KeyStore()
    await store.storeKey(SSHEd25519Key.generate(), label: "probe")
    let ran = Mutex(false)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await KeychainRuntimeCleanup.withCleanup(
        labels: ["probe"],
        work: { ran.withLock { $0 = true } },
        delete: { await store.deleteKey(label: $0) },
        report: { _, error in Issue.record("Unexpected cleanup error: \(error)")
        }
      )
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!ran.withLock { $0 })
    #expect(try await store.loadKey(label: "probe") == nil)
  }
}
