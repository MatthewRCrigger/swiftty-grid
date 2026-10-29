import Foundation
import Synchronization
import TerminalSurface

/// Orders lifecycle and geometry calls for the selected roaming client.
/// The calls never need the main actor, so a close can wait for them
/// while a quit blocks the main queue.
@MainActor
final class ClientLifecycleQueue {
  /// The calls queued for one selection; `use(_:)` ends it.
  private final class Selection: Sendable {
    private let ended = Atomic(false)

    var isCurrent: Bool { !ended.load(ordering: .acquiring) }

    func end() { ended.store(true, ordering: .releasing) }
  }

  private var client: RoamingClient?
  private var tail: Task<Void, Never>?
  private var selection = Selection()

  isolated deinit { selection.end() }

  /// Starts a fresh chain and invalidates calls waiting on the old selection.
  /// Returns the old tail so close can await an already-dispatched detach.
  @discardableResult
  func use(_ client: RoamingClient?) -> Task<Void, Never>? {
    let previous = tail
    selection.end()
    selection = Selection()
    tail?.cancel()
    tail = nil
    self.client = client
    return previous
  }

  @discardableResult
  func enqueue(
    _ operation: @escaping @Sendable (RoamingClient) async -> Void,
  ) -> Task<Void, Never>? {
    guard let client else { return nil }
    let previous = tail
    let selection = selection
    let task = Task.detached(priority: Task.currentPriority) {
      await previous?.value
      guard !Task.isCancelled, selection.isCurrent else { return }
      await operation(client)
    }
    tail = task
    return task
  }
}
