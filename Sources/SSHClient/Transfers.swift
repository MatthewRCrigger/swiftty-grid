import Crypto
import Foundation
import SessionCore

#if canImport(Darwin)
import Darwin
#endif

public enum SFTPTransferError: Error, Equatable, Sendable {
  /// Only regular files are transferred (spec §10).
  case notRegularFile
  /// The destination exists and overwriting was not approved.
  case destinationExists
  /// The staged source changed content or its path no longer names the
  /// verified local file.
  case stagedSourceChanged
  /// A remote source or staged upload changed size or content.
  case remoteSourceChanged
  /// Verification kept failing after the restart budget was used.
  case verificationFailed
  /// After a lost rename response, neither the temporary file nor a
  /// verified destination could be found.
  case renameOutcomeUncertain
  case closeFailed
  case invalidManifest
  case invalidRemotePath
  case fileTooLarge
  case invalidOptions
}

public struct SFTPTransferOptions: Hashable, Sendable {
  public var chunkSize: Int
  public var maxOutstanding: Int
  /// Restarts from offset zero allowed per `upload`/`download` call.
  public var maxRestarts: Int

  var isValid: Bool {
    (1 ... SFTPClient.maxIOLength).contains(chunkSize)
      && (1 ... RSTLimits.sftpOutstandingRequests).contains(maxOutstanding)
      && maxRestarts >= 0
  }

  public init(
    chunkSize: Int = RSTLimits.sftpChunkBytes,
    maxOutstanding: Int = RSTLimits.sftpOutstandingRequests,
    maxRestarts: Int = 2
  ) {
    self.chunkSize = min(max(chunkSize, 1), SFTPClient.maxIOLength)
    self.maxOutstanding = min(
      max(maxOutstanding, 1),
      RSTLimits.sftpOutstandingRequests
    )
    self.maxRestarts = max(maxRestarts, 0)
  }
}

/// Persists a manifest each time it changes; called serially.
public typealias TransferCheckpoint = @Sendable (TransferManifest) async -> Void

/// Resumable, verified SFTP transfers of regular files (spec §10).
///
/// Every function takes the manifest `inout`: on any error (including
/// cancellation or a dropped connection) it holds the last consistent
/// checkpoint, so the caller can persist it and resume later with a new
/// `SFTPClient`. Completion is reported only after full verification.
public enum SFTPTransfers {
  // MARK: Preparation

  /// Copies `source` into app-controlled `stagingDirectory` as an
  /// immutable (read-only) file, hashes it and chooses a unique remote
  /// temporary name beside `remotePath`.
  public static func prepareUpload(
    source: URL,
    remotePath: String,
    stagingDirectory: URL,
    overwriteExisting: Bool = false
  ) async throws -> TransferManifest {
    try await prepareUpload(
      source: source,
      remotePath: remotePath,
      stagingDirectory: stagingDirectory,
      overwriteExisting: overwriteExisting,
      beforeCopyForTesting: nil
    )
  }

