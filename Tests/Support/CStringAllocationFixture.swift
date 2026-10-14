#if canImport(Darwin)
import Darwin

/// Per-call failure injection. Owns a fallback for copies an incorrect
/// implementation forgot to free; assertions separately check liveCount.
public final class CStringAllocationFixture {
  private let failingAt: Int?
  private let failingString: String?
  private var live: [UInt: UnsafeMutablePointer<CChar>] = [:]
  public private(set) var attempts = 0
  public private(set) var allocations = 0
  public private(set) var frees = 0
  public private(set) var invalidFrees = 0
  public var liveCount: Int { live.count }

  public init(failingAt: Int? = nil, failingString: String? = nil) {
    self.failingAt = failingAt
    self.failingString = failingString
  }

  deinit { for pointer in live.values { free(pointer) } }

  public func copy(_ string: String) -> UnsafeMutablePointer<CChar>? {
    let index = attempts
    attempts += 1
    if index == failingAt || string == failingString {
      errno = EIO  // Verify that the caller explicitly reports ENOMEM.
      return nil
    }
    guard let pointer = strdup(string) else { return nil }
    allocations += 1
    live[UInt(bitPattern: pointer)] = pointer
    return pointer
  }

  public func release(_ pointer: UnsafeMutablePointer<CChar>) {
    guard live.removeValue(forKey: UInt(bitPattern: pointer)) != nil else {
      invalidFrees += 1
      return
    }
    frees += 1
    free(pointer)
  }
}
#endif
