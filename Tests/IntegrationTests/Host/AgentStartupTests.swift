#if os(macOS)
import Darwin
import Foundation
import Testing
import TerminalHost

@Suite(.timeLimit(.minutes(1)))
struct AgentStartupTests {
  @Test(arguments: 0 ..< 7)
  func selectedConfigurationIsValidatedBeforeAnyServiceStartup(
    _ scenario: Int
  ) throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appendingPathComponent("missing.json")
    let valid = directory.appendingPathComponent("valid.json")
    let malformed = directory.appendingPathComponent("malformed.json")
    let launcher = directory.appendingPathComponent("missing-launcher")
    try JSONEncoder()
      .encode(
        HostConfiguration(
          bindAddress: "127.0.0.1",
          advertisedHost: "owned.example"
        )
      )
      .write(to: valid)
    try Data("{".utf8).write(to: malformed)
    let cases: [([String], Int32, URL?)] = [
      ([], 78, missing), (["--no-roaming"], 69, nil),
      (["--roaming-config", valid.path], 69, nil),
      (["--roaming-config", malformed.path], 78, malformed),
      (["--roaming-config", missing.path, "--no-roaming"], 69, nil),
      (["--no-roaming", "--roaming-config", missing.path], 78, missing),
      (["--no-roaming", "--roaming-config", valid.path], 69, nil),
    ]
    let (arguments, expectedStatus, rejected) = cases[scenario]
    let result = try runAgent(
      arguments: ["--launcher", launcher.path] + arguments,
      configuration: missing,
      directory: directory
    )
    #expect(result.status == expectedStatus)
    if let rejected {
      #expect(
        result.diagnostic.contains(
          "cannot read roaming configuration at \(rejected.path)"
        )
      )
      #expect(!result.diagnostic.contains("launcher not found"))
    } else {
      #expect(
        result.diagnostic.contains("launcher not found at \(launcher.path)")
      )
      #expect(!result.diagnostic.contains("cannot read roaming configuration"))
    }
  }

  private func agentURL() throws -> URL {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["SWIFTTY_AGENT_BINARY"] {
      return URL(fileURLWithPath: path)
    }
    if let path = environment["SWIFTTY_TEST_BUNDLE"] {
      var directory = URL(fileURLWithPath: path)
      for _ in 0 ..< 4 { directory.deleteLastPathComponent() }
      return directory.appendingPathComponent("swiftmux-agent")
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 4 { root.deleteLastPathComponent() }
    let binary = root.appendingPathComponent(".build/debug/swiftmux-agent")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    return binary
  }

  private func runAgent(
    arguments: [String],
    configuration: URL,
    directory: URL
  ) throws -> (status: Int32, diagnostic: String) {
    let output = directory.appendingPathComponent("stderr")
    try Data().write(to: output)
    let handle = try FileHandle(forWritingTo: output)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = try agentURL()
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment[HostConfiguration.environmentKey] = configuration.path
    environment["SWMUX_SERVICE"] = "owned.startup.\(UUID().uuidString)"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = handle
    try process.run()
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while process.isRunning, ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      process.terminate()
      let cleanup = ContinuousClock.now.advanced(by: .seconds(1))
      while process.isRunning, ContinuousClock.now < cleanup {
        Thread.sleep(forTimeInterval: 0.02)
      }
      if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw CocoaError(.executableRuntimeMismatch)
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit else {
      throw CocoaError(.executableRuntimeMismatch)
    }
    return (
      process.terminationStatus,
      String(decoding: try Data(contentsOf: output), as: UTF8.self)
    )
  }
}
#endif