  static func prepareUpload(
    source: URL,
    remotePath: String,
    stagingDirectory: URL,
    overwriteExisting: Bool = false,
    beforeCopyForTesting: (@Sendable () throws -> Void)?,
    afterHashReadForTesting: (@Sendable (UInt64) throws -> Void)? = nil
  ) async throws -> TransferManifest {
    guard let parts = RemotePath(remotePath) else {
      throw SFTPTransferError.invalidRemotePath
    }
    let temporary = parts.temporarySibling()
    guard temporary.utf8.count <= SFTPLimits.maxPathBytes else {
      throw SFTPTransferError.invalidRemotePath
    }
    let staged = stagingDirectory.appendingPathComponent(
      "upload-" + UUID().uuidString
    )
    let (size, digest) = try await BlockingFileIO.runCancellable {
      cancellation throws -> (UInt64, String?) in
      let values = try source.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else {
        throw SFTPTransferError.notRegularFile
      }
      try beforeCopyForTesting?()
      try cancellation.check()
      let sourceFD = Darwin.open(
        source.path,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
      )
      guard sourceFD >= 0 else {
        if errno == ELOOP { throw SFTPTransferError.notRegularFile }
        throw posixError()
      }
      defer { Darwin.close(sourceFD) }
      var sourceInfo = Darwin.stat()
      guard fstat(sourceFD, &sourceInfo) == 0 else { throw posixError() }
      guard sourceInfo.st_mode & S_IFMT == S_IFREG else {
        throw SFTPTransferError.notRegularFile
      }
      try FileManager.default.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: true
      )
      let fd = Darwin.open(
        staged.path,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
      )
      guard fd >= 0 else { throw posixError() }
      var prepared = false
      defer {
        Darwin.close(fd)
        if !prepared { _ = Darwin.unlink(staged.path) }
      }
      try cancellation.check()
      guard fcopyfile(sourceFD, fd, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
      else { throw posixError() }
      try cancellation.check()
      guard fchmod(fd, 0o400) == 0 else { throw posixError() }
      var info = Darwin.stat()
      guard fstat(fd, &info) == 0 else { throw posixError() }
      guard let size = UInt64(exactly: info.st_size) else {
        throw SFTPTransferError.fileTooLarge
      }
      var hasher = SHA256()
      var offset: UInt64 = 0
      while offset < size {
        try cancellation.check()
        let want = Int(min(256 * 1024, size - offset))
        let bytes = try LocalFile.readSync(fd: fd, offset: offset, count: want)
        try afterHashReadForTesting?(offset)
        try cancellation.check()
        guard bytes.count == want else { return (size, nil) }
        hasher.update(data: bytes)
        offset += UInt64(want)
      }
      try cancellation.check()
      prepared = true
      return (size, hexString(hasher.finalize()))
    }
    guard let digest else { throw SFTPTransferError.stagedSourceChanged }
    return TransferManifest(
      direction: .upload,
      localPath: staged.path,
      remotePath: remotePath,
      remoteTemporaryPath: temporary,
      overwriteExisting: overwriteExisting,
      sourceSize: size,
      sourceSHA256: digest
    )
  }

  /// A download manifest writing into `temporaryDirectory` and
  /// publishing to `destination` only after verification.
  public static func prepareDownload(
    remotePath: String,
    temporaryDirectory: URL,
    destination: URL,
    overwriteExisting: Bool = false
  ) throws -> TransferManifest {
    guard RemotePath(remotePath) != nil else {
      throw SFTPTransferError.invalidRemotePath
    }
    let temporary = temporaryDirectory.appendingPathComponent(
      "download-" + UUID().uuidString + ".part"
    )
    return TransferManifest(
      direction: .download,
      localPath: temporary.path,
      remotePath: remotePath,
      localDestinationPath: destination.path,
      overwriteExisting: overwriteExisting,
      sourceSize: 0
    )
  }

  // MARK: Upload

  public static func upload(
    _ manifest: inout TransferManifest,
    client: SFTPClient,
    gate: any TransferGate = OpenTransferGate(),
    options: SFTPTransferOptions = SFTPTransferOptions(),
    checkpoint: @escaping TransferCheckpoint = { _ in }
  ) async throws {
    guard options.isValid else { throw SFTPTransferError.invalidOptions }
    guard manifest.direction == .upload, manifest.hasValidProgress,
      LocalFile.isValidPath(manifest.localPath),
      let sourceSHA = manifest.sourceSHA256,
      let temporaryPath = manifest.remoteTemporaryPath,
      let temporary = RemotePath(temporaryPath),
      let destination = RemotePath(manifest.remotePath),
      !temporary.hasEquivalentSpelling(to: destination)
    else { throw SFTPTransferError.invalidManifest }
    if manifest.state == .completed { return }

    let source = try await LocalFile.open(manifest.localPath, flags: O_RDONLY)
    defer { Darwin.close(source.fd) }
    guard try await source.size() == manifest.sourceSize,
      try await source.sha256(length: manifest.sourceSize) == sourceSHA
    else { throw SFTPTransferError.stagedSourceChanged }

    let context = UploadContext(
      client: client,
      source: source,
      gate: gate,
      options: options,
      checkpoint: checkpoint
    )

    switch manifest.state {
    case .renaming, .conflict:
      if try await context.resumeFinalization(&manifest) { return }
    default: break
    }

    // Refuse early rather than after moving every byte.
    if manifest.acknowledgedOffset == 0, !manifest.overwriteExisting,
      try await exists(manifest.remotePath, client: client)
    {
      manifest.state = .conflict
      await checkpoint(manifest)
      throw SFTPTransferError.destinationExists
    }

    var restarts = 0
    while true {
      try Task.checkCancellation()
      do {
        try await context.transfer(&manifest)
        manifest.state = .verifying
        await checkpoint(manifest)
        guard
          try await remoteSHA256(
            client: client,
            path: manifest.remoteTemporaryPath!,
            length: manifest.sourceSize,
            options: options,
            gate: gate,
            expectEOF: true
          ) == sourceSHA
        else { throw RestartTransfer() }
        break
      } catch is RestartTransfer {
        restarts += 1
        guard restarts <= options.maxRestarts else {
          manifest.state = .failed
          await checkpoint(manifest)
          throw SFTPTransferError.verificationFailed
        }
        try await context.restart(&manifest)
      }
    }
    try await context.finish(&manifest)
  }

