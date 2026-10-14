import Darwin
import Dispatch
import Foundation
@testable import SwiftMuxClient
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct AgentUnregisterWaitTests {
  private enum ProbeFailure: Error, Equatable { case expected }

  @Test(arguments: [false, true])
  func immediateFirstResultSurvivesDuplicateCallbacks(fails: Bool) throws {
    let begin: (@escaping @Sendable ((any Error)?) -> Void) -> Void = {
      complete in
      complete(fails ? ProbeFailure.expected : nil)
      complete(fails ? nil : ProbeFailure.expected)
    }
    if fails {
      #expect(throws: ProbeFailure.expected) {
        try AgentUnregisterWait.run(timeout: .seconds(1), begin)
      }
    } else {
      try AgentUnregisterWait.run(timeout: .seconds(1), begin)
    }
  }

  @Test
  func asynchronousCompletionPreservesExactError() {
    #expect(throws: ProbeFailure.expected) {
      try AgentUnregisterWait.run(timeout: .seconds(1)) { complete in
        DispatchQueue.global().async { complete(ProbeFailure.expected) }
      }
    }
  }

  @Test
  func missingCompletionTimesOutAndLateConcurrentCallbacksAreSafe() throws {
    let callback = Mutex<(@Sendable ((any Error)?) -> Void)?>(nil)
    let started = ContinuousClock.now
    #expect(throws: AgentUnregisterWait.Failure.timedOut) {
      try AgentUnregisterWait.run(timeout: .milliseconds(50)) { complete in
        callback.withLock { $0 = complete }
      }
    }
    #expect(ContinuousClock.now - started < .seconds(1))
    let complete = try #require(callback.withLock { $0 })
    DispatchQueue.concurrentPerform(iterations: 1000) { index in
      complete(index.isMultiple(of: 2) ? nil : ProbeFailure.expected)
    }
    // A timed-out operation's callbacks cannot affect a later command.
    try AgentUnregisterWait.run(timeout: .seconds(1)) { $0(nil) }
    callback.withLock { $0 = nil }
  }

  @Test
  func successObservedAfterDeadlineIsRejected() {
    #expect(throws: AgentUnregisterWait.Failure.timedOut) {
      try AgentUnregisterWait.run(timeout: .milliseconds(5)) { complete in
        usleep(20000)
        complete(nil)
      }
    }
  }
}
