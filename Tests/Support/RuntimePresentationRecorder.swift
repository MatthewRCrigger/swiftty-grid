import Synchronization

/// Counts installation results without retaining frames or result history.
/// Diagnostics read the current display, including after a refused frame.
public final class RuntimePresentationRecorder<Frame: Sendable>: Sendable {
  private struct Counts {
    var accepted = 0
    var refused = 0
    var last: Bool?
  }

  private let counts = Mutex(Counts())
  private let installFrame: @Sendable (Frame) -> Bool
  private let snapshot: @Sendable () -> [String]

  public init(
    install: @escaping @Sendable (Frame) -> Bool,
    snapshot: @escaping @Sendable () -> [String],
  ) {
    installFrame = install
    self.snapshot = snapshot
  }

  @discardableResult
  public func install(_ frame: Frame) -> Bool {
    let accepted = installFrame(frame)
    counts.withLock {
      if accepted { $0.accepted += 1 } else { $0.refused += 1 }
      $0.last = accepted
    }
    return accepted
  }

  public var resultCounts: (accepted: Int, refused: Int, last: Bool?) {
    counts.withLock { ($0.accepted, $0.refused, $0.last) }
  }

  public var summary: String {
    let counts = resultCounts
    let last = counts.last.map { String($0) } ?? "none"
    let heading =
      "installs: \(counts.accepted) accepted, "
      + "\(counts.refused) refused; last: \(last)\nframe:\n"
    // Only the displayed snapshot is inspected, never refused frame data.
    // Limit diagnostics before joining or copying arbitrarily long lines.
    let limit = 16 * 1024
    var bytes: [UInt8] = []
    for (index, line) in snapshot().enumerated() {
      if index > 0 {
        guard bytes.count < limit else {
          return heading + String(decoding: bytes, as: UTF8.self)
            + "\n[truncated]"
        }
        bytes.append(10)
      }
      let remaining = limit - bytes.count
      bytes.append(contentsOf: line.utf8.prefix(remaining + 1))
      if bytes.count > limit {
        bytes.removeLast()
        return heading + String(decoding: bytes, as: UTF8.self)
          + "\n[truncated]"
      }
    }
    return heading + String(decoding: bytes, as: UTF8.self)
  }
}
