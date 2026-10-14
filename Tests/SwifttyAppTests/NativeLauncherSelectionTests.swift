import Foundation
import Testing
import TestSupport

@MainActor
struct NativeLauncherSelectionTests {
  @Test
  func fixtureHonorsTheSelectedLauncher() throws {
    let environment = ProcessInfo.processInfo.environment
    let selected =
      try environment["SWIFTTY_EXPECTED_LAUNCHER"] ?? environment[
        "SWMUX_LAUNCHER"
      ] ?? NativeTestProducts.launcherPath(environment: [:])
    #expect(try MuxNativeTests.launcher() == selected)
  }
}