  struct RestartTransfer: Error {}

  struct UploadContext {
    let client: SFTPClient
    let source: LocalFile
    let gate: any TransferGate
    let options: SFTPTransferOptions
    let checkpoint: TransferCheckpoint

    init(
      client: SFTPClient,
      source: LocalFile,
      gate: any TransferGate,
      options: SFTPTransferOptions,
      checkpoint: @escaping TransferCheckpoint
    ) {
      self.client = client
      self.source = source
      self.gate = gate
      self.options = options
      self.checkpoint = checkpoint
    }

    /// Discards the current temporary file and starts over under a new
    /// unique name.
    func restart(_ manifest: inout TransferManifest) async throws {
      let (nextRestartCount, overflow) = manifest.restartCount
        .addingReportingOverflow(1)
      guard !overflow else { throw SFTPTransferError.invalidManifest }
      if let old = manifest.remoteTemporaryPath {
        try? await client.remove(old)
      }
      manifest.remoteTemporaryPath = RemotePath(manifest.remotePath)?
        .temporarySibling()
      manifest.acknowledgedOffset = 0
      manifest.remoteIdentity = nil
      manifest.restartCount = nextRestartCount
      // The fresh temporary name has no remote state yet.
      manifest.state = .staged
      await checkpoint(manifest)
    }

    /// Writes every byte after the verified prefix into the temporary
    /// file and closes it, checking the close status.
    func transfer(_ manifest: inout TransferManifest) async throws {
      let temp = manifest.remoteTemporaryPath!
      let handle: SFTPFileHandle
      if manifest.acknowledgedOffset > 0 {
        // Resume: the retained prefix must hash identically.
        guard let attributes = try await statIfExists(temp, client: client),
          attributes.isRegularFile,
          (attributes.size ?? 0) >= manifest.acknowledgedOffset,
          try await remoteSHA256(
            client: client,
            path: temp,
            length: manifest.acknowledgedOffset,
            options: options,
            gate: gate,
            expectEOF: false
          ) == source.sha256(length: manifest.acknowledgedOffset)
        else { throw RestartTransfer() }
        handle = try await client.open(temp, flags: [.write])
      } else {
        if manifest.state != .staged {
          // A previous attempt may have created this name; never reuse.
          try await restart(&manifest)
        }
        handle = try await client.open(
          manifest.remoteTemporaryPath!,
          flags: [.write, .create, .exclusive],
          attributes: SFTPAttributes(permissions: 0o600)
        )
      }
      manifest.state = .transferring
      await checkpoint(manifest)

      do { try await pipelineWrite(handle: handle, manifest: &manifest) } catch
      {
        await client.closeAfterFailure(handle)
        throw error
      }
      do { try await client.close(handle) } catch let error as SFTPError
        where error.statusCode != nil
      { throw SFTPTransferError.closeFailed }
      if let attributes = try await statIfExists(
        manifest.remoteTemporaryPath!,
        client: client
      ) {
        manifest.remoteIdentity = RemoteFileIdentity(
          size: attributes.size ?? 0,
          modificationTime: attributes.modificationTime,
          permissions: attributes.permissions
        )
      }
    }

