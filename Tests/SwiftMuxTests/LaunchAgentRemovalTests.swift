import Foundation
import SwiftMuxClient
import Testing

struct LaunchAgentRemovalTests {
  @Test
  func loadedServiceOrFailedProbePreservesPlist() {
    for (bootoutStatus, probeStatus, expected) in [
      (
        Int32(5), Int32(0),
        LaunchAgentRemoval.Failure.stillLoaded(bootoutStatus: 5),
      ), (0, 0, .stillLoaded(bootoutStatus: 0)),
      (5, 5, .cannotVerifyAbsence(status: 5)),
      (0, 125, .cannotVerifyAbsence(status: 125)),
    ] {
      var calls: [String] = []
      #expect(throws: expected) {
        try LaunchAgentRemoval.remove(
          bootout: {
            calls.append("bootout");
            return bootoutStatus
          },
          probe: {
            calls.append("probe");
            return probeStatus
          },
          removePlist: { calls.append("remove") },
        )
      }
      #expect(calls == ["bootout", "probe"])
    }
  }

  @Test
  func explicitAbsenceAllowsSuccessfulOrAlreadyUnloadedBootout() throws {
    for status: Int32 in [0, 3, 5] {
      var calls: [String] = []
      try LaunchAgentRemoval.remove(
        bootout: {
          calls.append("bootout");
          return status
        },
        probe: {
          calls.append("probe");
          return 113
        },
        removePlist: { calls.append("remove") },
      )
      #expect(calls == ["bootout", "probe", "remove"])
    }
  }

  @Test
  func realPlistRemovalAndRepeatedRemovalSucceed() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let plist = directory.appendingPathComponent("fixture.plist")
    try Data("fixture".utf8).write(to: plist)
    for _ in 0 ..< 2 {
      try LaunchAgentRemoval.remove(
        bootout: { 3 },
        probe: { 113 },
        removePlist: { try FileManager.default.removeItem(at: plist) },
      )
      #expect(!FileManager.default.fileExists(atPath: plist.path))
    }
  }

  @Test
  func filesystemErrorsAreNotIgnored() {
    for error in [
      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
      NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
      NSError(domain: NSPOSIXErrorDomain, code: 2),
    ] {
      var observed: NSError?
      do {
        try LaunchAgentRemoval.remove(
          bootout: { 0 },
          probe: { 113 },
          removePlist: { throw error },
        )
        Issue.record("filesystem failure reported success")
      } catch { observed = error as NSError }
      #expect(observed === error)
    }
  }

  @Test
  func commandLaunchErrorsStopFurtherWork() {
    enum Injected: Error { case launch }
    for failProbe in [false, true] {
      var calls: [String] = []
      #expect(throws: Injected.launch) {
        try LaunchAgentRemoval.remove(
          bootout: {
            calls.append("bootout")
            if !failProbe { throw Injected.launch }
            return 0
          },
          probe: {
            calls.append("probe");
            throw Injected.launch
          },
          removePlist: { calls.append("remove") },
        )
      }
      #expect(calls == (failProbe ? ["bootout", "probe"] : ["bootout"]))
    }
  }

  @Test
  func statusAcceptsOnlyLoadedOrExplicitAbsence() throws {
    #expect(try LaunchAgentRemoval.isLoaded(probeStatus: 0))
    #expect(try !LaunchAgentRemoval.isLoaded(probeStatus: 113))
    for status: Int32 in [-1, 1, 5, 125, 127] {
      #expect(
        throws: LaunchAgentRemoval.Failure.cannotVerifyAbsence(status: status)
      ) { try LaunchAgentRemoval.isLoaded(probeStatus: status) }
    }
  }

  @Test
  func unlinkIsIdempotentForRegularPlist() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let plist = directory.appendingPathComponent("fixture.plist")
    try Data("fixture".utf8).write(to: plist)
    try LaunchAgentRemoval.unlinkPlist(at: plist)
    try LaunchAgentRemoval.unlinkPlist(at: plist)
    #expect(!FileManager.default.fileExists(atPath: plist.path))
  }

  @Test
  func unlinkRefusesDirectoryAndPreservesAllContents() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let plist = directory.appendingPathComponent("fixture.plist")
    try FileManager.default.createDirectory(
      at: plist,
      withIntermediateDirectories: false,
    )
    let data = plist.appendingPathComponent("unrelated-user-file")
    try Data("preserved".utf8).write(to: data)
    #expect(throws: (any Error).self) {
      try LaunchAgentRemoval.unlinkPlist(at: plist)
    }
    #expect(try Data(contentsOf: data) == Data("preserved".utf8))
  }

  @Test
  func unlinkNeverFollowsLiveOrBrokenSymlinkTargets() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("target")
    try FileManager.default.createDirectory(
      at: target,
      withIntermediateDirectories: false,
    )
    let data = target.appendingPathComponent("user-file")
    try Data("preserved".utf8).write(to: data)
    let plist = directory.appendingPathComponent("fixture.plist")
    for destination in [
      target, directory.appendingPathComponent("missing-target"),
    ] {
      try FileManager.default.createSymbolicLink(
        at: plist,
        withDestinationURL: destination,
      )
      try LaunchAgentRemoval.unlinkPlist(at: plist)
      #expect(throws: (any Error).self) {
        try FileManager.default.attributesOfItem(atPath: plist.path)
      }
      #expect(try Data(contentsOf: data) == Data("preserved".utf8))
    }
  }

  @Test
  func nonfileAndNulPathsCannotUnlinkAliasedFile() throws {
    #expect(throws: LaunchAgentRemoval.Failure.invalidPlistPath) {
      try LaunchAgentRemoval.unlinkPlist(
        at: #require(URL(string: "https://example.test/fixture.plist")),
      )
    }
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let real = directory.appendingPathComponent("fixture.plist")
    try Data("preserved".utf8).write(to: real)
    var remote = try #require(
      URLComponents(url: real, resolvingAgainstBaseURL: false, )
    )
    remote.host = "remote.example.test"
    #expect(throws: LaunchAgentRemoval.Failure.invalidPlistPath) {
      try LaunchAgentRemoval.unlinkPlist(at: #require(remote.url))
    }
    #expect(try Data(contentsOf: real) == Data("preserved".utf8))
    let invalid = URL(fileURLWithPath: real.path + "\0extra")
    #expect(invalid.path(percentEncoded: true).contains("%00"))
    #expect(throws: LaunchAgentRemoval.Failure.invalidPlistPath) {
      try LaunchAgentRemoval.unlinkPlist(at: invalid)
    }
    #expect(try Data(contentsOf: real) == Data("preserved".utf8))
    let literal = directory.appendingPathComponent("literal%00.plist")
    try Data("fixture".utf8).write(to: literal)
    var local = try #require(
      URLComponents(url: literal, resolvingAgainstBaseURL: false, )
    )
    local.host = "localhost"
    try LaunchAgentRemoval.unlinkPlist(at: #require(local.url))
    #expect(!FileManager.default.fileExists(atPath: literal.path))
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
    )
    return directory
  }
}
