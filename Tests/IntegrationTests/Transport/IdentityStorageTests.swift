#if os(macOS)
import Darwin
import Foundation
import Testing

@testable import AppleTransport

private struct OwnedIdentityFixture {
  let base: URL
  let directory: URL
  let identity: HostIdentity

  init() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "identity-storage-" + UUID().uuidString
    )
    try FileManager.default.createDirectory(
      at: base,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    directory = base.appendingPathComponent("tls")
    do {
      identity = try HostIdentity.loadOrCreate(
        directory: directory,
        hostnames: ["owned.example"]
      )
    } catch {
      try? FileManager.default.removeItem(at: base)
      throw error
    }
  }

  func url(_ file: HostIdentityStorage.File) -> URL {
    directory.appendingPathComponent(file.name)
  }

  func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Suite(.timeLimit(.minutes(1)))
struct IdentityStorageTests {
  @Test(
    arguments: [HostIdentityStorage.File.key, .certificate],
    ["short", "excess", "directory", "symlink", "permissions"]
  )
  func invalidFilesAreRejectedBeforeReading(
    _ file: HostIdentityStorage.File,
    _ fault: String
  ) throws {
    let fixture = try OwnedIdentityFixture()
    defer { fixture.cleanup() }
    let storage = try HostIdentityStorage(directory: fixture.directory)
    let url = fixture.url(file)
    let error: HostIdentityError
    switch fault {
    case "short", "excess":
      let count =
        fault == "short"
        ? file.byteRange.lowerBound - 1 : file.byteRange.upperBound + 1
      try Data(repeating: 7, count: count).write(to: url)
      error = .storage("invalid size " + file.name)
    case "directory":
      try FileManager.default.removeItem(at: url)
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      error = .insecureStorage(file.name)
    case "symlink":
      let target = fixture.base.appendingPathComponent("alias-target")
      try FileManager.default.moveItem(at: url, to: target)
      try FileManager.default.createSymbolicLink(
        at: url,
        withDestinationURL: target
      )
      error = .insecureStorage(file.name)
    default:
      try #require(chmod(url.path, 0o644) == 0)
      error = .insecureStorage(file.name)
    }
    var reachedRead = false
    #expect(throws: error) { try storage.read(file) { reachedRead = true } }
    #expect(!reachedRead)
    #expect(throws: error) {
      try HostIdentity.load(directory: fixture.directory)
    }
  }

  @Test(arguments: [HostIdentityStorage.File.key, .certificate])
  func fifoRefusalAndReplacementNeverWaitForAWriter(
    _ file: HostIdentityStorage.File
  ) throws {
    let fixture = try OwnedIdentityFixture()
    defer { fixture.cleanup() }
    let url = fixture.url(file)
    try FileManager.default.removeItem(at: url)
    try #require(mkfifo(url.path, 0o600) == 0)
    // A finite keeper lets a regressed blocking reader reach EOF promptly.
    let keeper = open(url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
    try #require(keeper >= 0)
    let completion = DispatchGroup()
    completion.enter()
    DispatchQueue.global()
      .asyncAfter(deadline: .now() + .milliseconds(100)) {
        close(keeper)
        completion.leave()
      }
    defer { completion.wait() }
    #expect(throws: HostIdentityError.insecureStorage(file.name)) {
      try HostIdentity.load(directory: fixture.directory)
    }
    let replacement = try HostIdentity.loadOrCreate(
      directory: fixture.directory,
      hostnames: ["owned.example"]
    )
    #expect(replacement.certificateDER != fixture.identity.certificateDER)
    #expect(
      try HostIdentity.load(directory: fixture.directory).certificateDER
        == replacement.certificateDER
    )
    var info = stat()
    try #require(lstat(url.path, &info) == 0)
    #expect(info.st_mode & S_IFMT == S_IFREG)
    #expect(info.st_mode & 0o777 == 0o600)
  }

  @Test(
    arguments: [HostIdentityStorage.File.key, .certificate],
    ["grow", "shrink", "replace"]
  )
  func readsRemainBoundedAndUseTheValidatedDescriptor(
    _ file: HostIdentityStorage.File,
    _ change: String
  ) throws {
    let fixture = try OwnedIdentityFixture()
    defer { fixture.cleanup() }
    let storage = try HostIdentityStorage(directory: fixture.directory)
    let original = Data(repeating: 7, count: file.byteRange.upperBound)
    try storage.write(original, to: file)
    let url = fixture.url(file)
    let changeFile = {
      if change == "replace" {
        let retained = fixture.base.appendingPathComponent("retained")
        try FileManager.default.moveItem(at: url, to: retained)
        let target = fixture.base.appendingPathComponent("replacement")
        try Data([9]).write(to: target)
        try FileManager.default.createSymbolicLink(
          at: url,
          withDestinationURL: target
        )
      } else {
        let data = change == "grow" ? original + Data([8]) : Data()
        try data.write(to: url)
      }
    }
    if change == "replace" {
      #expect(
        try storage.read(file, afterValidationForTesting: changeFile)
          == original
      )
      #expect(throws: HostIdentityError.insecureStorage(file.name)) {
        try storage.read(file)
      }
    } else {
      #expect(throws: HostIdentityError.storage("invalid size " + file.name)) {
        try storage.read(file, afterValidationForTesting: changeFile)
      }
    }
  }

  @Test(arguments: ["permissions", "symlink", "file"])
  func directoryMustBeOwnerOnlyAndActuallyADirectory(_ fault: String) throws {
    let fixture = try OwnedIdentityFixture()
    defer { fixture.cleanup() }
    if fault == "permissions" {
      try #require(chmod(fixture.directory.path, 0o755) == 0)
    } else {
      let retained = fixture.base.appendingPathComponent("retained")
      try FileManager.default.moveItem(at: fixture.directory, to: retained)
      if fault == "symlink" {
        try FileManager.default.createSymbolicLink(
          at: fixture.directory,
          withDestinationURL: retained
        )
      } else {
        try Data([7]).write(to: fixture.directory)
      }
    }
    let error = HostIdentityError.insecureStorage("tls")
    #expect(throws: error) {
      try HostIdentity.load(directory: fixture.directory)
    }
    #expect(throws: error) {
      try HostIdentity.loadOrCreate(directory: fixture.directory)
    }
  }

  @Test
  func readsAndWritesStayWithinTheOpenedDirectory() throws {
    let fixture = try OwnedIdentityFixture()
    defer { fixture.cleanup() }
    let storage = try HostIdentityStorage(directory: fixture.directory)
    let retired = fixture.base.appendingPathComponent("retired")
    try FileManager.default.moveItem(at: fixture.directory, to: retired)
    let replacementDirectory = fixture.base.appendingPathComponent(
      "replacement"
    )
    let replacement = try HostIdentity.loadOrCreate(
      directory: replacementDirectory,
      hostnames: ["replacement.example"]
    )
    try FileManager.default.createSymbolicLink(
      at: fixture.directory,
      withDestinationURL: replacementDirectory
    )
    #expect(try storage.read(.certificate) == fixture.identity.certificateDER)
    try storage.write(replacement.certificateDER, to: .certificate)
    let retiredStorage = try HostIdentityStorage(directory: retired)
    #expect(try retiredStorage.read(.certificate) == replacement.certificateDER)
    #expect(
      try HostIdentity.load(directory: replacementDirectory).certificateDER
        == replacement.certificateDER
    )
    #expect(throws: HostIdentityError.insecureStorage("tls")) {
      try HostIdentity.load(directory: fixture.directory)
    }
  }

  @Test(arguments: [HostIdentityStorage.File.key, .certificate])
  func invalidWritesLeaveTheCurrentIdentityAndNoTemporaryFiles(
    _ file: HostIdentityStorage.File
  ) throws {
    let fixture = try OwnedIdentityFixture()
    defer { fixture.cleanup() }
    let storage = try HostIdentityStorage(directory: fixture.directory)
    for count in [file.byteRange.lowerBound - 1, file.byteRange.upperBound + 1]
    {
      #expect(throws: HostIdentityError.storage("invalid size " + file.name)) {
        try storage.write(Data(repeating: 7, count: count), to: file)
      }
    }
    #expect(
      try HostIdentity.load(directory: fixture.directory).certificateDER
        == fixture.identity.certificateDER
    )
    let files = try FileManager.default.contentsOfDirectory(
      atPath: fixture.directory.path
    )
    #expect(Set(files) == [HostIdentity.keyFile, HostIdentity.certificateFile])
  }

  @Test
  func oversizedGeneratedCertificateCannotReplaceTheCurrentIdentity() throws {
    let fixture = try OwnedIdentityFixture()
    defer { fixture.cleanup() }
    let names = (0 ..< 512)
      .map {
        String(repeating: "a", count: 60) + "."
          + String(repeating: "b", count: 60) + ".\($0).example"
      }
    #expect(throws: HostIdentityError.certificateEncoding) {
      try HostIdentity.generate(hostnames: names)
    }
    #expect(throws: HostIdentityError.certificateEncoding) {
      try HostIdentity.loadOrCreate(
        directory: fixture.directory,
        hostnames: names
      )
    }
    #expect(
      try HostIdentity.load(directory: fixture.directory).certificateDER
        == fixture.identity.certificateDER
    )
  }
}
#endif
