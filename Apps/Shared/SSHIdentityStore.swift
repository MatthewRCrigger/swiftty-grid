import Crypto
import Foundation
import SSHClient
import SSHIdentity

/// Keychain wiring from build configuration (spec.ssh-identity.md §10).
/// `SwifttyKeychainAccessGroup` in Info.plist carries the expanded
/// `$(AppIdentifierPrefix)dev.chr33s.swiftty` group; an unexpanded or
/// missing value (unsigned SwiftPM hosts) uses the default group.
enum IdentityKeychainConfiguration {
  static var accessGroup: String? {
    guard
      let group = Bundle.main.object(
        forInfoDictionaryKey: "SwifttyKeychainAccessGroup"
      ) as? String, !group.isEmpty, !group.hasPrefix("."), !group.contains("$(")
    else { return nil }
    return group
  }

  static func secretStore() -> any IdentitySecretStore {
    if UITesting.storageDirectory != nil {
      return InMemoryIdentitySecretStore()
    }
    return KeychainIdentitySecretStore(accessGroup: accessGroup)
  }

  static func legacyKeySource() -> any LegacyKeySource {
    if UITesting.storageDirectory != nil { return InMemoryLegacyKeySource() }
    return KeychainLegacyKeySource()
  }
}

/// Why an identity operation did not complete. Messages carry no secrets.
public enum IdentityOperationError: Error, Hashable, Sendable {
  case invalidName
  case tooManyIdentities
  case cancelled
  /// The connection snapshot could not be written.
  case storeUnavailable
  case keychain(IdentitySecretError)
  case integrityConflict
  case importFailed(OpenSSHImportError)
  case notFound
  /// iCloud Keychain identities need a verified current iCloud account.
  case accountRequired
  case unavailable(IdentityResolutionError)
  /// The supplied key is not the one this identity names.
  case publicKeyMismatch
  /// Saved, but not yet readable to verify; finished automatically later.
  case pendingVerification
  /// An unrecognized iCloud Keychain item, which may belong to another
  /// device: restore it rather than delete it.
  case syncedOrphan

  public var message: String {
    switch self {
    case .invalidName: "Enter a name of up to 64 characters."
    case .tooManyIdentities:
      "You can save up to \(ConnectionStore.maxIdentities) keys."
    case .cancelled: "Cancelled. No key was saved."
    case .storeUnavailable: "Saved keys could not be written."
    case .keychain(.protectedDataUnavailable):
      "Unlock this device, then try again."
    case .keychain(.missingEntitlement):
      "This build cannot use the Keychain. No key was saved."
    case .keychain: "The Keychain refused the operation."
    case .integrityConflict:
      "A different key is already stored for this identity. Nothing was replaced."
    case .importFailed(let error): error.message
    case .notFound: "The key no longer exists."
    case .accountRequired:
      "Sign in to iCloud to create a key that syncs with iCloud Keychain."
    case .unavailable(let error):
      (error.availability ?? .unsupported).summary + "."
    case .syncedOrphan:
      "This key syncs with iCloud Keychain and may be in use on your other "
        + "devices. Restore it, or turn on iCloud Sync to see its details."
    case .pendingVerification:
      "The key was saved but could not be checked yet. It appears here once "
        + "this device is unlocked; don't create it again."
    case .publicKeyMismatch:
      "That key does not match this identity's fingerprint."
    }
  }
}

/// SSH identity lifecycle over the Keychain and the connection snapshot
/// (§5, §7). Every change follows a durable intent: record it, write the
/// Keychain item, read it back and verify, then publish metadata and
/// complete in one commit. There is no load-or-create operation, and login
/// resolution (`resolve`) never mutates anything.
@MainActor
public final class SSHIdentityStore {
  private weak var app: RoamingAppModel?
  public let secrets: any IdentitySecretStore
  let legacy: any LegacyKeySource
  /// Confirms a current iCloud account before an iCloud identity is made.
  var verifyICloudAccount: @MainActor () async -> Bool = {
    FileManager.default.ubiquityIdentityToken != nil
  }

  init(
    app: RoamingAppModel,
    secrets: any IdentitySecretStore,
    legacy: any LegacyKeySource
  ) {
    self.app = app
    self.secrets = secrets
    self.legacy = legacy
  }

