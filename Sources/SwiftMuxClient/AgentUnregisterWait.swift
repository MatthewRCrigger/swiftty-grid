import Dispatch
import Foundation
import Synchronization

/// Bounds the CLI's wait for ServiceManagement's asynchronous unregister
/// completion. The API submits promptly; a timeout leaves completion unknown.
package enum AgentUnregisterWait {
  package enum Failure: Error, Equatable, LocalizedError {
    case timedOut

    package var errorDescription: String? {
      "unregister did not complete within ten seconds; completion is unknown"
    }
  }

  package static func run(
    _ begin: (@escaping @Sendable ((any Error)?) -> Void) -> Void,
  ) throws { try run(timeout: .seconds(10), begin) }

  static func run(
    timeout: DispatchTimeInterval,
    _ begin: (@escaping @Sendable ((any Error)?) -> Void) -> Void,
  ) throws {
    let completion = UnregisterCompletion(deadline: .now() + timeout)
    begin { error in
      if let error {
        completion.finish(.failure(error))
      } else {
        completion.finish(.success(()))
      }
    }
    if completion.signal.wait(timeout: completion.deadline) == .timedOut {
      completion.finish(.failure(Failure.timedOut))
    }
    try completion.result()
  }
}

/// A callback can outlive the waiting CLI invocation. It retains only this
/// result, never the caller's stack storage or service registration object.
private final class UnregisterCompletion: Sendable {
  let deadline: DispatchTime
  let signal = DispatchSemaphore(value: 0)
  private let outcome = Mutex<Result<Void, any Error>?>(nil)

  init(deadline: DispatchTime) { self.deadline = deadline }

  func finish(_ result: Result<Void, any Error>) {
    let first = outcome.withLock { outcome in
      guard outcome == nil else { return false }
      outcome =
        DispatchTime.now() < deadline
        ? result : .failure(AgentUnregisterWait.Failure.timedOut)
      return true
    }
    if first { signal.signal() }
  }

  func result() throws {
    let result = outcome.withLock {
      $0 ?? .failure(AgentUnregisterWait.Failure.timedOut)
    }
    try result.get()
  }
}
