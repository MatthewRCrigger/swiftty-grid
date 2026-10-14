import Dispatch
import Synchronization
import TerminalSurface

/// One pending main-queue update, retaining only the latest refusal.
final class InputRefusalRelay: Sendable {
  private struct State: Sendable {
    var latest: InputRefusal?
    var scheduled = false
    var closed = false
  }

  private let state = Mutex(State())
  private let receive: @MainActor @Sendable (InputRefusal) -> Void

  init(receive: @escaping @MainActor @Sendable (InputRefusal) -> Void) {
    self.receive = receive
  }

  func report(_ refusal: InputRefusal) {
    let schedule = state.withLock { s in
      guard !s.closed else { return false }
      s.latest = refusal
      guard !s.scheduled else { return false }
      s.scheduled = true
      return true
    }
    if schedule {
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.deliver() }
      }
    }
  }

  func close() {
    state.withLock { s in
      s.closed = true
      s.latest = nil
    }
  }

  @MainActor private func deliver() {
    let refusal = state.withLock { s in
      defer {
        s.scheduled = false
        s.latest = nil
      }
      return s.closed ? nil : s.latest
    }
    if let refusal {
      receive(refusal)
    }
  }
}
