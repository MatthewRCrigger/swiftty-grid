import Dispatch

extension MetalRenderer {
  /// Test seam: occupies every in-flight slot, as a stalled GPU would,
  /// after letting work already submitted finish (bounded to one second).
  /// Returns the number taken for `releaseInFlightSlots`.
  package func occupyInFlightSlots() -> Int {
    var taken = 0
    guard inFlight.wait(timeout: .now() + 1) == .success else { return 0 }
    taken = 1
    while inFlight.wait(timeout: .now()) == .success { taken += 1 }
    return taken
  }

  package func releaseInFlightSlots(_ count: Int) {
    for _ in 0 ..< count { inFlight.signal() }
  }
}
