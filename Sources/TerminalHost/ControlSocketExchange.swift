#if os(macOS)
import Darwin
import Synchronization

/// Owns one accepted socket across blocking I/O and a suspended handler.
/// Cancellation shuts down I/O immediately; close waits only for active
/// syscalls, so a handler cannot retain a usable socket after stop or expiry.
final class ControlSocketExchange: Sendable {
  private struct State {
    var fd: Int32
    var users = 0
    var stopped = false
    var task: Task<Void, Never>?
    var deadline: Task<Void, Never>?
  }

  private let state: Mutex<State>
  private let onFinished: @Sendable (ControlSocketExchange) -> Void

  init(
    fd: Int32,
    onFinished: @escaping @Sendable (ControlSocketExchange) -> Void
  ) {
    state = Mutex(State(fd: fd))
    self.onFinished = onFinished
  }

  var isStopped: Bool { state.withLock { $0.stopped } }

  func withSocket<T>(_ body: (Int32) -> T) -> T? {
    let fd = state.withLock { value -> Int32? in
      guard !value.stopped else { return nil }
      value.users += 1
      return value.fd
    }
    guard let fd else { return nil }
    defer {
      state.withLock { value in
        value.users -= 1
        if value.stopped && value.users == 0 && value.fd >= 0 {
          close(value.fd)
          value.fd = -1
        }
      }
    }
    return body(fd)
  }

  func expire(at deadline: ContinuousClock.Instant) {
    let timer = Task<Void, Never> { [weak self] in
      do { try await Task.sleep(until: deadline, clock: .continuous) } catch {
        return
      }
      self?.cancel()
    }
    let stopped = state.withLock { value in
      guard !value.stopped else { return true }
      value.deadline = timer
      return false
    }
    if stopped { timer.cancel() }
  }

  func install(_ task: Task<Void, Never>) {
    let stopped = state.withLock { value in
      guard !value.stopped else { return true }
      value.task = task
      return false
    }
    if stopped { task.cancel() }
  }

  func cancel() {
    let tasks = state.withLock { value in
      value.stopped = true
      if value.fd >= 0 {
        shutdown(value.fd, SHUT_RDWR)
        if value.users == 0 {
          close(value.fd)
          value.fd = -1
        }
      }
      defer {
        value.task = nil
        value.deadline = nil
      }
      return (value.task, value.deadline)
    }
    // Cancellation handlers may call back into their server.
    tasks.0?.cancel()
    tasks.1?.cancel()
  }

  func finish() {
    cancel()
    onFinished(self)
  }
}
#endif
