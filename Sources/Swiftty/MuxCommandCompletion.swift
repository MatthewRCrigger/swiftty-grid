import SwiftMuxProtocol
import Synchronization

/// Resumes a continuation exactly once; released unresumed, it fails.
final class MuxCommandCompletion: Sendable {
  private let done: Mutex<CheckedContinuation<Void, any Error>?>

  init(_ done: CheckedContinuation<Void, any Error>) { self.done = Mutex(done) }

  func resume(throwing error: (any Error)? = nil) {
    guard let done = self.done.withLock({ $0.take() }) else { return }
    if let error { done.resume(throwing: error) } else { done.resume() }
  }

  deinit { resume(throwing: MuxError(.notAttached)) }
}

/// Queued callbacks own the completion. Dropping a command releases it
/// and fails the waiter; cancellation does not keep that completion alive.
struct MuxCommandWait: Sendable {
  var cancelled = false
  weak var once: MuxCommandCompletion?
}