    /// Up to `maxOutstanding` positioned writes in flight; the manifest
    /// advances only over the contiguous acknowledged prefix.
    private func pipelineWrite(
      handle: SFTPFileHandle,
      manifest: inout TransferManifest
    ) async throws {
      let size = manifest.sourceSize
      let client = self.client
      try await withThrowingTaskGroup(of: (UInt64, UInt64).self) { group in
        var next = manifest.acknowledgedOffset
        var completed: [UInt64: UInt64] = [:]
        var inFlight = 0
        while next < size || inFlight > 0 {
          while inFlight + completed.count < options.maxOutstanding, next < size
          {
            try await gate.waitUntilOpen()
            let length = Int(min(UInt64(options.chunkSize), size - next))
            let data = try await source.read(at: next, count: length)
            guard data.count == length else {
              throw SFTPTransferError.stagedSourceChanged
            }
            let offset = next
            group.addTask {
              try await client.write(handle, offset: offset, data: data)
              return (offset, offset + UInt64(length))
            }
            next += UInt64(length)
            inFlight += 1
          }
          guard let (offset, end) = try await group.next() else { break }
          inFlight -= 1
          completed[offset] = end
          var contiguous = manifest.acknowledgedOffset
          while let end = completed.removeValue(forKey: contiguous) {
            contiguous = end
          }
          if contiguous != manifest.acknowledgedOffset {
            manifest.acknowledgedOffset = contiguous
            await checkpoint(manifest)
          }
        }
      }
    }

    /// Handles a manifest left in `.renaming` or `.conflict`. Returns
    /// `true` once the upload is verified and published; `false` when the
    /// transfer must run (again).
    func resumeFinalization(
      _ manifest: inout TransferManifest
    ) async throws -> Bool {
      let temp = manifest.remoteTemporaryPath!
      let tempAttributes = try await statIfExists(temp, client: client)
      if let tempAttributes {
        // Rename not applied (or a conflict was pending): re-verify the
        // complete temporary file before trying again.
        if tempAttributes.isRegularFile,
          tempAttributes.size == manifest.sourceSize,
          try await remoteSHA256(
            client: client,
            path: temp,
            length: manifest.sourceSize,
            options: options,
            gate: gate,
            expectEOF: true
          ) == manifest.sourceSHA256
        {
          try await finish(&manifest)
          return true
        }
        try await restart(&manifest)
        return false
      }
      if manifest.state == .conflict {
        // Conflict found before any bytes moved: start over normally.
        manifest.state = .staged
        manifest.acknowledgedOffset = 0
        return false
      }
      // Temporary file gone: the rename may have happened. Only a
      // destination with the exact source content counts as success.
      if let destination = try await statIfExists(
        manifest.remotePath,
        client: client
      ), destination.isRegularFile, destination.size == manifest.sourceSize,
        try await remoteSHA256(
          client: client,
          path: manifest.remotePath,
          length: manifest.sourceSize,
          options: options,
          gate: gate,
          expectEOF: true
        ) == manifest.sourceSHA256
      {
        await complete(&manifest)
        return true
      }
      manifest.state = .failed
      await checkpoint(manifest)
      throw SFTPTransferError.renameOutcomeUncertain
    }

    /// Publishes the verified temporary file under the destination name.
    func finish(_ manifest: inout TransferManifest) async throws {
      let temp = manifest.remoteTemporaryPath!
      let destinationExists = try await exists(
        manifest.remotePath,
        client: client
      )
      if destinationExists, !manifest.overwriteExisting {
        manifest.state = .conflict
        await checkpoint(manifest)
        throw SFTPTransferError.destinationExists
      }
      manifest.state = .renaming
      await checkpoint(manifest)
      // Checkpoints can suspend while the temporary entry changes. Verify
      // again before removing an approved destination or publishing bytes.
      guard try await client.lstat(temp).isRegularFile else {
        throw SFTPTransferError.notRegularFile
      }
      guard
        try await remoteSHA256(
          client: client,
          path: temp,
          length: manifest.sourceSize,
          options: options,
          gate: gate,
          expectEOF: true
        ) == manifest.sourceSHA256
      else { throw SFTPTransferError.remoteSourceChanged }
      if destinationExists {
        if client.supportsPOSIXRename {
          try await client.posixRename(temp, to: manifest.remotePath)
        } else {
          try await client.remove(manifest.remotePath)
          try await client.rename(temp, to: manifest.remotePath)
        }
      } else {
        try await client.rename(temp, to: manifest.remotePath)
      }
      await complete(&manifest)
    }

