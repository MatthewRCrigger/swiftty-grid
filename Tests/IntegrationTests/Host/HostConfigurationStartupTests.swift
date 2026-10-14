#if os(macOS)
import Darwin
import Foundation
import Testing

@testable import TerminalHost

@Suite(.timeLimit(.minutes(1)))
struct HostConfigurationStartupTests {
  @Test
  func onlyAnAbsentOptionalConfigurationDisablesRoaming() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("missing.json")
    #expect(
      try HostConfiguration.loadForStartup(from: file, required: false) == nil
    )
    #expect(throws: POSIXError(.ENOENT)) {
      try HostConfiguration.loadForStartup(from: file, required: true)
    }
    #expect(
      try HostConfiguration.loadForStartup(from: nil, required: true) == nil
    )
  }

  @Test(arguments: [false, true])
  func validSelectionsLoadBeforeStartup(_ required: Bool) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    let configuration = HostConfiguration(
      bindAddress: "127.0.0.1",
      advertisedHost: "owned.example",
      stateDirectory: directory.path
    )
    try JSONEncoder().encode(configuration).write(to: file)
    #expect(
      try HostConfiguration.loadForStartup(from: file, required: required)
        == configuration
    )
  }

  @Test(arguments: [false, true])
  func malformedOversizedAndNonregularSelectionsNeverDisableRoaming(
    _ required: Bool
  ) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    try Data("{".utf8).write(to: file)
    #expect(throws: DecodingError.self) {
      try HostConfiguration.loadForStartup(from: file, required: required)
    }
    try Data(repeating: 32, count: 64 * 1024 + 1).write(to: file)
    #expect(throws: CocoaError(.fileReadTooLarge)) {
      try HostConfiguration.loadForStartup(from: file, required: required)
    }
    #expect(throws: POSIXError(.EINVAL)) {
      try HostConfiguration.loadForStartup(from: directory, required: required)
    }
    #expect(
      try HostConfiguration.loadForStartup(from: nil, required: required) == nil
    )
  }

  @Test(arguments: [false, true])
  func unreadableSelectionsNeverDisableRoaming(_ required: Bool) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("config.json")
    try Data("{}".utf8).write(to: file)
    #expect(chmod(file.path, 0) == 0)
    defer { _ = chmod(file.path, 0o600) }
    #expect(throws: POSIXError(.EACCES)) {
      try HostConfiguration.loadForStartup(from: file, required: required)
    }
  }
}
#endif
