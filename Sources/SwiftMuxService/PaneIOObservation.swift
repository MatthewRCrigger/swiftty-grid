/// Bounded, opt-in pane I/O evidence for owned test fixtures. Observers run
/// synchronously on the pane queue and must not wait or reenter the pane.
struct PaneIOObservation: Sendable {
  enum Phase: String, Sendable {
    case read, replyGenerated, replyQueued, replyDropped
    case written, writeBlocked, writeFailed
  }

  let phase: Phase
  let byteCount: Int
  /// At most 256 bytes, copied only when an observer is installed.
  let prefix: [UInt8]
  let error: Int32?
}
