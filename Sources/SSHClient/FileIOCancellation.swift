import Synchronization

/// Shared with a blocking queue job; cancellation never releases its owner
/// before the body and all descriptor cleanup have finished.
final class FileIOCancellation: Sendable {
  private let cancelled = Mutex(false)

  func cancel() { cancelled.withLock { $0 = true } }

  func check() throws {
    if cancelled.withLock({ $0 }) { throw CancellationError() }
  }
}
