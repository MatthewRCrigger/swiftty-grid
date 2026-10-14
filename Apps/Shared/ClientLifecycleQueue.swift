import Foundation
import TerminalSurface

/// Orders lifecycle and geometry calls for the selected roaming client.
@MainActor
final class ClientLifecycleQueue {
  private var client: RoamingClient?
  private var tail: Task<Void, Never>?
  private var generation = UUID()

  /// Starts a fresh chain and invalidates calls waiting on the old selection.
  /// Returns the old tail so close can await an already-dispatched detach.
  @discardableResult
  func use(_ client: RoamingClient?) -> Task<Void, Never>? {
    let previous = tail
    generation = UUID()
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
    let generation = generation
    let task = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled, self?.generation == generation else { return }
      await operation(client)
    }
    tail = task
    return task
  }
}
