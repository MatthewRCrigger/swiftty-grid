import Synchronization

/// A lazy byte collection that exposes how much input a parser reads.
public final class ReadCountingBytes: Collection, Sendable {
  public let count: Int
  private let prefix: [UInt8]
  private let reads = Mutex(0)

  public init(prefix: [UInt8], count: Int) {
    precondition(count >= prefix.count)
    self.prefix = prefix
    self.count = count
  }

  public var elementReads: Int { reads.withLock { $0 } }
  public var startIndex: Int { 0 }
  public var endIndex: Int { count }
  public func index(after index: Int) -> Int { index + 1 }
  public subscript(index: Int) -> UInt8 {
    precondition(index >= 0 && index < count)
    reads.withLock { $0 += 1 }
    return index < prefix.count ? prefix[index] : 0
  }
}
