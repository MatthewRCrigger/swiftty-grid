import SessionCore

/// Client-side holder of the newest complete screen (spec §6, §7.3;
/// spec §A.4.3). Only validated snapshots are installed, atomically, and
/// an older revision or attachment epoch never overwrites a newer screen.
public struct RemoteScreenStore: Sendable {
  public enum InstallResult: Equatable, Sendable {
    case installed(generation: UInt64)
    case stale
    case rejected(SnapshotValidationError)
  }

  public let sessionID: SessionID
  public private(set) var current: ScreenSnapshot?
  /// Lowest epoch accepted: raised by each `Attached`.
  public private(set) var minimumEpoch: UInt64 = 0
  /// Client-local, monotonically increasing; changes with every install
  /// and every fence, so a reconnect never looks like an unchanged frame.
  public private(set) var renderGeneration: UInt64 = 0

  public init(sessionID: SessionID) { self.sessionID = sessionID }

  /// A new attachment fences frames from older epochs.
  public mutating func fence(epoch: UInt64) {
    minimumEpoch = max(minimumEpoch, epoch)
    renderGeneration &+= 1
  }

  public mutating func install(_ snapshot: ScreenSnapshot) -> InstallResult {
    guard snapshot.sessionID == sessionID else {
      return .rejected(.wrongSession)
    }
    guard snapshot.attachmentEpoch >= minimumEpoch else { return .stale }
    do { try snapshot.validate() } catch { return .rejected(error) }
    if let current {
      guard snapshot.attachmentEpoch >= current.attachmentEpoch,
        snapshot.resizeRevision >= current.resizeRevision
      else { return .stale }
      if snapshot.attachmentEpoch == current.attachmentEpoch {
        guard snapshot.screenRevision > current.screenRevision else {
          return .stale
        }
      } else {
        guard snapshot.screenRevision >= current.screenRevision else {
          return .stale
        }
      }
    }
    current = snapshot
    renderGeneration &+= 1
    return .installed(generation: renderGeneration)
  }
}