    private func complete(_ manifest: inout TransferManifest) async {
      manifest.acknowledgedOffset = manifest.sourceSize
      manifest.state = .completed
      await checkpoint(manifest)
      let staged = manifest.localPath
      _ = try? await BlockingFileIO.run { _ = Darwin.unlink(staged) }
    }
  }

  // MARK: Download

  public static func download(
    _ manifest: inout TransferManifest,
    client: SFTPClient,
    gate: any TransferGate = OpenTransferGate(),
    options: SFTPTransferOptions = SFTPTransferOptions(),
    checkpoint: TransferCheckpoint = { _ in }
  ) async throws {
    guard options.isValid else { throw SFTPTransferError.invalidOptions }
    guard manifest.direction == .download, manifest.hasValidProgress,
      LocalFile.isValidPath(manifest.localPath),
      let destinationPath = manifest.localDestinationPath,
      LocalFile.isValidPath(destinationPath)
    else { throw SFTPTransferError.invalidManifest }
    if manifest.state == .completed { return }

    let local = try await LocalFile.open(
      manifest.localPath,
      flags: O_RDWR | O_CREAT,
      excluding: destinationPath
    )
    defer { Darwin.close(local.fd) }

    var restarts = 0
    var digest: String
    while true {
      try Task.checkCancellation()
      do {
        try await downloadPass(
          &manifest,
          client: client,
          local: local,
          gate: gate,
          options: options,
          checkpoint: checkpoint
        )
        manifest.state = .verifying
        await checkpoint(manifest)
        // Whole-file verification: unchanged remote metadata, then the
        // local file against a fresh read-back of the remote file.
        let attributes = try await client.stat(manifest.remotePath)
        guard attributes.isRegularFile,
          identity(attributes) == manifest.remoteIdentity,
          try await local.size() == manifest.sourceSize,
          let localDigest = try await local.sha256(length: manifest.sourceSize),
          try await remoteSHA256(
            client: client,
            path: manifest.remotePath,
            length: manifest.sourceSize,
            options: options,
            gate: gate,
            expectEOF: true
          ) == localDigest
        else { throw RestartTransfer() }
        digest = localDigest
        break
      } catch is RestartTransfer {
        restarts += 1
        guard restarts <= options.maxRestarts else {
          manifest.state = .failed
          await checkpoint(manifest)
          throw SFTPTransferError.verificationFailed
        }
        let (nextRestartCount, overflow) = manifest.restartCount
          .addingReportingOverflow(1)
        guard !overflow else { throw SFTPTransferError.invalidManifest }
        try await local.truncate(to: 0)
        manifest.acknowledgedOffset = 0
        manifest.prefixSHA256 = nil
        manifest.remoteIdentity = nil
        manifest.restartCount = nextRestartCount
        manifest.state = .transferring
        await checkpoint(manifest)
      }
    }

    try await local.sync()
    let overwrite = manifest.overwriteExisting
    let temporaryPath = manifest.localPath
    let published = try await BlockingFileIO.run { () throws -> Bool in
      // Verification used the open descriptor. The caller's checkpoint
      // may have replaced its name while that descriptor remained valid.
      var opened = Darwin.stat()
      guard fstat(local.fd, &opened) == 0 else { throw posixError() }
      var named = Darwin.stat()
      guard lstat(temporaryPath, &named) == 0 else {
        if errno == ENOENT { throw SFTPTransferError.stagedSourceChanged }
        throw posixError()
      }
      guard named.st_mode & S_IFMT == S_IFREG, named.st_dev == opened.st_dev,
        named.st_ino == opened.st_ino
      else { throw SFTPTransferError.stagedSourceChanged }
      let fileManager = FileManager.default
      let destination = URL(fileURLWithPath: destinationPath)
      let temporary = URL(fileURLWithPath: temporaryPath)
      var existing = Darwin.stat()
      let destinationExists = lstat(destinationPath, &existing) == 0
      if !destinationExists, errno != ENOENT { throw posixError() }
      if destinationExists {
        guard overwrite else { return false }
        let kind = existing.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFLNK else {
          throw SFTPTransferError.notRegularFile
        }
        if kind == S_IFLNK {
          try replaceLocalSymlink(
            local: local,
            temporary: temporary,
            destination: destination
          )
        } else {
          _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        }
      } else {
        try fileManager.moveItem(at: temporary, to: destination)
      }
      return true
    }
    guard published else {
      manifest.state = .conflict
      await checkpoint(manifest)
      throw SFTPTransferError.destinationExists
    }
    manifest.sourceSHA256 = digest
    manifest.prefixSHA256 = digest
    manifest.acknowledgedOffset = manifest.sourceSize
    manifest.state = .completed
    await checkpoint(manifest)
  }

