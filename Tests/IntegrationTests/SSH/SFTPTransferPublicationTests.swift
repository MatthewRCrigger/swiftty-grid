import Darwin
import Foundation
import SessionCore
import Testing

@testable import SSHClient

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SFTPTransferPublicationTests {
  @Test(
    arguments: [TransferManifest.Direction.upload, .download],
    ["offset", "negative-restart"]
  )
  func invalidProgressIsRejectedBeforeIO(
    _ direction: TransferManifest.Direction,
    _ field: String
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, bytes) = try fixture.sourceFile(size: 4)
    let destination = fixture.local.appendingPathComponent("destination")
    var manifest: TransferManifest
    if direction == .upload {
      manifest = try await SFTPTransfers.prepareUpload(
        source: source,
        remotePath: "/destination",
        stagingDirectory: fixture.staging
      )
    } else {
      try fixture.remoteFile("/source", data: bytes)
      manifest = try SFTPTransfers.prepareDownload(
        remotePath: "/source",
        temporaryDirectory: fixture.local,
        destination: destination
      )
      manifest.sourceSize = 4
      try bytes.write(to: URL(fileURLWithPath: manifest.localPath))
    }
    if field == "offset" {
      manifest.acknowledgedOffset = 5
    } else {
      manifest.restartCount = -1
    }
    #expect(throws: EncodingError.self) { try manifest.encoded() }
    let invalidData = try JSONEncoder().encode(manifest)
    #expect(throws: DecodingError.self) {
      try TransferManifest.decode(invalidData)
    }
    let original = manifest
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let requestsBefore = fixture.server.state.sftpRequests.withLock { $0 }
    await #expect(throws: SFTPTransferError.invalidManifest) {
      if direction == .upload {
        try await SFTPTransfers.upload(&manifest, client: client)
      } else {
        try await SFTPTransfers.download(&manifest, client: client)
      }
    }
    #expect(manifest == original)
    #expect(fixture.server.state.sftpRequests.withLock { $0 } == requestsBefore)
    #expect(
      (try? Data(contentsOf: URL(fileURLWithPath: original.localPath))) == bytes
    )
    await connection.close()
    await fixture.cleanup()
  }

  @Test
  func downloadRejectsAnOverflowingRestartCountBeforeTruncation() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/source", data: Data([1, 2, 3, 4]))
    let destination = fixture.local.appendingPathComponent("destination")
    let original = Data("protected".utf8)
    try original.write(to: destination)
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination,
      overwriteExisting: true
    )
    manifest.restartCount = Int.max
    #expect(try TransferManifest.decode(manifest.encoded()) == manifest)
    let stage = URL(fileURLWithPath: manifest.localPath)
    let changed = Data([5, 6, 7, 8])
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.invalidManifest) {
      try await SFTPTransfers.download(&manifest, client: client) { value in
        guard value.state == .verifying else { return }
        do { try changed.write(to: stage) } catch { Issue.record(error) }
      }
    }
    #expect(try Data(contentsOf: stage) == changed)
    #expect(try Data(contentsOf: destination) == original)
    #expect(manifest.restartCount == Int.max)
    #expect(!manifest.isComplete)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: [Int.max - 1, Int.max])
  func resumedUploadChecksRestartCountBeforeChangingTemporary(
    _ count: Int
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, bytes) = try fixture.sourceFile(size: 4)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/destination",
      stagingDirectory: fixture.staging
    )
    let temporary = manifest.remoteTemporaryPath!
    let retained = Data([bytes[0] ^ 0xFF])
    try fixture.remoteFile(temporary, data: retained)
    manifest.acknowledgedOffset = 1
    manifest.state = .transferring
    manifest.restartCount = count
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    if count == Int.max {
      await #expect(throws: SFTPTransferError.invalidManifest) {
        try await SFTPTransfers.upload(&manifest, client: client)
      }
      #expect(fixture.remoteData(temporary) == retained)
      #expect(fixture.remoteData("/destination") == nil)
      #expect(manifest.remoteTemporaryPath == temporary)
      #expect(!manifest.isComplete)
    } else {
      try await SFTPTransfers.upload(&manifest, client: client)
      #expect(fixture.remoteData("/destination") == bytes)
      #expect(manifest.isComplete)
    }
    #expect(manifest.restartCount == Int.max)
    #expect(try TransferManifest.decode(manifest.encoded()) == manifest)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(
    arguments: [TransferManifest.Direction.upload, .download],
    [false, true]
  )
  func localStagePathsRejectEmbeddedNUL(
    _ direction: TransferManifest.Direction,
    _ discard: Bool
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    var manifest: TransferManifest
    if direction == .upload {
      let (source, _) = try fixture.sourceFile(size: 4)
      manifest = try await SFTPTransfers.prepareUpload(
        source: source,
        remotePath: "/destination",
        stagingDirectory: fixture.staging
      )
    } else {
      try fixture.remoteFile("/source", data: Data([1, 2, 3, 4]))
      manifest = try SFTPTransfers.prepareDownload(
        remotePath: "/source",
        temporaryDirectory: fixture.local,
        destination: fixture.local.appendingPathComponent("destination")
      )
      try Data("protected".utf8)
        .write(to: URL(fileURLWithPath: manifest.localPath))
    }
    let stage = URL(fileURLWithPath: manifest.localPath)
    let original = try Data(contentsOf: stage)
    manifest.localPath += "\u{0}ignored"
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let requestsBefore = fixture.server.state.sftpRequests.withLock { $0 }
    if discard {
      await SFTPTransfers.discard(manifest, client: client)
    } else {
      await #expect(throws: SFTPTransferError.invalidManifest) {
        if direction == .upload {
          try await SFTPTransfers.upload(&manifest, client: client)
        } else {
          try await SFTPTransfers.download(&manifest, client: client)
        }
      }
      #expect(
        fixture.server.state.sftpRequests.withLock { $0 } == requestsBefore
      )
    }
    #expect((try? Data(contentsOf: stage)) == original)
    #expect(!manifest.isComplete)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: [false, true])
  func localDestinationPathsRejectEmbeddedNUL(_ discard: Bool) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/source", data: Data([1, 2, 3, 4]))
    let destination = fixture.local.appendingPathComponent("destination")
    let original = Data("protected".utf8)
    try original.write(to: destination)
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination,
      overwriteExisting: true
    )
    let stage = URL(fileURLWithPath: manifest.localPath)
    try original.write(to: stage)
    manifest.localDestinationPath! += "\u{0}ignored"
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let requestsBefore = fixture.server.state.sftpRequests.withLock { $0 }
    if discard {
      await SFTPTransfers.discard(manifest, client: client)
    } else {
      await #expect(throws: SFTPTransferError.invalidManifest) {
        try await SFTPTransfers.download(&manifest, client: client)
      }
    }
    #expect(fixture.server.state.sftpRequests.withLock { $0 } == requestsBefore)
    #expect((try? Data(contentsOf: stage)) == original)
    #expect(try Data(contentsOf: destination) == original)
    #expect(!manifest.isComplete)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: [TransferManifest.Direction.upload, .download])
  func verificationCloseFailurePreventsPublication(
    _ direction: TransferManifest.Direction
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let original = Data("protected".utf8)
    let destination = fixture.local.appendingPathComponent("destination")
    var manifest: TransferManifest
    if direction == .upload {
      let (source, _) = try fixture.sourceFile(size: 4)
      try fixture.remoteFile("/destination", data: original)
      manifest = try await SFTPTransfers.prepareUpload(
        source: source,
        remotePath: "/destination",
        stagingDirectory: fixture.staging,
        overwriteExisting: true
      )
    } else {
      try fixture.remoteFile("/source", data: Data([1, 2, 3, 4]))
      try original.write(to: destination)
      manifest = try SFTPTransfers.prepareDownload(
        remotePath: "/source",
        temporaryDirectory: fixture.local,
        destination: destination,
        overwriteExisting: true
      )
    }
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    let checkpoint: TransferCheckpoint = { value in
      guard value.state == .verifying else { return }
      fixture.server.state.faults.withLock { $0.rejectNextClose = true }
    }
    await #expect(throws: SFTPTransferError.closeFailed) {
      if direction == .upload {
        try await SFTPTransfers.upload(
          &manifest,
          client: client,
          checkpoint: checkpoint
        )
      } else {
        try await SFTPTransfers.download(
          &manifest,
          client: client,
          checkpoint: checkpoint
        )
      }
    }
    let retained =
      direction == .upload
      ? fixture.remoteData("/destination") : try Data(contentsOf: destination)
    #expect(retained == original)
    #expect(!manifest.isComplete)
    #expect(FileManager.default.fileExists(atPath: manifest.localPath))
    #expect(fixture.server.state.sftpOpenHandles.withLock { $0 } == 0)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: [false, true], [false, true])
  func downloadDoesNotOverwriteADestinationDirectory(
    _ populated: Bool,
    _ createAtCheckpoint: Bool
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/source", data: Data([1, 2, 3, 4]))
    let destination = fixture.local.appendingPathComponent("destination")
    let child = destination.appendingPathComponent("protected")
    let original = Data("protected".utf8)
    let createDirectory: @Sendable () throws -> Void = {
      try FileManager.default.createDirectory(
        at: destination,
        withIntermediateDirectories: true
      )
      if populated { try original.write(to: child) }
    }
    if !createAtCheckpoint { try createDirectory() }
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/source",
      temporaryDirectory: fixture.local,
      destination: destination,
      overwriteExisting: true
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.notRegularFile) {
      try await SFTPTransfers.download(&manifest, client: client) {
        checkpoint in
        guard createAtCheckpoint, checkpoint.state == .verifying else { return }
        do { try createDirectory() } catch { Issue.record(error) }
      }
    }
    var info = Darwin.stat()
    #expect(lstat(destination.path, &info) == 0)
    #expect(info.st_mode & S_IFMT == S_IFDIR)
    if populated { #expect(try Data(contentsOf: child) == original) }
    #expect(!manifest.isComplete)
    #expect(FileManager.default.fileExists(atPath: manifest.localPath))
    await connection.close()
    await fixture.cleanup()
  }

  @Test(
    arguments: [TransferManifest.State.verifying, .renaming],
    [false, true]
  )
  func uploadDoesNotPublishATemporarySymlinkFromACheckpoint(
    _ replacementState: TransferManifest.State,
    _ overwrite: Bool
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, bytes) = try fixture.sourceFile(size: 4)
    let target = fixture.server.url("/unrelated")
    try bytes.write(to: target)
    let original = Data("protected".utf8)
    if overwrite { try fixture.remoteFile("/destination", data: original) }
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/destination",
      stagingDirectory: fixture.staging,
      overwriteExisting: overwrite
    )
    let temporary = fixture.server.url(manifest.remoteTemporaryPath!)
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.notRegularFile) {
      try await SFTPTransfers.upload(&manifest, client: client) { checkpoint in
        guard checkpoint.state == replacementState else { return }
        do {
          try FileManager.default.removeItem(at: temporary)
          try FileManager.default.createSymbolicLink(
            at: temporary,
            withDestinationURL: target
          )
        } catch { Issue.record(error) }
      }
    }
    let targetBytes = try Data(contentsOf: target)
    let destinationBytes = try? Data(
      contentsOf: fixture.server.url("/destination")
    )
    #expect(!manifest.isComplete)
    #expect(destinationBytes == (overwrite ? original : nil))
    #expect(targetBytes == bytes)
    await connection.close()
    await fixture.cleanup()
  }

  @Test(arguments: [false, true])
  func uploadRejectsChangedBytesFromARenamingCheckpoint(
    _ overwrite: Bool
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, _) = try fixture.sourceFile(size: 4)
    let original = Data("protected".utf8)
    if overwrite { try fixture.remoteFile("/destination", data: original) }
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/destination",
      stagingDirectory: fixture.staging,
      overwriteExisting: overwrite
    )
    let temporary = fixture.server.url(manifest.remoteTemporaryPath!)
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.remoteSourceChanged) {
      try await SFTPTransfers.upload(&manifest, client: client) { checkpoint in
        guard checkpoint.state == .renaming else { return }
        do { try Data([1, 2, 3, 4]).write(to: temporary) } catch {
          Issue.record(error)
        }
      }
    }
    let destinationBytes = try? Data(
      contentsOf: fixture.server.url("/destination")
    )
    #expect(!manifest.isComplete)
    #expect(destinationBytes == (overwrite ? original : nil))
    await connection.close()
    await fixture.cleanup()
  }

}