  private var snapshot: ConnectionSnapshot {
    app?.connections ?? ConnectionSnapshot()
  }

  private func commit(
    _ mutate: (inout ConnectionSnapshot) throws(ConnectionStore.StoreError) ->
      Void
  ) throws(IdentityOperationError) {
    guard let app, app.commitConnections(mutate) else {
      throw .storeUnavailable
    }
  }

  // MARK: Resolution

  /// Exactly the selected identity, verified, for one authentication.
  public func resolve(
    _ id: UUID
  ) async throws(IdentityResolutionError) -> IdentitySecret {
    // Another iCloud account's identities are quarantined, not usable.
    guard snapshot.isVisible(ConnectionSnapshot.identityRecord(id)) else {
      throw .unknownIdentity
    }
    if snapshot.identityConflicts[id] != nil { throw .integrityConflict }
    return try await IdentityResolver(secrets: secrets)
      .resolve(snapshot.identity(id))
  }

  public func availability(_ id: UUID) async -> IdentityAvailability {
    guard let metadata = snapshot.identity(id) else { return .unsupported }
    if snapshot.identityConflicts[id] != nil { return .integrityConflict }
    return await IdentityResolver(secrets: secrets).availability(of: metadata)
  }

  // MARK: Creation

  /// Generates and saves a new Ed25519 identity. The identity appears in
  /// pickers only after its key is stored and verified.
  public func generate(
    name: String,
    policy: IdentityStoragePolicy
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    try await create(
      IdentitySecret(SSHEd25519Key.generate()),
      name: name,
      policy: policy,
      kind: .generate
    )
  }

  /// Imports an unencrypted OpenSSH Ed25519 key after the user confirmed
  /// its fingerprint (see `inspect`).
  public func importKey(
    _ data: Data,
    name: String,
    policy: IdentityStoragePolicy
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    let key: ImportedOpenSSHKey
    do {
      key = try await OpenSSHImportGate.shared.decode(data)
    } catch .cancelled { throw .cancelled } catch { throw .importFailed(error) }
    return try await create(
      key.secret,
      name: name,
      policy: policy,
      kind: .importKey
    )
  }

  /// Parses `data` for confirmation without saving anything.
  public func inspect(
    _ data: Data
  ) async throws(IdentityOperationError) -> OpenSSHKeyInspection {
    do {
      return try await OpenSSHImportGate.shared.decode(data).inspection
    } catch { throw .importFailed(error) }
  }

  /// Identities already holding this public key: duplicate detection only,
  /// never a substitute at login.
  public func identities(
    withFingerprint fingerprint: String
  ) -> [SSHIdentityMetadata] {
    snapshot.visibleIdentities.filter { $0.fingerprint == fingerprint }
  }

