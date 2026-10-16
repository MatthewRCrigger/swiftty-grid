import Foundation
import SwiftUI

/// Test-only hooks for the XCUITest suite in Tests/AppUITests, active only
/// when the app is launched with the `-ui-testing` argument. They change no
/// behaviour: they isolate on-disk state and expose the visible terminal
/// text to UI automation.
public enum UITesting {
  /// Whether the app was launched by the UI test suite.
  public static let isEnabled = ProcessInfo.processInfo.arguments.contains("-ui-testing")

  /// A fresh, empty state directory for this launch (saved hosts, trusted
  /// keys, transfer manifests), so tests never see or touch real app data.
  static let storageDirectory: URL? = {
    guard isEnabled else { return nil }
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "Swiftty-UITests", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: directory)
    return directory
  }()

  /// A separate, cleared defaults domain for remembered session ids.
  /// (`UserDefaults` is thread-safe; it is just not marked `Sendable`.)
  nonisolated(unsafe) public static let defaults: UserDefaults? = {
    guard isEnabled else { return nil }
    let suite = "dev.swiftty.roaming.ui-testing"
    let defaults = UserDefaults(suiteName: suite)
    defaults?.removePersistentDomain(forName: suite)
    return defaults
  }()
}

extension View {
  /// Under `-ui-testing`, overlays an invisible accessibility element
  /// `terminal.screen` whose value is the visible terminal text. UIKit's
  /// terminal only builds screen text for VoiceOver, which UI tests don't
  /// run.
  @ViewBuilder
  func uiTestingScreenProbe(_ model: TerminalScreenModel) -> some View {
    if UITesting.isEnabled {
      overlay(alignment: .topLeading) { ScreenTextProbe(model: model) }
    } else {
      self
    }
  }
}

private struct ScreenTextProbe: View {
  let model: TerminalScreenModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
      let text = (model.previewLines?() ?? []).joined(separator: "\n")
      Color.clear
        .frame(width: 2, height: 2)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Terminal screen")
        .accessibilityValue(text)
        .accessibilityIdentifier("terminal.screen")
    }
  }
}
