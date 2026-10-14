import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing
import TestSupport

@Suite(.serialized, .timeLimit(.minutes(1)))
struct InboxCapacityTests {
  @Test
  func disabledPagingRejectsReadsAndAdmissionButAllowsUnsubscribe() async throws
  {
    var limits = MuxLimits.standard
    limits.inboxPageSize = 0
    let harness = try Harness(limits: limits)
    var connection: MuxConnection?
    try await RuntimeFixture.withCleanup {
      let client = try await harness.connect(.control)
      connection = client
      for command in [MuxCommand.inbox(InboxQuery()), .subscribeInbox(true)] {
        do {
          _ = try await client.execute(command)
          Issue.record("Disabled paging returned success")
        } catch let error as MuxError { #expect(error.code == .resourceLimit) }
      }
      for _ in 0 ..< 2 {
        let reply = try await client.execute(.subscribeInbox(false))
        #expect(reply == .ok)
      }
      let reply = try await client.execute(.listWorkspaces)
      guard case let .workspaces(list) = reply else {
        Issue.record("Service did not answer after rejected paging")
        return
      }
      #expect(list.isEmpty)
    } cleanup: {
      await connection?.close()
      await withCheckedContinuation { continuation in
        harness.service.prepareToExit { continuation.resume() }
      }
    }
  }

  @Test
  func healthySubscriptionReturnsSnapshotAndUnsubscribeReleasesItsSlot()
    async throws
  {
    var limits = MuxLimits.standard
    limits.inboxSubscribers = 1
    let harness = try Harness(limits: limits)
    var connections: [MuxConnection] = []
    try await RuntimeFixture.withCleanup {
      let a = try await harness.connect(.control)
      connections.append(a)
      let b = try await harness.connect(.control)
      connections.append(b)
      guard
        case let .inbox(snapshot) = try await a.execute(.subscribeInbox(true))
      else {
        Issue.record("Subscription omitted its initial snapshot")
        return
      }
      #expect(snapshot.items.isEmpty)
      do {
        _ = try await b.execute(.subscribeInbox(true))
        Issue.record("Subscriber bound was exceeded")
      } catch let error as MuxError { #expect(error.code == .resourceLimit) }
      #expect(try await a.execute(.subscribeInbox(false)) == .ok)
      guard case .inbox = try await b.execute(.subscribeInbox(true)) else {
        Issue.record("Unsubscribe failed to release its slot")
        return
      }
    } cleanup: {
      for connection in connections { await connection.close() }
      await withCheckedContinuation { continuation in
        harness.service.prepareToExit { continuation.resume() }
      }
    }
  }
}