  /// Copies the verified descriptor beside the destination before the
  /// same-volume rename, so even a cross-volume staging file is supported.
  /// Called only on BlockingFileIO.queue with overwrite approval.
  private static func replaceLocalSymlink(
    local: LocalFile,
    temporary: URL,
    destination: URL
  ) throws {
    let sibling = destination.deletingLastPathComponent()
      .appendingPathComponent("download-" + UUID().uuidString + ".part")
    let fd = Darwin.open(
      sibling.path,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      0o600
    )
    guard fd >= 0 else { throw posixError() }
    defer {
      Darwin.close(fd)
      _ = Darwin.unlink(sibling.path)
    }
    guard fcopyfile(local.fd, fd, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
    else { throw posixError() }
    guard fsync(fd) == 0 else { throw posixError() }
    guard Darwin.rename(sibling.path, destination.path) == 0 else {
      throw posixError()
    }
    // Publication succeeded; a cleanup failure must not report an
    // unsuccessful transfer after the destination has already changed.
    _ = Darwin.unlink(temporary.path)
  }

  private static func identity(
    _ attributes: SFTPAttributes
  ) -> RemoteFileIdentity {
    RemoteFileIdentity(
      size: attributes.size ?? 0,
      modificationTime: attributes.modificationTime,
      permissions: attributes.permissions
    )
  }

  /// Validates the retained prefix, then fetches the rest.
  private static func downloadPass(
    _ manifest: inout TransferManifest,
    client: SFTPClient,
    local: LocalFile,
    gate: any TransferGate,
    options: SFTPTransferOptions,
    checkpoint: TransferCheckpoint
  ) async throws {
    let attributes = try await client.stat(manifest.remotePath)
    guard attributes.isRegularFile, let size = attributes.size else {
      throw SFTPTransferError.notRegularFile
    }
    guard size <= UInt64(off_t.max) else {
      throw SFTPTransferError.fileTooLarge
    }
    let current = identity(attributes)
    var hasher = SHA256()
    if let recorded = manifest.remoteIdentity, recorded == current,
      manifest.acknowledgedOffset > 0
    {
      // Resume: local prefix must match its checkpoint hash, and the
      // remote prefix must still hash the same.
      let ack = manifest.acknowledgedOffset
      guard try await local.size() >= ack,
        let localPrefix = try await local.sha256(length: ack),
        localPrefix == manifest.prefixSHA256,
        try await remoteSHA256(
          client: client,
          path: manifest.remotePath,
          length: ack,
          options: options,
          gate: gate,
          expectEOF: false
        ) == localPrefix
      else { throw RestartTransfer() }
      hasher = try await prefixHasher(local, length: ack)
    } else {
      manifest.acknowledgedOffset = 0
      manifest.prefixSHA256 = nil
    }
    manifest.remoteIdentity = current
    manifest.sourceSize = size
    try await local.truncate(to: manifest.acknowledgedOffset)
    manifest.state = .transferring
    await checkpoint(manifest)

    let handle = try await client.open(manifest.remotePath, flags: [.read])
    do {
      try await withThrowingTaskGroup(of: (UInt64, [UInt8]).self) { group in
        var next = manifest.acknowledgedOffset
        var completed: [UInt64: [UInt8]] = [:]
        var inFlight = 0
        while next < size || inFlight > 0 {
          while inFlight + completed.count < options.maxOutstanding, next < size
          {
            try await gate.waitUntilOpen()
            let offset = next
            let length = Int(min(UInt64(options.chunkSize), size - next))
            group.addTask {
              (offset, try await readFully(client, handle, offset, length))
            }
            next += UInt64(length)
            inFlight += 1
          }
          guard let (offset, data) = try await group.next() else { break }
          inFlight -= 1
          try await local.write(data, at: offset)
          completed[offset] = data
          var advanced = false
          while let data = completed.removeValue(
            forKey: manifest.acknowledgedOffset
          ) {
            hasher.update(data: data)
            manifest.acknowledgedOffset += UInt64(data.count)
            advanced = true
          }
          if advanced {
            manifest.prefixSHA256 = hexString(hasher.finalize())
            await checkpoint(manifest)
          }
        }
      }
    } catch {
      await client.closeAfterFailure(handle)
      throw error
    }
    do { try await client.close(handle) } catch let error as SFTPError
      where error.statusCode != nil
    { throw SFTPTransferError.closeFailed }
  }

  private static func prefixHasher(
    _ file: LocalFile,
    length: UInt64
  ) async throws -> SHA256 {
    var hasher = SHA256()
    var offset: UInt64 = 0
    while offset < length {
      let want = Int(min(256 * 1024, length - offset))
      let bytes = try await file.read(at: offset, count: want)
      guard bytes.count == want else { throw RestartTransfer() }
      hasher.update(data: bytes)
      offset += UInt64(want)
    }
    return hasher
  }

  /// Reads exactly `length` bytes, following short reads; EOF first
  /// means the remote file changed.
  private static func readFully(
    _ client: SFTPClient,
    _ handle: SFTPFileHandle,
    _ offset: UInt64,
    _ length: Int
  ) async throws -> [UInt8] {
    var data: [UInt8] = []
    while data.count < length {
      guard
        let chunk = try await client.read(
          handle,
          offset: offset + UInt64(data.count),
          length: length - data.count
        ), !chunk.isEmpty
      else { throw SFTPTransferError.remoteSourceChanged }
      data += chunk
    }
    return data
  }

  // MARK: Shared helpers

  /// SHA-256 of remote bytes `0 ..< length` read back through SFTP with
  /// pipelined requests. Returns `nil` if the file is shorter, or (with
  /// `expectEOF`) longer than `length`.
  static func remoteSHA256(
    client: SFTPClient,
    path: String,
    length: UInt64,
    options: SFTPTransferOptions,
    gate: any TransferGate,
    expectEOF: Bool
  ) async throws -> String? {
    let handle = try await client.open(path, flags: [.read])
    var digest: String?
    do {
      digest = try await withThrowingTaskGroup(of: (UInt64, [UInt8]?).self) {
        group -> String? in
        var hasher = SHA256()
        var next: UInt64 = 0
        var hashed: UInt64 = 0
        var completed: [UInt64: [UInt8]] = [:]
        var inFlight = 0
        while next < length || inFlight > 0 {
          while inFlight + completed.count < options.maxOutstanding,
            next < length
          {
            try await gate.waitUntilOpen()
            let offset = next
            let count = Int(min(UInt64(options.chunkSize), length - next))
            group.addTask {
              do {
                let bytes = try await readFully(client, handle, offset, count)
                return (offset, bytes)
              } catch SFTPTransferError.remoteSourceChanged {
                return (offset, nil)
              }
            }
            next += UInt64(count)
            inFlight += 1
          }
          guard let (offset, data) = try await group.next() else { break }
          inFlight -= 1
          guard let data else {
            group.cancelAll()
            return nil
          }
          completed[offset] = data
          while let data = completed.removeValue(forKey: hashed) {
            hasher.update(data: data)
            hashed += UInt64(data.count)
          }
        }
        return hexString(hasher.finalize())
      }
      if digest != nil, expectEOF {
        let extra = try await client.read(handle, offset: length, length: 1)
        if let extra, !extra.isEmpty { digest = nil }
      }
    } catch {
      await client.closeAfterFailure(handle)
      throw error
    }
    do { try await client.close(handle) } catch let error as SFTPError
      where error.statusCode != nil
    { throw SFTPTransferError.closeFailed }
    return digest
  }

  static func statIfExists(
    _ path: String,
    client: SFTPClient
  ) async throws -> SFTPAttributes? {
    do { return try await client.lstat(path) } catch let error as SFTPError
      where error.statusCode == .noSuchFile
    { return nil }
  }

  static func exists(_ path: String, client: SFTPClient) async throws -> Bool {
    try await statIfExists(path, client: client) != nil
  }

  // MARK: Cleanup

  /// Best-effort removal of a transfer's temporary and staged files,
  /// e.g. after the user cancels for good. Never touches the destination
  /// or recursively removes a directory substituted at a temporary path.
  public static func discard(
    _ manifest: TransferManifest,
    client: SFTPClient?
  ) async {
    if manifest.direction == .upload, manifest.state != .completed,
      let temp = manifest.remoteTemporaryPath, let client,
      let temporary = RemotePath(temp),
      let destination = RemotePath(manifest.remotePath),
      !temporary.hasEquivalentSpelling(to: destination)
    {
      try? await client.remove(temp)
    }
    if manifest.state != .completed || manifest.direction == .upload {
      let path = manifest.localPath
      let download = manifest.direction == .download
      let destinationPath = manifest.localDestinationPath
      _ = try? await BlockingFileIO.run {
        guard LocalFile.isValidPath(path) else { return }
        if download {
          // An invalid download may name its destination as its stage.
          // Do not delete that file, including a destination's referent.
          guard let destinationPath, LocalFile.isValidPath(destinationPath)
          else { return }
          var local = Darwin.stat()
          guard lstat(path, &local) == 0 else { return }
          var destination = Darwin.stat()
          if stat(destinationPath, &destination) == 0 {
            guard
              local.st_dev != destination.st_dev
                || local.st_ino != destination.st_ino
            else { return }
          } else if errno != ENOENT {
            return
          }
        }
        _ = Darwin.unlink(path)
      }
    }
  }
}

/// Remote path split into directory and file name, used to place the
/// temporary upload file beside the destination.
struct RemotePath {
  let directory: String
  let name: String

