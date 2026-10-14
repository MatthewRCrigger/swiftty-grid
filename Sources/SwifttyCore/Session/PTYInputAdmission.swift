import Synchronization

/// Credit covers input awaiting encoding and bytes awaiting the PTY.
/// Replies share the byte count but cannot be refused like user input.
package final class PTYInputAdmission: Sendable {
  private struct State: Sendable {
    var reserved = 0
    var buffered = 0
    var closed = false
  }

  package let limit: Int
  private let state = Mutex(State())

  package init(limit: Int) {
    precondition(limit > 0)
    self.limit = limit
  }

  package var pendingBytes: Int { state.withLock { $0.reserved + $0.buffered } }

  package func reserve(_ count: Int) -> Bool {
    state.withLock { s in
      guard !s.closed, count <= limit - s.reserved - s.buffered else {
        return false
      }
      s.reserved += count
      return true
    }
  }

  /// Atomically substitutes actual encoding for its conservative reservation.
  package func encoded(_ count: Int, reservation: Int) -> Bool {
    state.withLock { s in
      guard !s.closed else { return false }
      s.reserved -= reservation
      s.buffered += count
      return true
    }
  }

  package func consumed(_ count: Int) {
    state.withLock { s in if !s.closed { s.buffered -= count } }
  }

  package func close() {
    state.withLock { s in
      s.closed = true
      s.reserved = 0
      s.buffered = 0
    }
  }
}
