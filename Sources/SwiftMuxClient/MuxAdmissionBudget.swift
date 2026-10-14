import SwiftMuxProtocol
import Synchronization

/// Charges job and payload capacity until the last owned reservation retires.
final class MuxAdmissionBudget: Sendable {
  private let maxJobs: Int
  private let maxBytes: Int
  private let refusal: String
  private let state = Mutex((jobs: 0, bytes: 0))

  init(maxJobs: Int, maxBytes: Int, refusal: String) {
    precondition(maxJobs > 0 && maxBytes > 0)
    self.maxJobs = maxJobs
    self.maxBytes = maxBytes
    self.refusal = refusal
  }

  func reserve(_ bytes: Int) throws(MuxError) -> Reservation {
    let admitted = state.withLock { value in
      guard bytes >= 0, value.jobs < maxJobs, bytes <= maxBytes - value.bytes
      else { return false }
      value.jobs += 1
      value.bytes += bytes
      return true
    }
    guard admitted else { throw MuxError(.resourceLimit, refusal) }
    return Reservation(owner: self, bytes: bytes)
  }

  private func release(_ bytes: Int) {
    state.withLock {
      $0.jobs -= 1;
      $0.bytes -= bytes
    }
  }

  final class Reservation: Sendable {
    private let owner: MuxAdmissionBudget
    private let bytes: Int

    fileprivate init(owner: MuxAdmissionBudget, bytes: Int) {
      self.owner = owner
      self.bytes = bytes
    }

    deinit { owner.release(bytes) }
  }
}
