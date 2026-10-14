#if os(macOS)
import Darwin

/// Finite waits for test children whose exclusive reaping authority belongs
/// to the caller. Use one owner on one thread; do not independently reap
/// its child. Do not use for Foundation.Process or a live session child.
public final class OwnedChildWait {
  private let pid: pid_t
  private var owned = true

  public init(_ pid: pid_t) {
    precondition(pid > 0)
    self.pid = pid
  }

  /// Collects exit status, or returns nil on timeout or loss of ownership.
  /// A timeout leaves the child untouched for the caller's cleanup.
  public func collect(timeout: Duration = .seconds(5), ) -> Int32? {
    precondition(timeout > .zero)
    guard owned else { return nil }
    let deadline = ContinuousClock.now + timeout
    repeat {
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      if result == pid {
        owned = false
        return status
      }
      if result < 0, errno != EINTR {
        if errno == ECHILD { owned = false }
        return nil
      }
      if ContinuousClock.now >= deadline { return nil }
      usleep(1000)
    } while true
  }

  /// Kills and collects a still-owned child. An already collected child is
  /// successful cleanup; an unowned or reused PID is never signaled.
  public func terminate(timeout: Duration = .seconds(2), ) -> Bool {
    precondition(timeout > .zero)
    guard owned else { return true }
    let deadline = ContinuousClock.now + timeout
    var child = siginfo_t()
    var result: Int32
    repeat {
      result = waitid(P_PID, id_t(pid), &child, WEXITED | WNOHANG | WNOWAIT)
      if result >= 0 || errno != EINTR { break }
      if ContinuousClock.now >= deadline { return false }
    } while true
    if result < 0 {
      if errno == ECHILD {
        owned = false
        return true
      }
      return false
    }
    // Exclusive authority plus the noncollecting ownership check retains
    // this child's PID through signaling, even if it exits in between.
    if kill(pid, SIGKILL) < 0, errno != ESRCH { return false }
    let remaining = deadline - ContinuousClock.now
    guard remaining > .zero else { return false }
    return collect(timeout: remaining) != nil
  }
}
#endif
