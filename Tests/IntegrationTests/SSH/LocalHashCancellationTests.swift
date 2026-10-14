import Crypto
import Darwin
import Foundation
import SessionCore
import Synchronization
import Testing

@testable import SSHClient

private final class HashReadGate: Sendable {
  let offsets = Mutex<[UInt64]>([])
  private let released = DispatchSemaphore(value: 0)

  func hold(_ offset: UInt64) throws {
    offsets.withLock { $0.append(offset) }
    guard released.wait(timeout: .now() + .seconds(5)) == .success else {
      throw POSIXError(.ETIMEDOUT)
    }
  }

  func release() { released.signal() }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct LocalHashCancellationTests {
  @Test(arguments: [false, true])
  func cancelledQueuedJobNeverEntersItsBody(
    _ alreadyCancelled: Bool
  ) async throws {
    let queue = DispatchQueue(label: "swiftty.tests.hash-cancellation")
    let gate = HashReadGate()
    defer { gate.release() }
    let blocker = Task {
      try await BlockingFileIO.runCancellable(on: queue) { _ in try gate.hold(0)
      }
    }
    defer { blocker.cancel() }
    try #require(try await waitUntil { gate.offsets.withLock { !$0.isEmpty } })
    let entered = Mutex(false)
    let enqueued = Mutex(false)
    let settled = Mutex(false)
    let job = Task {
      defer { settled.withLock { $0 = true } }
      if alreadyCancelled { withUnsafeCurrentTask { $0?.cancel() } }
      return try await BlockingFileIO.runCancellable(
        on: queue,
        afterEnqueueForTesting: { enqueued.withLock { $0 = true } },
        { _ in entered.withLock { $0 = true } }
      )
    }
    defer { job.cancel() }
    try #require(try await waitUntil { enqueued.withLock { $0 } })
    if !alreadyCancelled { job.cancel() }
    #expect(!settled.withLock { $0 })
    gate.release()
    try await blocker.value
    await #expect(throws: CancellationError.self) { try await job.value }
    #expect(!entered.withLock { $0 })
    #expect(settled.withLock { $0 })
    #expect(try await BlockingFileIO.runCancellable(on: queue) { _ in 7 } == 7)
  }

  @Test
  func runningHashStopsAfterOneChunkAndKeepsItsDescriptorUntilSettlement()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hash-cancel-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let data = Data(repeating: 0x5a, count: 3 * 256 * 1024)
    try data.write(to: source)
    let file = try await LocalFile.open(source.path, flags: O_RDONLY)
    defer { Darwin.close(file.fd) }
    let gate = HashReadGate()
    defer { gate.release() }
    let settled = Mutex(false)
    let hashing = Task {
      defer { settled.withLock { $0 = true } }
      return try await file.sha256(
        length: UInt64(data.count),
        afterReadForTesting: { try gate.hold($0) }
      )
    }
    defer { hashing.cancel() }
    try #require(try await waitUntil { gate.offsets.withLock { !$0.isEmpty } })
    hashing.cancel()
    #expect(!settled.withLock { $0 })
    #expect(fcntl(file.fd, F_GETFD) >= 0)
    gate.release()
    await #expect(throws: CancellationError.self) { try await hashing.value }
    #expect(gate.offsets.withLock { $0 } == [0])
    #expect(settled.withLock { $0 })
    #expect(
      try await file.sha256(length: 0) == hexString(SHA256.hash(data: []))
    )
    #expect(
      try await file.sha256(length: UInt64(data.count))
        == hexString(SHA256.hash(data: data))
    )
    #expect(try await file.sha256(length: UInt64(data.count + 1)) == nil)
  }

  @Test(arguments: [false, true])
  func cancelledStagingStopsBeforeCopyOrAfterFirstHashChunk(
    _ hashing: Bool
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("stage-cancel-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let data = Data(repeating: 0x3c, count: 3 * 256 * 1024)
    try data.write(to: source)
    let staging = directory.appendingPathComponent("staging")
    let gate = HashReadGate()
    defer { gate.release() }
    let settled = Mutex(false)
    let beforeCopy: (@Sendable () throws -> Void)? =
      hashing ? nil : { @Sendable in try gate.hold(0) }
    let afterRead: (@Sendable (UInt64) throws -> Void)? =
      hashing ? { @Sendable offset in try gate.hold(offset) } : nil
    let preparing = Task {
      defer { settled.withLock { $0 = true } }
      return try await SFTPTransfers.prepareUpload(
        source: source,
        remotePath: "/destination",
        stagingDirectory: staging,
        beforeCopyForTesting: beforeCopy,
        afterHashReadForTesting: afterRead
      )
    }
    defer { preparing.cancel() }
    try #require(try await waitUntil { gate.offsets.withLock { !$0.isEmpty } })
    preparing.cancel()
    #expect(!settled.withLock { $0 })
    gate.release()
    await #expect(throws: CancellationError.self) { try await preparing.value }
    #expect(gate.offsets.withLock { $0 } == [0])
    #expect(settled.withLock { $0 })
    let leftovers = try? FileManager.default.contentsOfDirectory(
      atPath: staging.path
    )
    #expect(leftovers == nil || leftovers == [])
    #expect(try Data(contentsOf: source) == data)
    let fresh = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/destination",
      stagingDirectory: staging
    )
    #expect(fresh.sourceSHA256 == hexString(SHA256.hash(data: data)))
    await SFTPTransfers.discard(fresh, client: nil)
  }
}
