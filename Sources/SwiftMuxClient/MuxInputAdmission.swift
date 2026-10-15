import SwiftMuxProtocol

/// Charges accepted jobs through dispatch, pane queues and admission ACKs.
final class MuxInputAdmission: Sendable {
  static let maxJobs = 256
  static let maxBytes = 4 << 20
  typealias Reservation = MuxAdmissionBudget.Reservation
  private let budget = MuxAdmissionBudget(
    maxJobs: maxJobs,
    maxBytes: maxBytes,
    refusal: "client input buffer is full"
  )

  static func bytes(_ input: MuxInput) -> Int {
    switch input {
    case let .text(text), let .paste(text): text.utf8.count
    case .key, .focus, .mouse: 32
    case .moveCursor: MuxInput.moveCursorBytes
    }
  }

  func reserve(_ bytes: Int) throws(MuxError) -> Reservation {
    try budget.reserve(bytes)
  }
}