  private func create(
    _ secret: IdentitySecret,
    name: String,
    policy: IdentityStoragePolicy,
    kind: IdentityIntent.Kind,
    reassign: [UUID] = [],
    id: UUID = UUID()
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    guard SSHIdentityMetadata.isValidName(name) else { throw .invalidName }
    guard snapshot.visibleIdentities.count < ConnectionStore.maxIdentities
    else { throw .tooManyIdentities }
    if policy == .iCloudKeychain {
      guard await verifyICloudAccount() else { throw .accountRequired }
    }
    guard !Task.isCancelled else { throw .cancelled }
    let metadata = SSHIdentityMetadata(
      id: id,
      name: name,
      publicKey: secret.publicKey,
      storage: policy,
      revision: LogicalRevision(counter: 0, deviceID: snapshot.deviceID)
    )
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: kind,
      policy: policy,
      name: name,
      publicKey: metadata.publicKey,
      reassign: reassign,
      stage: .recorded,
      createdAt: .now
    )
    try commit { $0.intents.append(intent) }
    // Create without overwriting. A duplicate may be an earlier attempt's
    // item; verification decides.
    do {
      try await secrets.add(secret, id: id, policy: policy)
    } catch .duplicate {} catch {
      // Nothing was written: forget the intent.
      try? commit { $0.intents.removeAll { $0.id == intent.id } }
      throw .keychain(error)
    }
    do { try await verify(intent) } catch .integrityConflict {
      // A different key holds this UUID: never replaced or published.
      try? commit { $0.intents.removeAll { $0.id == intent.id } }
      throw .integrityConflict
    } catch {
      // Written but not yet verifiable (for example the device locked):
      // the intent stays, and `recover()` verifies and publishes it.
      throw .pendingVerification
    }
    guard !Task.isCancelled else {
      try? await secrets.delete(id: id, policy: policy)
      try? commit { $0.intents.removeAll { $0.id == intent.id } }
      throw .cancelled
    }
    try publish(intent)
    guard let published = snapshot.identity(id) else { throw .storeUnavailable }
    return published
  }

  private func verify(
    _ intent: IdentityIntent
  ) async throws(IdentityOperationError) {
    let stored: IdentitySecret
    do {
      stored = try await secrets.read(
        id: intent.identityID,
        policy: intent.policy
      )
    } catch { throw .keychain(error) }
    guard
      SSHEd25519Key.authorizedKeysLine(for: stored.publicKey)
        == intent.publicKey
    else { throw .integrityConflict }
  }

  /// Publishes verified metadata and completes the intent in one commit.
  private func publish(_ intent: IdentityIntent) throws(IdentityOperationError)
  {
    guard let key = SSHIdentityMetadata.ed25519PublicKey(line: intent.publicKey)
    else { throw .integrityConflict }
    try commit { snapshot in
      snapshot.insertIdentity(
        SSHIdentityMetadata(
          id: intent.identityID,
          name: intent.name,
          publicKey: key,
          storage: intent.policy,
          createdAt: intent.createdAt,
          revision: LogicalRevision(counter: 0, deviceID: snapshot.deviceID)
        )
      )
      Self.reassign(intent.reassign, to: intent.identityID, in: &snapshot)
      switch intent.kind {
      case .withdraw(let source):
        snapshot.tombstoneIdentity(source)
        if let old = snapshot.identity(source) {
          snapshot.intents.append(Self.deletion(of: old))
        }
      case .migrateLegacy(let label):
        for host in snapshot.hosts where host.auth == .legacyKey(label: label) {
          var moved = host
          moved.auth = .key(identityID: intent.identityID)
          snapshot.upsertHost(moved)
        }
        snapshot.migration.pendingCleanup.append(label)
      default: break
      }
      snapshot.intents.removeAll { $0.id == intent.id }
    }
  }

  private static func reassign(
    _ hosts: [UUID],
    to id: UUID,
    in snapshot: inout ConnectionSnapshot
  ) {
    for hostID in hosts {
      guard var host = snapshot.hosts.first(where: { $0.id == hostID }) else {
        continue
      }
      host.auth = .key(identityID: id)
      snapshot.upsertHost(host)
    }
  }

  private static func deletion(
    of identity: SSHIdentityMetadata
  ) -> IdentityIntent {
    IdentityIntent(
      id: UUID(),
      identityID: identity.id,
      kind: .deleteSecret,
      policy: identity.storage,
      name: identity.name,
      publicKey: identity.publicKey,
      reassign: [],
      stage: .recorded,
      createdAt: .now
    )
  }

  // MARK: Changes

  public func rename(_ id: UUID, to name: String) throws(IdentityOperationError)
  {
    guard SSHIdentityMetadata.isValidName(name) else { throw .invalidName }
    guard snapshot.identity(id)?.isDeleted == false else { throw .notFound }
    try commit { $0.renameIdentity(id, to: name) }
  }

  /// Deletes an identity: publishes its tombstone, then deletes exactly its
  /// own Keychain item (an iCloud item's deletion propagates to the user's
  /// other devices). Referencing hosts keep their now-unresolved reference;
  /// the server's `authorized_keys` is untouched.
  public func delete(_ id: UUID) async throws(IdentityOperationError) {
    guard let identity = snapshot.identity(id), !identity.isDeleted else {
      throw .notFound
    }
    let intent = Self.deletion(of: identity)
    try commit { snapshot in
      snapshot.tombstoneIdentity(id)
      snapshot.intents.append(intent)
    }
    await finishDeletion(intent)
  }

  private func finishDeletion(_ intent: IdentityIntent) async {
    do {
      try await secrets.delete(id: intent.identityID, policy: intent.policy)
      try? commit { $0.intents.removeAll { $0.id == intent.id } }
    } catch {
      // Kept for retry on the next launch or recovery pass.
    }
  }

  /// **Create an iCloud copy**: a new UUID for the same key material in
  /// iCloud Keychain, after explicit consent. `reassign` hosts move to it
  /// in the same commit; the original stays until deleted.
  public func createICloudCopy(
    of id: UUID,
    name: String,
    reassign: [UUID]
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    let secret = try await sourceSecret(id)
    return try await create(
      secret,
      name: name,
      policy: .iCloudKeychain,
      kind: .iCloudCopy(source: id),
      reassign: reassign
    )
  }

  /// **Withdraw from iCloud and keep locally**: a verified device-only copy
  /// first, then host reassignment, then the old identity's tombstone and
  /// exact synchronizable-item deletion, retried until done. Not a remote
  /// revocation, and no proof that every prior copy was erased.
  public func withdrawFromICloud(
    _ id: UUID,
    name: String,
    reassign: [UUID]
  ) async throws(IdentityOperationError) -> SSHIdentityMetadata {
    guard snapshot.identity(id)?.storage == .iCloudKeychain else {
      throw .notFound
    }
    let secret = try await sourceSecret(id)
    let copy = try await create(
      secret,
      name: name,
      policy: .deviceOnly,
      kind: .withdraw(source: id),
      reassign: reassign
    )
    for intent in snapshot.intents
    where intent.kind == .deleteSecret && intent.identityID == id {
      await finishDeletion(intent)
    }
    return copy
  }

  private func sourceSecret(
    _ id: UUID
  ) async throws(IdentityOperationError) -> IdentitySecret {
    do { return try await resolve(id) } catch { throw .unavailable(error) }
  }

  /// Restores a missing key for an existing identity from an imported file
  /// whose public key exactly matches. The caller confirms the match first.
  public func repair(
    _ id: UUID,
    with data: Data
  ) async throws(IdentityOperationError) {
    guard let identity = snapshot.identity(id), !identity.isDeleted else {
      throw .notFound
    }
    let key: ImportedOpenSSHKey
    do { key = try await OpenSSHImportGate.shared.decode(data) } catch {
      throw .importFailed(error)
    }
    guard
      SSHEd25519Key.authorizedKeysLine(for: key.secret.publicKey)
        == identity.publicKey
    else { throw .publicKeyMismatch }
    do {
      try await secrets.add(key.secret, id: id, policy: identity.storage)
    } catch .duplicate {} catch { throw .keychain(error) }
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: .importKey,
      policy: identity.storage,
      name: identity.name,
      publicKey: identity.publicKey,
      reassign: [],
      stage: .secretWritten,
      createdAt: .now
    )
    try await verify(intent)
  }

  // MARK: Orphans

  /// Keychain items in this app's exact namespace with no identity or
  /// pending intent. Shown for explicit approval; never published
  /// automatically.
  public func orphans() async -> [(id: UUID, policy: IdentityStoragePolicy)] {
    var known = Set(snapshot.identities.map(\.id))
    known.formUnion(snapshot.intents.map(\.identityID))
    known.formUnion(snapshot.identityConflicts.keys)
    var found: [(UUID, IdentityStoragePolicy)] = []
    for policy in IdentityStoragePolicy.allCases {
      guard let ids = try? await secrets.storedIdentities(policy: policy) else {
        continue
      }
      for id in ids.subtracting(known)
        .sorted(by: { $0.uuidString < $1.uuidString })
      { found.append((id, policy)) }
    }
    return found
  }

  /// Publishes an orphaned item under its own UUID after user approval.
  public func adoptOrphan(
    _ id: UUID,
    policy: IdentityStoragePolicy,
    name: String
  ) async throws(IdentityOperationError) {
    guard SSHIdentityMetadata.isValidName(name) else { throw .invalidName }
    let secret: IdentitySecret
    do { secret = try await secrets.read(id: id, policy: policy) } catch {
      throw .keychain(error)
    }
    let intent = IdentityIntent(
      id: UUID(),
      identityID: id,
      kind: .importKey,
      policy: policy,
      name: name,
      publicKey: SSHEd25519Key.authorizedKeysLine(for: secret.publicKey),
      reassign: [],
      stage: .verified,
      createdAt: .now
    )
    try publish(intent)
  }

  public func deleteOrphan(
    _ id: UUID,
    policy: IdentityStoragePolicy
  ) async throws(IdentityOperationError) {
    guard snapshot.identity(id) == nil else { throw .integrityConflict }
    // A synchronizable item without metadata here may be another device's
    // key in transit; deleting it would remove it everywhere.
    guard policy == .deviceOnly else { throw .syncedOrphan }
    do { try await secrets.delete(id: id, policy: policy) } catch {
      throw .keychain(error)
    }
  }

  // MARK: Recovery and migration

  private var recovery: Task<Void, Never>?
  var isRecovering: Bool { recovery != nil }

  /// Resumes interrupted intents and the version-1 label migration, joining
  /// a pass already in flight. Safe to run repeatedly: mappings, UUIDs and
  /// fingerprints are stable across reruns, and a temporarily locked
  /// Keychain defers rather than counting a key as missing.
  public func recover() async { await startRecovery().value }

  @discardableResult
  func startRecovery() -> Task<Void, Never> {
    if let recovery { return recovery }
    let task = Task {
      await performRecovery()
      recovery = nil
    }
    recovery = task
    return task
  }

  private func performRecovery() async {
    for intent in snapshot.intents { await resume(intent) }
    await migrateLegacyLabels()
    await cleanUpLegacyItems()
  }

  private func resume(_ intent: IdentityIntent) async {
    switch intent.kind {
    case .deleteSecret: await finishDeletion(intent)
    case .generate, .importKey, .iCloudCopy, .withdraw, .migrateLegacy:
      do {
        try await verify(intent)
        try publish(intent)
        if case .withdraw(let source) = intent.kind {
          for pending in snapshot.intents
          where pending.kind == .deleteSecret && pending.identityID == source {
            await finishDeletion(pending)
          }
        }
      } catch .keychain(.notFound) {
        // The item was never written. Nothing was published, so the
        // intent is dropped: a generated or imported secret is gone, and a
        // copy, withdrawal or migration can be retried from its source.
        try? commit { $0.intents.removeAll { $0.id == intent.id } }
      } catch {
        // Locked, entitlement or store failures: keep for a later pass.
      }
    }
  }

  /// §9 steps 2–5, one label at a time.
  func migrateLegacyLabels() async {
    let labels = Set(
      snapshot.hosts.compactMap {
        if case .legacyKey(let label) = $0.auth { return label }
        return nil
      }
    )
    .subtracting(snapshot.migration.unresolved)
    guard !snapshot.migration.completed || !labels.isEmpty else { return }
    var deferred = false
    for label in labels.sorted() {
      // A stable mapping, persisted before any Keychain write.
      if snapshot.migration.labelMap[label] == nil {
        guard (try? commit({ $0.migration.labelMap[label] = UUID() })) != nil
        else { return }
      }
      guard let id = snapshot.migration.labelMap[label] else { return }
      if snapshot.identity(id) != nil {
        // Published by an earlier run; finish the host references.
        try? commit { snapshot in
          for host in snapshot.hosts where host.auth == .legacyKey(label: label)
          {
            var moved = host
            moved.auth = .key(identityID: id)
            snapshot.upsertHost(moved)
          }
        }
        continue
      }
      let secret: IdentitySecret
      do { secret = try await legacy.read(label: label) } catch .notFound {
        try? commit { $0.migration.unresolved.append(label) }
        continue
      } catch {
        deferred = true
        continue
      }
      let name = SSHIdentityMetadata.isValidName(label) ? label : "Migrated key"
      do {
        _ = try await create(
          secret,
          name: name,
          policy: .deviceOnly,
          kind: .migrateLegacy(label: label),
          id: id
        )
      } catch { deferred = true }
    }
    if !deferred { try? commit { $0.migration.completed = true } }
  }

  /// §9 step 6: legacy items go only after verified replacement and
  /// committed references.
  func cleanUpLegacyItems() async {
    for label in snapshot.migration.pendingCleanup {
      guard let id = snapshot.migration.labelMap[label],
        let identity = snapshot.identity(id), !identity.isDeleted,
        await IdentityResolver(secrets: secrets).availability(of: identity)
          == .available,
        !snapshot.hosts.contains(where: { $0.auth == .legacyKey(label: label) })
      else { continue }
      do {
        try await legacy.delete(label: label)
        try? commit { $0.migration.pendingCleanup.removeAll { $0 == label } }
      } catch { continue }
    }
  }
}
