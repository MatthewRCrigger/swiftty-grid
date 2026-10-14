import SessionCore

@testable import ScreenProtocol
import Synchronization
import Testing

@Suite(.serialized)
struct InMemoryTransportTests {
  private func eventually(_ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(1)
    while !condition() {
      if ContinuousClock.now >= deadline { return false }
      try await Task.sleep(for: .milliseconds(1))
    }
    return true
  }

  private struct WeakPair: Sendable {
    weak var client: InMemoryRSTConnection?
    weak var server: InMemoryRSTConnection?
  }

  private final class LifetimeProbe: Sendable {
    let onDeinit: @Sendable () -> Void
    init(_ onDeinit: @escaping @Sendable () -> Void) {
      self.onDeinit = onDeinit
    }
    deinit { onDeinit() }
  }

  @Test
  func closureReleasesHandlersThatCaptureTheirConnections() async throws {
    let weakPair = Mutex(WeakPair())
    let closed = Mutex(0)
    func installAndClose() {
      let (client, server) = InMemoryRSTConnection.pair()
      weakPair.withLock { $0 = WeakPair(client: client, server: server) }
      client.start(
        RSTConnectionHandler(
          onControl: { _ in _ = client.isClosed },
          onClosed: { _ in closed.withLock { $0 += 1 } }
        )
      )
      server.start(
        RSTConnectionHandler(
          onControl: { _ in _ = server.isClosed },
          onClosed: { _ in closed.withLock { $0 += 1 } }
        )
      )
      client.close()
    }
    installAndClose()
    try #require(try await eventually { closed.withLock { $0 } == 2 })
    #expect(
      try await eventually {
        weakPair.withLock { $0.client == nil && $0.server == nil }
      }
    )
  }

  @Test
  func callbackCapturesReleaseAfterOrderedClosure() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    let release = Mutex(false)
    let entered = Mutex(false)
    let closed = Mutex(false)
    let deinitialized = Mutex(false)
    defer {
      release.withLock { $0 = true };
      client.close()
    }
    func install() {
      let probe = LifetimeProbe { deinitialized.withLock { $0 = true } }
      client.start(
        RSTConnectionHandler(
          onControl: { _ in
            entered.withLock { $0 = true }
            while !release.withLock({ $0 }) {
              try? await Task.sleep(for: .milliseconds(1))
            }
            withExtendedLifetime(probe) {}
          },
          onClosed: { _ in closed.withLock { $0 = true } }
        )
      )
    }
    install()
    try await server.sendControl([1])
    try #require(try await eventually { entered.withLock { $0 } })
    client.close()
    #expect(!closed.withLock { $0 })
    #expect(!deinitialized.withLock { $0 })
    release.withLock { $0 = true }
    try #require(try await eventually { closed.withLock { $0 } })
    #expect(try await eventually { deinitialized.withLock { $0 } })
    let rejectedProbeReleased = Mutex(false)
    func tryRestart() {
      let probe = LifetimeProbe { rejectedProbeReleased.withLock { $0 = true } }
      client.start(
        RSTConnectionHandler(
          onControl: { _ in withExtendedLifetime(probe) {} },
          onClosed: { _ in }
        )
      )
    }
    tryRestart()
    #expect(rejectedProbeReleased.withLock { $0 })
    #expect(client.pendingDeliveryCount == 0)
    #expect(client.pendingDeliveryBytes == 0)
  }

  @Test
  func oversizedSnapshotsAreRefusedBeforeDelivery() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    let sizes = Mutex<[Int]>([])
    client.start(
      RSTConnectionHandler(
        onControl: { _ in },
        onSnapshot: { bytes in sizes.withLock { $0.append(bytes.count) } },
        onClosed: { _ in }
      )
    )
    let limit = RSTLimits.maxSnapshotEncodedBytes + SnapshotFrame.headerLength
    await #expect(throws: RSTTransportError.snapshotTooLarge) {
      try await server.sendSnapshot(
        [UInt8](repeating: 0, count: limit + 1),
        stream: 1
      )
    }
    try await server.sendSnapshot(
      [UInt8](repeating: 0, count: limit),
      stream: 2
    )
    try await server.sendSnapshot([7], stream: 3)
    #expect(try await eventually { sizes.withLock { $0.count >= 2 } })
    #expect(sizes.withLock { $0 } == [limit, 1])
  }

  @Test
  func replacingHeldSnapshotCancelsTheOlderSender() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    let received = Mutex<[[UInt8]]>([])
    client.start(
      RSTConnectionHandler(
        onControl: { _ in },
        onSnapshot: { bytes in received.withLock { $0.append(bytes) } },
        onClosed: { _ in }
      )
    )
    server.setHoldSnapshots(true)
    let firstFinished = Mutex(false)
    let first = Task {
      defer { firstFinished.withLock { $0 = true } }
      await #expect(throws: RSTTransportError.canceled) {
        try await server.sendSnapshot([1], stream: 1)
      }
    }
    defer { first.cancel() }
    try #require(try await eventually { server.heldSnapshotGeneration == 1 })
    let second = Task { try await server.sendSnapshot([2], stream: 1) }
    defer { second.cancel() }
    try #require(try await eventually { server.heldSnapshotGeneration == 2 })
    #expect(try await eventually { firstFinished.withLock { $0 } })
    server.releaseSnapshots()
    try await second.value
    // In the failing implementation the first continuation is lost; do
    // not hang the suite waiting for a task that transport closure cannot release.
    if firstFinished.withLock({ $0 }) { await first.value }
    #expect(try await eventually { received.withLock { !$0.isEmpty } })
    #expect(received.withLock { $0 } == [[2]])
  }

  @Test(arguments: [false, true])
  func canceledSnapshotDoesNotRequireRelease(
    _ cancelBeforeSend: Bool
  ) async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    let received = Mutex<[[UInt8]]>([])
    client.start(
      RSTConnectionHandler(
        onControl: { _ in },
        onSnapshot: { bytes in received.withLock { $0.append(bytes) } },
        onClosed: { _ in }
      )
    )
    server.setHoldSnapshots(true)
    let begin = Mutex(false)
    let finished = Mutex(false)
    let sending = Task {
      defer { finished.withLock { $0 = true } }
      while !begin.withLock({ $0 }) { await Task.yield() }
      await #expect(throws: RSTTransportError.canceled) {
        try await server.sendSnapshot([1], stream: 1)
      }
    }
    defer { sending.cancel() }
    if cancelBeforeSend { sending.cancel() }
    begin.withLock { $0 = true }
    try #require(
      try await eventually {
        finished.withLock { $0 } || server.heldSnapshotGeneration == 1
      }
    )
    sending.cancel()
    #expect(try await eventually { finished.withLock { $0 } })
    // Release also joins the failing implementation's still-held sender.
    server.releaseSnapshots()
    await sending.value
    server.setHoldSnapshots(false)
    try await server.sendSnapshot([2], stream: 1)
    #expect(try await eventually { received.withLock { $0.contains([2]) } })
    #expect(received.withLock { $0 } == [[2]])
    #expect(!client.isClosed && !server.isClosed)
    if cancelBeforeSend { #expect(server.heldSnapshotGeneration == 0) }
  }

  @Test
  func heldSnapshotsHaveFiniteAdmissionAndReusableCapacity() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    server.setHoldSnapshots(true)
    var sends: [Task<Void, any Error>] = []
    defer { sends.forEach { $0.cancel() } }
    for id in 0 ..< InMemoryRSTConnection.maxHeldSnapshots {
      sends.append(
        Task { try await server.sendSnapshot([UInt8(id)], stream: UInt64(id)) }
      )
      try #require(try await eventually { server.heldSnapshotCount == id + 1 })
    }
    let overflowFinished = Mutex(false)
    let overflowID = UInt64(InMemoryRSTConnection.maxHeldSnapshots)
    let overflow = Task {
      defer { overflowFinished.withLock { $0 = true } }
      await #expect(throws: RSTTransportError.resourceLimit) {
        try await server.sendSnapshot([99], stream: overflowID)
      }
    }
    defer { overflow.cancel() }
    #expect(try await eventually { overflowFinished.withLock { $0 } })
    #expect(server.heldSnapshotCount == InMemoryRSTConnection.maxHeldSnapshots)
    // Also join the baseline's erroneously admitted overflow sender.
    if !overflowFinished.withLock({ $0 }) {
      server.cancelSnapshot(stream: overflowID)
    }
    await overflow.value
    let generation = server.heldSnapshotGeneration
    let replacement = Task { try await server.sendSnapshot([100], stream: 0) }
    sends.append(replacement)
    try #require(
      try await eventually { server.heldSnapshotGeneration == generation + 1 }
    )
    await #expect(throws: RSTTransportError.canceled) {
      try await sends[0].value
    }
    #expect(server.heldSnapshotCount == InMemoryRSTConnection.maxHeldSnapshots)
    server.cancelSnapshot(stream: 1)
    await #expect(throws: RSTTransportError.canceled) {
      try await sends[1].value
    }
    let next = Task { try await server.sendSnapshot([101], stream: overflowID) }
    sends.append(next)
    try #require(
      try await eventually {
        server.heldSnapshotCount == InMemoryRSTConnection.maxHeldSnapshots
      }
    )
    server.releaseSnapshots()
    for send in sends.dropFirst(2) { try await send.value }
    #expect(server.heldSnapshotCount == 0)
    let held = Task { try await server.sendSnapshot([102], stream: 1000) }
    sends.append(held)
    try #require(try await eventually { server.heldSnapshotCount == 1 })
    server.close()
    await #expect(throws: RSTTransportError.closed) { try await held.value }
    #expect(server.heldSnapshotCount == 0)
  }

  @Test
  func concurrentHeldSnapshotsRespectAdmissionCapacity() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    server.setHoldSnapshots(true)
    let refused = Mutex(0)
    let completed = Mutex(0)
    let sends = (0 ..< 64)
      .map { id in
        Task {
          do {
            try await server.sendSnapshot([UInt8(id)], stream: UInt64(id))
            completed.withLock { $0 += 1 }
          } catch {
            #expect(error as? RSTTransportError == .resourceLimit)
            refused.withLock { $0 += 1 }
          }
        }
      }
    defer { sends.forEach { $0.cancel() } }
    try #require(
      try await eventually {
        refused.withLock { $0 } == sends.count
          - InMemoryRSTConnection.maxHeldSnapshots
      }
    )
    #expect(server.heldSnapshotCount == InMemoryRSTConnection.maxHeldSnapshots)
    #expect(completed.withLock { $0 } == 0)
    server.releaseSnapshots()
    for send in sends { await send.value }
    #expect(completed.withLock { $0 } == InMemoryRSTConnection.maxHeldSnapshots)
    #expect(server.heldSnapshotCount == 0)
  }

  @Test
  func preCanceledSnapshotHistoryKeepsOnlyRecentIDs() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    let received = Mutex<[[UInt8]]>([])
    client.start(
      RSTConnectionHandler(
        onControl: { _ in },
        onSnapshot: { bytes in received.withLock { $0.append(bytes) } },
        onClosed: { _ in }
      )
    )
    let count = 100_000
    let capacity = InMemoryRSTConnection.maxPreCanceledSnapshots
    for id in 0 ..< count { server.cancelSnapshot(stream: UInt64(id)) }
    let retained = server.preCanceledSnapshotCount
    #expect(retained == capacity)
    // Repeating a recent cancellation must not flush other recent IDs.
    server.cancelSnapshot(stream: UInt64(count - 1))
    for id in count - capacity ..< count {
      await #expect(throws: RSTTransportError.canceled) {
        try await server.sendSnapshot([1], stream: UInt64(id))
      }
    }
    let remaining = server.preCanceledSnapshotCount
    #expect(remaining == 0)
    do { try await server.sendSnapshot([2], stream: 0) } catch {
      Issue.record("expired cancellation refused a valid snapshot: \(error)")
    }
    try await server.sendSnapshot([3], stream: UInt64(count))
    #expect(try await eventually { received.withLock { $0.contains([3]) } })
    #expect(received.withLock { $0 } == [[2], [3]])
  }

  @Test
  func closedConnectionsDiscardSnapshotCancellationHistory() {
    let (client, server) = InMemoryRSTConnection.pair()
    server.cancelSnapshot(stream: 1)
    client.close()
    for id in 2 ..< 100_000 { server.cancelSnapshot(stream: UInt64(id)) }
    let retained = server.preCanceledSnapshotCount
    #expect(retained == 0)
    #expect(server.isClosed)
  }

  @Test
  func deliveryWindowStaysOccupiedUntilCallbacksReturn() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    let release = Mutex(false)
    defer {
      release.withLock { $0 = true };
      client.close()
    }
    for id in 0 ..< InMemoryRSTConnection.maxPendingEvents {
      if id.isMultiple(of: 2) {
        try await server.sendControl([])
      } else {
        try await server.sendSnapshot([], stream: UInt64(id))
      }
    }
    #expect(
      client.pendingDeliveryCount == InMemoryRSTConnection.maxPendingEvents
    )
    let seen = Mutex(0)
    let receive: @Sendable ([UInt8]) async -> Void = { _ in
      seen.withLock { $0 += 1 }
      while !release.withLock({ $0 }) {
        try? await Task.sleep(for: .milliseconds(1))
      }
    }
    client.start(
      RSTConnectionHandler(
        onControl: receive,
        onSnapshot: receive,
        onClosed: { _ in }
      )
    )
    try #require(try await eventually { seen.withLock { $0 } == 1 })
    await #expect(throws: RSTTransportError.resourceLimit) {
      try await server.sendControl([])
    }
    await #expect(throws: RSTTransportError.resourceLimit) {
      try await server.sendSnapshot([], stream: 1000)
    }
    #expect(
      client.pendingDeliveryCount == InMemoryRSTConnection.maxPendingEvents
    )
    release.withLock { $0 = true }
    try #require(try await eventually { client.pendingDeliveryCount == 0 })
    #expect(seen.withLock { $0 } == InMemoryRSTConnection.maxPendingEvents)
    #expect(client.pendingDeliveryBytes == 0)
    try await server.sendControl([1])
    try #require(
      try await eventually {
        seen.withLock { $0 } == InMemoryRSTConnection.maxPendingEvents + 1
      }
    )
  }

  @Test
  func byteWindowAndReentrantReserveAreBothBounded() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    let limit = InMemoryRSTConnection.maxPendingBytes
    await #expect(throws: RSTTransportError.resourceLimit) {
      try await server.sendControl([UInt8](repeating: 0, count: limit + 1))
    }
    #expect(client.pendingDeliveryCount == 0)
    try await server.sendControl([UInt8](repeating: 0, count: limit))
    await #expect(throws: RSTTransportError.resourceLimit) {
      try await server.sendControl([1])
    }
    await #expect(throws: RSTTransportError.resourceLimit) {
      try await server.sendSnapshot([1], stream: 1)
    }
    #expect(client.pendingDeliveryBytes == limit)
    let seen = Mutex(0)
    client.start(
      RSTConnectionHandler(
        onControl: { bytes in
          if bytes.first == 0 {
            do {
              try await server.sendControl([UInt8](repeating: 1, count: limit))
            } catch { Issue.record("reserved reentrant send failed: \(error)") }
            #expect(client.pendingDeliveryCount == 2)
            #expect(client.pendingDeliveryBytes == 2 * limit)
            await #expect(throws: RSTTransportError.resourceLimit) {
              try await server.sendControl([1])
            }
          }
          seen.withLock { $0 += 1 }
        },
        onClosed: { _ in }
      )
    )
    try #require(
      try await eventually {
        seen.withLock { $0 } == 2 && client.pendingDeliveryCount == 0
      }
    )
    #expect(client.pendingDeliveryBytes == 0)
  }

  @Test
  func concurrentDeliveryAdmissionAndCloseBeforeStartAreBounded() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    let accepted = await withTaskGroup(of: Bool.self) { group in
      for id in 0 ..< 400 {
        group.addTask {
          do {
            if id.isMultiple(of: 2) {
              try await server.sendControl([1])
            } else {
              try await server.sendSnapshot([1], stream: UInt64(id))
            }
            return true
          } catch {
            #expect(error as? RSTTransportError == .resourceLimit)
            return false
          }
        }
      }
      var accepted = 0
      for await result in group where result { accepted += 1 }
      return accepted
    }
    #expect(accepted == InMemoryRSTConnection.maxPendingEvents)
    #expect(client.pendingDeliveryCount == accepted)
    #expect(client.pendingDeliveryBytes == accepted)
    client.close()
    #expect(client.pendingDeliveryCount == accepted)
    let received = Mutex(0)
    let countAtClose = Mutex<Int?>(nil)
    let receive: @Sendable ([UInt8]) async -> Void = { _ in
      received.withLock { $0 += 1 }
    }
    client.start(
      RSTConnectionHandler(
        onControl: receive,
        onSnapshot: receive,
        onClosed: { _ in countAtClose.withLock { $0 = received.withLock { $0 } }
        }
      )
    )
    try #require(try await eventually { countAtClose.withLock { $0 } != nil })
    #expect(countAtClose.withLock { $0 } == accepted)
    #expect(client.pendingDeliveryCount == 0)
    #expect(client.pendingDeliveryBytes == 0)
  }

  @Test
  func childTasksCannotKeepReentrantCreditAfterTheirCallbackReturns()
    async throws
  {
    let (client, server) = InMemoryRSTConnection.pair()
    let childMaySend = Mutex(false)
    let release = Mutex(false)
    let paused = Mutex(false)
    let childTask = Mutex<Task<Void, Never>?>(nil)
    let childFinished = Mutex(false)
    defer {
      childMaySend.withLock { $0 = true }
      release.withLock { $0 = true }
      childTask.withLock { $0 }?.cancel()
      client.close()
    }
    client.start(
      RSTConnectionHandler(
        onControl: { bytes in
          if bytes == [0] {
            let child = Task {
              while !childMaySend.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(1))
              }
              await #expect(throws: RSTTransportError.resourceLimit) {
                try await server.sendControl([2])
              }
              childFinished.withLock { $0 = true }
            }
            childTask.withLock { $0 = child }
          } else if bytes == [1] {
            paused.withLock { $0 = true }
            while !release.withLock({ $0 }) {
              try? await Task.sleep(for: .milliseconds(1))
            }
          }
        },
        onClosed: { _ in }
      )
    )
    try await server.sendControl([0])
    try #require(
      try await eventually {
        childTask.withLock { $0 != nil } && client.pendingDeliveryCount == 0
      }
    )
    try await server.sendControl([1])
    try #require(try await eventually { paused.withLock { $0 } })
    for _ in 1 ..< InMemoryRSTConnection.maxPendingEvents {
      try await server.sendControl([])
    }
    childMaySend.withLock { $0 = true }
    try #require(try await eventually { childFinished.withLock { $0 } })
    await childTask.withLock { $0 }?.value
    #expect(
      client.pendingDeliveryCount == InMemoryRSTConnection.maxPendingEvents
    )
    release.withLock { $0 = true }
    try #require(try await eventually { client.pendingDeliveryCount == 0 })
    #expect(client.pendingDeliveryBytes == 0)
  }

  @Test(arguments: [false, true])
  func orderlyClosureAndPathLossReportConsistentErrorsAtBothEnds(
    _ sever: Bool
  ) async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    defer { client.close() }
    let errors = Mutex<[RSTTransportError?]>([])
    let closed: @Sendable ((any Error)?) -> Void = { error in
      if let error { #expect(error is RSTTransportError) }
      errors.withLock { $0.append(error as? RSTTransportError) }
    }
    client.start(RSTConnectionHandler(onControl: { _ in }, onClosed: closed))
    server.start(RSTConnectionHandler(onControl: { _ in }, onClosed: closed))
    if sever { client.sever() } else { client.close() }
    try #require(try await eventually { errors.withLock { $0.count } == 2 })
    #expect(errors.withLock { $0.allSatisfy { $0 == (sever ? .closed : nil) } })
    client.close()
    server.sever()
    #expect(errors.withLock { $0.count } == 2)
  }

  private struct Received {
    var events: [Int] = []
    var countAtClose: Int?
    var afterClose = 0
  }

  @Test(arguments: 0 ..< 4, [false, true])
  func `handler handoff preserves buffered events before new events and close`(
    iteration _: Int,
    childSends: Bool
  ) async throws {
    let count = 20_000
    let (client, server) = InMemoryRSTConnection.pair(deliveryEventLimit: count)
    defer { client.close() }
    // Fill the explicit finite stress window. The first callback must
    // still admit its reentrant record before closing the receiver.
    for index in 0 ..< count {
      let bytes = [UInt8(index >> 8), UInt8(truncatingIfNeeded: index)]
      if index.isMultiple(of: 2) {
        try await server.sendControl(bytes)
      } else {
        try await server.sendSnapshot(bytes, stream: UInt64(index))
      }
    }
    let received = Mutex(Received())
    let record: @Sendable ([UInt8]) -> Void = { bytes in
      let index = bytes.count == 2 ? Int(bytes[0]) << 8 | Int(bytes[1]) : count
      received.withLock {
        if $0.countAtClose != nil { $0.afterClose += 1 }
        $0.events.append(index)
      }
    }
    client.start(
      RSTConnectionHandler(
        onControl: { bytes in
          record(bytes)
          if bytes == [0, 0] {
            do {
              if childSends {
                try await Task { try await server.sendControl([255]) }.value
              } else {
                try await server.sendControl([255])
              }
            } catch {
              Issue.record("new event rejected before close: \(error)")
            }
            client.close()
          }
        },
        onSnapshot: { record($0) },
        onClosed: { _ in received.withLock { $0.countAtClose = $0.events.count }
        }
      )
    )
    let deadline = ContinuousClock.now + .seconds(10)
    while received.withLock({
      $0.events.count < count + 1 || $0.countAtClose == nil
    }) {
      try #require(ContinuousClock.now < deadline, "delivery did not finish")
      try await Task.sleep(for: .milliseconds(1))
    }
    let result = received.withLock { $0 }
    #expect(result.countAtClose == count + 1)
    #expect(result.afterClose == 0)
    #expect(result.events.firstIndex(of: count) == count)
    #expect(result.events.enumerated().allSatisfy { $0.offset == $0.element })
  }

  @Test
  func `queued async callbacks finish before closure`() async throws {
    let (client, server) = InMemoryRSTConnection.pair()
    let released = Mutex(false)
    defer {
      released.withLock { $0 = true }
      client.close()
    }
    let received = Mutex(Received())
    client.start(
      RSTConnectionHandler(
        onControl: { bytes in
          received.withLock { $0.events.append(Int(bytes[0])) }
          if bytes == [0] {
            while !released.withLock({ $0 }) {
              try? await Task.sleep(for: .milliseconds(1))
            }
          }
        },
        onSnapshot: { bytes in
          received.withLock { $0.events.append(Int(bytes[0])) }
        },
        onClosed: { _ in received.withLock { $0.countAtClose = $0.events.count }
        }
      )
    )
    try await server.sendControl([0])
    let deadline = ContinuousClock.now + .seconds(10)
    while received.withLock({ $0.events.isEmpty }) {
      try #require(
        ContinuousClock.now < deadline,
        "first callback did not start"
      )
      try await Task.sleep(for: .milliseconds(1))
    }
    try await server.sendControl([1])
    try await server.sendSnapshot([2], stream: 1)
    client.close()
    #expect(received.withLock { $0.events } == [0])
    #expect(received.withLock { $0.countAtClose } == nil)
    await #expect(throws: RSTTransportError.closed) {
      try await server.sendControl([3])
    }
    released.withLock { $0 = true }
    while received.withLock({ $0.countAtClose == nil }) {
      try #require(
        ContinuousClock.now < deadline,
        "close callback did not arrive"
      )
      try await Task.sleep(for: .milliseconds(1))
    }
    #expect(received.withLock { $0.events } == [0, 1, 2])
    #expect(received.withLock { $0.countAtClose } == 3)
  }
}
