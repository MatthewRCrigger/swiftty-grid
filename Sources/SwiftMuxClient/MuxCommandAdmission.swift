import SwiftMuxProtocol

/// Reserves command jobs and payload before dispatch and through wire replies.
final class MuxCommandAdmission: Sendable {
  static let maxJobs = 64
  static let maxBytes = 4 << 20
  typealias Reservation = MuxAdmissionBudget.Reservation
  private let budget = MuxAdmissionBudget(
    maxJobs: maxJobs,
    maxBytes: maxBytes,
    refusal: "client command buffer is full"
  )

  func reserve(_ command: MuxCommand) throws(MuxError) -> Reservation {
    try budget.reserve(Self.bytes(command))
  }
}