  /// Compares UTF-8 path components after removing dot components and
  /// repeated separators. Preserve POSIX's special double-slash root.
  func hasEquivalentSpelling(to other: RemotePath) -> Bool {
    let first = directory + name
    let second = other.directory + other.name
    func rootKind(_ path: String) -> Int {
      if path.hasPrefix("//"), !path.hasPrefix("///") { return 2 }
      return path.hasPrefix("/") ? 1 : 0
    }
    guard rootKind(first) == rootKind(second) else { return false }
    func components(_ path: String) -> [[UInt8]] {
      path.split(separator: "/").filter { $0 != "." }.map { Array($0.utf8) }
    }
    return components(first) == components(second)
  }

  init?(_ path: String) {
    guard !path.isEmpty, path.utf8.count <= SFTPLimits.maxPathBytes,
      !path.utf8.contains(0), !path.hasSuffix("/")
    else { return nil }
    if let slash = path.lastIndex(of: "/") {
      directory = String(path[...slash])
      name = String(path[path.index(after: slash)...])
    } else {
      directory = ""
      name = path
    }
    guard !name.isEmpty, name != ".", name != ".." else { return nil }
  }

  /// `.<name>.<random>.swiftty-part` in the same directory.
  func temporarySibling() -> String {
    var bytes = 0
    let prefix = name.unicodeScalars.prefix { scalar in
      let count = scalar.utf8.count
      guard bytes + count <= 100 else { return false }
      bytes += count
      return true
    }
    let stem = String(String.UnicodeScalarView(prefix))
    return directory + "." + stem + "." + hexString(secureRandomBytes(8))
      + ".swiftty-part"
  }
}
