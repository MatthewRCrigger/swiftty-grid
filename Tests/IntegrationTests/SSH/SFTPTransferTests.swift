import Crypto
import Foundation
import SessionCore
import Synchronization
import Testing

@testable import SSHClient

/// Captures every checkpointed manifest, like durable app storage.
final class ManifestLog: Sendable {
  let latest = Mutex<TransferManifest?>(nil)
  let count = Mutex(0)

  var checkpoint: TransferCheckpoint {
    { manifest in
      // Round-trip through the persisted form.
      let decoded = try? TransferManifest.decode(manifest.encoded())
      self.latest.withLock { $0 = decoded }
      self.count.withLock { $0 += 1 }
    }
  }
}

/// A temporary local workspace plus a server.
struct TransferFixture {
  let server: TestSSHServer
  let local: URL

  static func make() async throws -> TransferFixture {
    let local = FileManager.default.temporaryDirectory
      .appendingPathComponent("sftp-local-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: local,
      withIntermediateDirectories: true
    )
    return TransferFixture(server: try await TestSSHServer.start(), local: local)
  }

  func cleanup() async {
    await server.shutdown()
    try? FileManager.default.removeItem(at: local)
  }

  var staging: URL { local.appendingPathComponent("staging") }

  func sourceFile(size: Int, seed: UInt64 = 1) throws -> (URL, Data) {
    var rng = SplitMix64(seed: seed)
    let data = Data((0 ..< size).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
    let url = local.appendingPathComponent("source-\(seed).bin")
    try data.write(to: url)
    return (url, data)
  }

  func remoteFile(_ path: String, data: Data) throws {
    try data.write(to: server.url(path))
  }

  func remoteData(_ path: String) -> Data? {
    try? Data(contentsOf: server.url(path))
  }

  func remoteNames() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: server.root.path))?
      .sorted() ?? []
  }

  /// Opens a fresh connection and SFTP client.
  func session() async throws -> (SSHConnection, SFTPClient) {
    let connection = try await server.connect()
    return (connection, try await connection.openSFTP())
  }

  /// Runs `body` until it completes, reconnecting after each dropped
  /// connection. Returns the number of attempts.
  func untilComplete(
    maxAttempts: Int = 6,
    _ body: (SFTPClient) async throws -> Void
  ) async throws -> Int {
    for attempt in 1 ... maxAttempts {
      let (connection, client) = try await session()
      do {
        try await body(client)
        await connection.close()
        return attempt
      } catch let error as SFTPError where error == .connectionClosed {
        await connection.close()
      }
    }
    Issue.record("transfer did not complete")
    return maxAttempts
  }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SFTPTransferTests {
  static let fileSize = 19 * 32 * 1024 + 1234

  @Test
  func `sftp client lists stats and rejects bad paths`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    for name in ["a", "b", "c", "d", "e"] {
      try fixture.remoteFile("/" + name, data: Data(name.utf8))
    }
    try FileManager.default.createDirectory(
      at: fixture.server.url("/dir"),
      withIntermediateDirectories: false
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }

    let entries = try await client.listDirectory("/")
    #expect(entries.map(\.filename) == ["a", "b", "c", "d", "dir", "e"])
    #expect(entries.first { $0.filename == "dir" }?.attributes.isDirectory == true)
    #expect(try await client.stat("/a").size == 1)
    #expect(try await client.realpath("/a/") == "/a")
    await #expect(throws: SFTPError.self) { _ = try await client.stat("/missing") }
    await #expect(throws: SFTPError.invalidPath) { _ = try await client.stat("") }
    await #expect(throws: SFTPError.invalidPath) {
      _ = try await client.stat("a\u{0}b")
    }
    let handle = try await client.open("/a", flags: [.read])
    #expect(try await client.read(handle, offset: 0, length: 10) == Array("a".utf8))
    #expect(try await client.read(handle, offset: 1, length: 10) == nil)
    #expect(try await client.fstat(handle).isRegularFile)
    try await client.close(handle)
    await #expect(throws: SFTPError.invalidLength) {
      _ = try await client.read(handle, offset: 0, length: 0)
    }
  }

  @Test
  func `upload completes with verified identical content`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize)
    let log = ManifestLog()
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/upload.bin",
      stagingDirectory: fixture.staging
    )
    #expect(manifest.sourceSize == UInt64(data.count))
    #expect(
      manifest.sourceSHA256 == hexString(SHA256.hash(data: data))
    )
    #expect(manifest.remoteTemporaryPath!.hasPrefix("/.upload.bin."))

    let (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(
      &manifest,
      client: client,
      checkpoint: log.checkpoint
    )
    await connection.close()
    #expect(manifest.state == .completed)
    #expect(log.latest.withLock { $0 } == manifest)
    #expect(fixture.remoteData("/upload.bin") == data)
    #expect(fixture.remoteNames() == ["upload.bin"])
    #expect(!FileManager.default.fileExists(atPath: manifest.localPath))
    // Writes use the outstanding window, never append mode.
    #expect(fixture.server.state.writes.withLock { $0 } == 20)
  }

  @Test(arguments: [2, 5, 9, 14, 21, 26, 30, 34])
  func `interrupted upload resumes to an identical file`(
    dropAfter: Int
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize, seed: 7)
    let log = ManifestLog()
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    fixture.server.state.faults.withLock { $0.dropAfterRequests = dropAfter }

    let attempts = try await fixture.untilComplete { client in
      do {
        try await SFTPTransfers.upload(
          &manifest,
          client: client,
          checkpoint: log.checkpoint
        )
      } catch {
        // Never complete when interrupted; the checkpoint matches.
        #expect(manifest.state != .completed)
        #expect(log.latest.withLock { $0 }.map { $0 == manifest } ?? true)
        throw error
      }
    }
    #expect(attempts == 2)
    #expect(manifest.state == .completed)
    #expect(fixture.remoteData("/dest.bin") == data)
    #expect(fixture.remoteNames() == ["dest.bin"])
  }

  @Test
  func `resume keeps a verified prefix and restarts on an altered one`()
    async throws
  {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize, seed: 3)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    // open + several writes, then drop.
    fixture.server.state.faults.withLock { $0.dropAfterRequests = 12 }
    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.connectionClosed) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    await connection.close()
    #expect(manifest.state == .transferring)
    #expect(manifest.acknowledgedOffset > 0)
    #expect(manifest.acknowledgedOffset % 32768 == 0)
    let firstTemp = try #require(manifest.remoteTemporaryPath)

    // Corrupt the retained prefix on the server.
    let tempURL = fixture.server.url(firstTemp)
    var corrupted = try Data(contentsOf: tempURL)
    corrupted[100] ^= 0xFF
    try corrupted.write(to: tempURL)

    (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(&manifest, client: client)
    await connection.close()
    #expect(manifest.state == .completed)
    #expect(manifest.restartCount == 1)
    #expect(manifest.remoteTemporaryPath != firstTemp)
    #expect(fixture.remoteData("/dest.bin") == data)
    // The corrupted temporary file was discarded.
    #expect(fixture.remoteNames() == ["dest.bin"])
  }

  @Test
  func `intact prefix is reused without restarting`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize, seed: 4)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    fixture.server.state.faults.withLock { $0.dropAfterRequests = 14 }
    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.self) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    await connection.close()
    let retained = manifest.acknowledgedOffset
    #expect(retained > 0)
    let writesBefore = fixture.server.state.writes.withLock { $0 }

    (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(&manifest, client: client)
    await connection.close()
    #expect(manifest.restartCount == 0)
    let resent = fixture.server.state.writes.withLock { $0 } - writesBefore
    let remaining = (UInt64(data.count) - retained + 32767) / 32768
    #expect(UInt64(resent) == remaining)
    #expect(fixture.remoteData("/dest.bin") == data)
  }

  @Test
  func `lost rename response is inspected before retrying`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: 100_000, seed: 5)
    let log = ManifestLog()
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    fixture.server.state.faults.withLock { $0.dropRenameResponse = true }

    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.connectionClosed) {
      try await SFTPTransfers.upload(
        &manifest,
        client: client,
        checkpoint: log.checkpoint
      )
    }
    await connection.close()
    // The rename happened, but the client cannot know that yet.
    #expect(manifest.state == .renaming)
    #expect(log.latest.withLock { $0?.state } == .renaming)
    #expect(fixture.remoteData("/dest.bin") == data)

    // Resume from the persisted manifest only.
    var resumed = try #require(log.latest.withLock { $0 })
    (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(&resumed, client: client)
    await connection.close()
    #expect(resumed.state == .completed)
    #expect(fixture.server.state.renames.withLock { $0 } == 1)
    #expect(fixture.remoteData("/dest.bin") == data)
  }

  @Test
  func `existing destination is never overwritten without a decision`()
    async throws
  {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: 70_000, seed: 6)
    let original = Data("keep me".utf8)
    try fixture.remoteFile("/dest.bin", data: original)
    var manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )

    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPTransferError.destinationExists) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    #expect(manifest.state == .conflict)
    #expect(fixture.remoteData("/dest.bin") == original)
    await connection.close()

    // Conflict appearing after the bytes moved: temp is kept, verified.
    try FileManager.default.removeItem(at: fixture.server.url("/dest.bin"))
    fixture.server.state.faults.withLock { $0.dropAfterRequests = 8 }
    (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.self) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    await connection.close()
    try fixture.remoteFile("/dest.bin", data: original)
    (connection, client) = try await fixture.session()
    await #expect(throws: SFTPTransferError.destinationExists) {
      try await SFTPTransfers.upload(&manifest, client: client)
    }
    await connection.close()
    #expect(manifest.state == .conflict)
    #expect(fixture.remoteData("/dest.bin") == original)
    #expect(fixture.remoteNames().count == 2)

    // An explicit decision replaces it.
    manifest.overwriteExisting = true
    (connection, client) = try await fixture.session()
    try await SFTPTransfers.upload(&manifest, client: client)
    await connection.close()
    #expect(manifest.state == .completed)
    #expect(fixture.remoteData("/dest.bin") == data)
    #expect(fixture.remoteNames() == ["dest.bin"])
  }

  @Test(arguments: [3, 7, 11, 18, 24, 31])
  func `interrupted download resumes to a verified identical file`(
    dropAfter: Int
  ) async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (_, data) = try fixture.sourceFile(size: Self.fileSize, seed: 9)
    try fixture.remoteFile("/remote.bin", data: data)
    let destination = fixture.local.appendingPathComponent("downloaded.bin")
    let log = ManifestLog()
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/remote.bin",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    fixture.server.state.faults.withLock { $0.dropAfterRequests = dropAfter }

    let attempts = try await fixture.untilComplete { client in
      do {
        try await SFTPTransfers.download(
          &manifest,
          client: client,
          checkpoint: log.checkpoint
        )
      } catch {
        #expect(manifest.state != .completed)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        throw error
      }
    }
    #expect(attempts == 2)
    #expect(manifest.state == .completed)
    #expect(manifest.sourceSHA256 == hexString(SHA256.hash(data: data)))
    #expect(try Data(contentsOf: destination) == data)
    #expect(!FileManager.default.fileExists(atPath: manifest.localPath))
  }

  @Test
  func `download restarts when the remote prefix changed`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (_, data) = try fixture.sourceFile(size: Self.fileSize, seed: 10)
    try fixture.remoteFile("/remote.bin", data: data)
    let destination = fixture.local.appendingPathComponent("out.bin")
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/remote.bin",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    fixture.server.state.faults.withLock { $0.dropAfterRequests = 12 }
    var (connection, client) = try await fixture.session()
    await #expect(throws: SFTPError.self) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    await connection.close()
    #expect(manifest.acknowledgedOffset > 0)

    // Same size (and likely mtime second), different prefix bytes.
    var changed = data
    changed[10] ^= 0x55
    try fixture.remoteFile("/remote.bin", data: changed)
    let identity = manifest.remoteIdentity
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.server.url("/remote.bin").path
    )
    if let date = identity?.modificationTime {
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: Double(date))],
        ofItemAtPath: fixture.server.url("/remote.bin").path
      )
    }
    _ = attributes

    (connection, client) = try await fixture.session()
    try await SFTPTransfers.download(&manifest, client: client)
    await connection.close()
    #expect(manifest.restartCount == 1)
    #expect(try Data(contentsOf: destination) == changed)
  }

  @Test
  func `download refuses to replace an existing local file`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try fixture.remoteFile("/remote.bin", data: Data("new".utf8))
    let destination = fixture.local.appendingPathComponent("exists.bin")
    try Data("old".utf8).write(to: destination)
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/remote.bin",
      temporaryDirectory: fixture.local,
      destination: destination
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.destinationExists) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    #expect(manifest.state == .conflict)
    #expect(try Data(contentsOf: destination) == Data("old".utf8))

    manifest.overwriteExisting = true
    try await SFTPTransfers.download(&manifest, client: client)
    #expect(manifest.state == .completed)
    #expect(try Data(contentsOf: destination) == Data("new".utf8))
  }

  @Test
  func `non-regular files are rejected for transfer`() async throws {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    try FileManager.default.createDirectory(
      at: fixture.server.url("/dir"),
      withIntermediateDirectories: false
    )
    var manifest = try SFTPTransfers.prepareDownload(
      remotePath: "/dir",
      temporaryDirectory: fixture.local,
      destination: fixture.local.appendingPathComponent("x")
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }
    await #expect(throws: SFTPTransferError.notRegularFile) {
      try await SFTPTransfers.download(&manifest, client: client)
    }
    await #expect(throws: SFTPTransferError.notRegularFile) {
      _ = try await SFTPTransfers.prepareUpload(
        source: fixture.local,
        remotePath: "/x",
        stagingDirectory: fixture.staging
      )
    }
    #expect(throws: SFTPTransferError.invalidRemotePath) {
      _ = try SFTPTransfers.prepareDownload(
        remotePath: "/dir/",
        temporaryDirectory: fixture.local,
        destination: fixture.local
      )
    }
  }

  @Test
  func `paused gate holds bulk work and cancellation stays resumable`()
    async throws
  {
    let fixture = try await TransferFixture.make()
    defer { Task { await fixture.cleanup() } }
    let (source, data) = try fixture.sourceFile(size: Self.fileSize, seed: 11)
    let gate = TransferPauseGate()
    await gate.pause()
    let log = ManifestLog()
    let manifest = try await SFTPTransfers.prepareUpload(
      source: source,
      remotePath: "/dest.bin",
      stagingDirectory: fixture.staging
    )
    let (connection, client) = try await fixture.session()
    defer { Task { await connection.close() } }

    let task = Task {
      var copy = manifest
      try await SFTPTransfers.upload(
        &copy,
        client: client,
        gate: gate,
        checkpoint: log.checkpoint
      )
      return copy
    }
    #expect(
      try await waitUntil { log.latest.withLock { $0?.state } == .transferring }
    )
    try await Task.sleep(for: .milliseconds(100))
    #expect(fixture.server.state.writes.withLock { $0 } == 0)
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }

    var resumed = try #require(log.latest.withLock { $0 })
    #expect(resumed.state == .transferring)
    await gate.resume()
    try await SFTPTransfers.upload(&resumed, client: client, gate: gate)
    #expect(resumed.state == .completed)
    #expect(fixture.remoteData("/dest.bin") == data)
  }

  @Test
  func `manifest encoding is bounded and non-secret`() throws {
    var manifest = TransferManifest(
      direction: .upload,
      localPath: "/staged",
      remotePath: "/r",
      sourceSize: 10,
      sourceSHA256: String(repeating: "0", count: 64)
    )
    manifest.acknowledgedOffset = 5
    let data = try manifest.encoded()
    #expect(try TransferManifest.decode(data) == manifest)
    manifest.acknowledgedOffset = 11
    #expect(throws: DecodingError.self) {
      _ = try TransferManifest.decode(manifest.encoded())
    }
    #expect(throws: DecodingError.self) {
      _ = try TransferManifest.decode(Data(count: 70_000))
    }
  }
}
