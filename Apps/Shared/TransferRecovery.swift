#if !os(tvOS)
import Foundation
import SessionCore
import SSHClient

/// Recovery changes ownership only after staging succeeds. A new remote temporary
/// name and fresh overwrite decision keep unknown old remote state untouched.
enum TransferRecovery {
  static func prepare(
    _ original: TransferManifest,
    staging: URL,
    partial: URL,
    prepareUpload:
      @Sendable (URL, String, URL, Bool) async throws -> TransferManifest
  ) async throws -> TransferManifest {
    if original.isComplete { return original }
    let fresh: TransferManifest
    switch original.direction {
    case .upload:
      fresh = try await prepareUpload(
        URL(fileURLWithPath: original.localPath),
        original.remotePath,
        staging,
        false
      )
    case .download:
      guard let destination = original.localDestinationPath else {
        throw SFTPTransferError.invalidManifest
      }
      try FileManager.default.createDirectory(
        at: partial,
        withIntermediateDirectories: true
      )
      fresh = try SFTPTransfers.prepareDownload(
        remotePath: original.remotePath,
        temporaryDirectory: partial,
        destination: URL(fileURLWithPath: destination)
      )
    }
    return TransferManifest(
      id: original.id,
      direction: fresh.direction,
      localPath: fresh.localPath,
      remotePath: fresh.remotePath,
      remoteTemporaryPath: fresh.remoteTemporaryPath,
      localDestinationPath: fresh.localDestinationPath,
      overwriteExisting: false,
      sourceSize: fresh.sourceSize,
      sourceSHA256: fresh.sourceSHA256
    )
  }
}
/// A legacy checkpoint has no owner. It cannot drive any network operation until
/// the user explicitly assigns it, restarting unfinished work without old handles
/// or overwrite consent. Known local transfers can be reviewed after cloud binding.
struct SavedTransfer: Hashable, Sendable, Identifiable {
  let owner: HostDataOwner?
  let manifest: TransferManifest
  var id: UUID { manifest.id }

  func canRecover(for target: HostDataOwner) -> Bool {
    guard let owner else { return true }
    return owner.account == nil && target.account != nil
      && owner.hasSameEndpoint(as: target)
  }
}
#endif
