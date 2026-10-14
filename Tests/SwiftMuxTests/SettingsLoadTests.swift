import Foundation
import SwiftMuxProtocol
@testable import SwiftMuxTerminal
import Testing

@Suite
struct SettingsLoadTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
    return url
  }

  @Test
  func aMissingFileKeepsDefaults() throws {
    let url = try directory().appendingPathComponent("settings.json")
    defer {
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    let settings = try Settings.load(from: url)
    #expect(settings == Settings())
  }

  @Test
  func aDirectoryIsNotTreatedAsDefaults() throws {
    let url = try directory()
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: SettingsError.self) { try Settings.load(from: url) }
  }

  @Test
  func anUnreadableFileIsNotTreatedAsDefaults() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0],
      ofItemAtPath: url.path
    )
    #expect(throws: SettingsError.self) { try Settings.load(from: url) }
  }

  @Test
  func anOversizedFileFailsWithoutAcceptingIt() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    try Data(count: (64 << 10) + 1).write(to: url)
    do {
      _ = try Settings.load(from: url)
      Issue.record("oversized settings were accepted")
    } catch let error as SettingsError {
      #expect(error.description == "settings file too large")
    }
  }

  @Test
  func malformedJSONFailsInsteadOfFallingBack() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")
    try Data("{".utf8).write(to: url)
    #expect(throws: SettingsError.self) { try Settings.load(from: url) }
  }
}
