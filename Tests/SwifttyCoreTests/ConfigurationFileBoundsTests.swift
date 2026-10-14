import Foundation
@testable import SwifttyCore
import Testing

struct ConfigurationFileBoundsTests {
  private func withDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }

  private func padded(_ text: String, to bytes: Int) -> Data {
    var data = Data(text.utf8)
    data.append(Data(repeating: 0x20, count: bytes - data.count))
    return data
  }

  @Test
  func themeLimitAcceptsBoundaryAndRejectsOneExcessByte() throws {
    try withDirectory { directory in
      let file = directory.appendingPathComponent("Night")
      try padded("background=#123456\n#", to: Themes.maxFileBytes)
        .write(to: file)
      #expect(
        Themes.colors(named: file.path, searching: [])?.background == 0x123456
      )
      try padded("background=#123456\n#", to: Themes.maxFileBytes + 1)
        .write(to: file)
      #expect(Themes.colors(named: file.path, searching: []) == nil)
      #expect(Themes.colors(named: "Night", searching: [directory]) == nil)
    }
  }

  @Test
  func rootAndOptionalIncludeRejectOversizedFilesBeforeApplyingTheirSettings()
    throws
  {
    try withDirectory { directory in
      let file = directory.appendingPathComponent("large")
      try padded("font-size=22\n#", to: Configuration.maxFileBytes + 1)
        .write(to: file)
      let root = Configuration.load(from: file)
      #expect(root.fontSize == Configuration().fontSize)
      #expect(root.diagnostics.count == 1)
      let included = Configuration.parse(
        "font-size=19\nconfig-file=?large",
        directory: directory
      )
      #expect(included.fontSize == 19)
      #expect(included.diagnostics.count == 1)
      try padded("font-size=22\n#", to: Configuration.maxFileBytes)
        .write(to: file)
      #expect(Configuration.load(from: file).fontSize == 22)
      #expect(Configuration.load(from: file).diagnostics.isEmpty)
    }
  }

  @Test
  func cumulativeBytesPreserveEarlierSettingsAndRejectNextFile() throws {
    try withDirectory { directory in
      let root = directory.appendingPathComponent("root")
      let rootText = (0 ..< 5).map { "config-file=\($0)\n" }.joined()
      try Data(rootText.utf8).write(to: root)
      for index in 0 ..< 4 {
        let count =
          index == 3
          ? Configuration.maxFileBytes - rootText.utf8.count
          : Configuration.maxFileBytes
        try padded("font-size=\(22 + index)\n#", to: count)
          .write(to: directory.appendingPathComponent(String(index)))
      }
      try Data("font-size=26".utf8)
        .write(to: directory.appendingPathComponent("4"))
      let loaded = Configuration.load(from: root)
      #expect(loaded.fontSize == 25)
      #expect(loaded.diagnostics.count == 1)
    }
  }

  @Test
  func wideIncludeQueueHasOneLimitDiagnosticAndRetainsOrderedOverrides() throws
  {
    try withDirectory { directory in
      let root = directory.appendingPathComponent("root")
      let text = (0 ..< Configuration.maxLoadedFiles)
        .map { "config-file=\($0)\n" }.joined()
      try Data(text.utf8).write(to: root)
      for index in 0 ..< Configuration.maxLoadedFiles {
        try Data("font-size=\(20 + index)".utf8)
          .write(to: directory.appendingPathComponent(String(index)))
      }
      let loaded = Configuration.load(from: root)
      #expect(loaded.fontSize == Double(20 + Configuration.maxLoadedFiles - 2))
      #expect(loaded.diagnostics.count == 1)
    }
  }

  @Test
  func failedDecodesStillConsumeTheAggregateReadBudget() throws {
    try withDirectory { directory in
      let invalid = Data(repeating: 0xFF, count: Configuration.maxFileBytes)
      for index in 0 ..< 4 {
        try invalid.write(to: directory.appendingPathComponent("bad\(index)"))
      }
      try Data("font-size=22".utf8)
        .write(to: directory.appendingPathComponent("tail"))
      let text =
        "font-size=19\n" + (0 ..< 4).map { "config-file=?bad\($0)\n" }.joined()
        + "config-file=tail"
      let config = Configuration.parse(text, directory: directory)
      #expect(config.fontSize == 19)
      #expect(config.diagnostics.count == 5)
      #expect(config.diagnostics.last?.contains("byte budget exceeded") == true)
    }
  }

  @Test
  func clearingPendingIncludesCannotResetProcessedFileCredit() throws {
    try withDirectory { directory in
      for index in 0 ... Configuration.maxLoadedFiles {
        let text =
          "font-size=\(20 + index)\nconfig-file=\nconfig-file=\(index + 1)"
        try Data(text.utf8)
          .write(to: directory.appendingPathComponent(String(index)))
      }
      let loaded = Configuration.load(
        from: directory.appendingPathComponent("0")
      )
      #expect(loaded.fontSize == Double(19 + Configuration.maxLoadedFiles))
      #expect(loaded.diagnostics.count == 1)
      #expect(loaded.diagnostics.first?.contains("file limit") == true)
    }
  }

  @Test
  func invalidIncludeCannotClaimTheCanonicalIdentityOfAValidFile() throws {
    try withDirectory { directory in
      try Data("font-size=22".utf8)
        .write(to: directory.appendingPathComponent("valid"))
      let config = Configuration.parse(
        "config-file=valid\0other\nconfig-file=valid",
        directory: directory
      )
      #expect(config.fontSize == 22)
      #expect(config.diagnostics.count == 1)
      #expect(config.diagnostics.first?.contains("cannot read") == true)
    }
  }
}
