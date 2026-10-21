#if !os(tvOS)
import Foundation
import Observation
import SSHClient
import SessionCore
import SwiftUI
import UniformTypeIdentifiers

// Minimal SFTP on full clients only (spec §10): directory navigation,
// regular files, verified resumable upload/download, explicit overwrite
// decisions. tvOS compiles none of this.

/// One remote directory entry the browser offers: a directory or a
/// regular file. Links and special files are not listed.
struct RemoteEntry: Identifiable, Hashable, Sendable {
  var id: String { path }
  let name: String
  let path: String
  let isDirectory: Bool
  let size: UInt64?

  var sizeDescription: String? {
    guard let size else { return nil }
    guard let signedSize = Int64(exactly: size) else { return "\(size) bytes" }
    return signedSize.formatted(.byteCount(style: .file))
  }
}

/// A transfer row: its latest checkpoint and what the user can do.
struct TransferItem: Identifiable, Equatable, Sendable {
  enum State: Equatable, Sendable {
    case running
    /// Stopped by the user or the connection; resumable.
    case paused(LocalizedStringResource)
    case completed
    case failed(LocalizedStringResource)
  }

  var manifest: TransferManifest
  var state: State
  var id: UUID { manifest.id }

  var name: String {
    let path =
      manifest.direction == .upload
      ? manifest.remotePath
      : (manifest.localDestinationPath ?? manifest.remotePath)
    return (path as NSString).lastPathComponent
  }

  var progress: Double? {
    guard manifest.sourceSize > 0 else { return nil }
    return min(
      1,
      Double(manifest.acknowledgedOffset) / Double(manifest.sourceSize)
    )
  }
}

/// A file exported through the platform document picker.
struct ExportedFile: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }
  let url: URL

  init(url: URL) { self.url = url }

  init(configuration: ReadConfiguration) throws {
    throw CocoaError(.featureUnsupported)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    try FileWrapper(url: url, options: .immediate)
  }
}

/// An upload whose destination exists, awaiting an explicit decision.
struct PendingOverwrite: Identifiable, Sendable {
  let id = UUID()
  let source: URL
  let remotePath: String
  var name: String { (remotePath as NSString).lastPathComponent }
}

/// SFTP over its own SSH connection, separate from the terminal's.
@MainActor
@Observable
final class SFTPBrowserModel {
  enum Status: Equatable {
    case closed
    case connecting
    case ready
    case failed(LocalizedStringResource)
  }

  let host: HostProfile
  private(set) var status = Status.connecting
  private(set) var path = ""
  private(set) var entries: [RemoteEntry] = []
  private(set) var transfers: [TransferItem] = []
  var message: LocalizedStringResource?
  var pendingOverwrite: PendingOverwrite?
  /// The overwrite alert's binding: dismissing it keeps the remote file.
  var isOverwritePending: Bool {
    get { pendingOverwrite != nil }
    set {
      if !newValue, pendingOverwrite != nil {
        Task { await resolveOverwrite(false) }
      }
    }
  }
  var exportDocument: ExportedFile?
  var exportName = ""
  var exporting = false

  @ObservationIgnored
  private weak var app: RoamingAppModel?
  @ObservationIgnored
  private var connection: SSHConnection?
  @ObservationIgnored
  private var client: SFTPClient?
  @ObservationIgnored
  private var tasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored
  private var preparations: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored
  private var preparationGeneration = UUID()
  @ObservationIgnored
  private var retirement: Task<Void, Never>?
  @ObservationIgnored
  private var removing: Set<UUID> = []
  @ObservationIgnored
  private var connectionTask: Task<Void, Never>?
  @ObservationIgnored
  private var generation = UUID()
  @ObservationIgnored
  private var navigationID = UUID()
  @ObservationIgnored
  private var listingID = UUID()
  @ObservationIgnored
  private var isClosed = false
  private(set) var presentationID: UUID?
  @ObservationIgnored
  private let connectSSH: @MainActor () async throws -> SSHConnection
  @ObservationIgnored
  private let prepareUpload:
    @Sendable (URL, String, URL, Bool) async throws -> TransferManifest
  @ObservationIgnored
  private let root: URL
  @ObservationIgnored
  private let store: TransferManifestStore

  init(
    host: HostProfile,
    app: RoamingAppModel,
    transferDirectory: URL? = nil,
    connectSSH: (@MainActor () async throws -> SSHConnection)? = nil,
    prepareUpload:
      @escaping @Sendable (URL, String, URL, Bool) async throws ->
      TransferManifest = { source, remotePath, stagingDirectory, overwrite in
        try await SFTPTransfers.prepareUpload(
          source: source,
          remotePath: remotePath,
          stagingDirectory: stagingDirectory,
          overwriteExisting: overwrite
        )
      }
  ) {
    self.host = host
    self.app = app
    self.prepareUpload = prepareUpload
    self.connectSSH =
      connectSSH ?? { [weak app] in
        guard let app else { throw CancellationError() }
        return try await app.ssh.connect(host)
      }
    root =
      transferDirectory
      ?? RoamingStorage.directory
      .appending(path: "Transfers", directoryHint: .isDirectory)
      .appending(path: host.id.uuidString, directoryHint: .isDirectory)
    store = TransferManifestStore(
      directory: root.appending(path: "manifests", directoryHint: .isDirectory)
    )
    transfers = store.loadAll()
      .map { manifest in
        TransferItem(
          manifest: manifest,
          state: manifest.isComplete
            ? .completed
            : manifest.state == .failed
              ? .failed(.localized("Needs attention"))
              : .paused(.localized("Interrupted"))
        )
      }
  }

  private var staging: URL {
    root.appending(path: "staging", directoryHint: .isDirectory)
  }
  private var partial: URL {
    root.appending(path: "partial", directoryHint: .isDirectory)
  }
  private var downloads: URL {
    root.appending(path: "downloads", directoryHint: .isDirectory)
  }

  var isPausedForTerminal: Bool { app?.transferPolicy.isPaused ?? false }

  /// A browser holds prompt routing until its presentation ends, even if
  /// SwiftUI retains the sheet's view hierarchy after native dismissal.
  func beginPresentation() {
    guard presentationID == nil else { return }
    presentationID = UUID()
    app?.modalDepth += 1
  }

  func endPresentation() {
    guard presentationID != nil else { return }
    presentationID = nil
    app?.modalDepth -= 1
    shutdown()
  }

  func startPresentation(_ id: UUID) async {
    guard presentationID == id, !Task.isCancelled else { return }
    await start()
  }

  // MARK: Connection

  /// Starts a new presentation after the previous one shut down.
  func start() async {
    retirement = nil
    isClosed = false
    await connect()
  }

  /// Connects (or reconnects with fresh handles) and lists `path`.
  func connect() async {
    guard !isClosed else { return }
    if let client, client.isActive { return }
    if let task = connectionTask {
      await task.value
      return
    }
    generation = UUID()
    let generation = self.generation
    let task = Task { await establishConnection(generation: generation) }
    connectionTask = task
    await task.value
    guard generation == self.generation, !isClosed else { return }
    connectionTask = nil
    if status == .ready { await list() }
  }

  private func establishConnection(generation: UUID) async {
    guard generation == self.generation, !isClosed, !Task.isCancelled else {
      return
    }
    status = .connecting
    await disconnect()
    guard generation == self.generation, !isClosed, !Task.isCancelled else {
      return
    }
    do {
      let connection = try await connectSSH()
      guard generation == self.generation, !isClosed, !Task.isCancelled else {
        await connection.close()
        return
      }
      self.connection = connection
      let client = try await connection.openSFTP()
      guard generation == self.generation, !isClosed, !Task.isCancelled else {
        await client.close()
        await connection.close()
        return
      }
      self.client = client
      if path.isEmpty {
        let initialPath = try await client.realpath(".")
        guard generation == self.generation, !isClosed else { return }
        path = initialPath
      }
      status = .ready
    } catch {
      guard generation == self.generation, !isClosed else { return }
      await disconnect()
      guard generation == self.generation, !isClosed else { return }
      status = .failed(
        (error as? SSHAccessError)?.title
          ?? .localized("SFTP is not available on this host.")
      )
    }
  }

  private func disconnect() async {
    let client = self.client
    let connection = self.connection
    self.client = nil
    self.connection = nil
    await client?.close()
    await connection?.close()
  }

  /// Stops transfers (they stay resumable) and closes the connection.
  /// Revokes ownership synchronously, before the view can reappear.
  @discardableResult
  func shutdown() -> Task<Void, Never> {
    if isClosed, let retirement { return retirement }
    isClosed = true
    generation = UUID()
    preparationGeneration = UUID()
    pendingOverwrite = nil
    status = .closed
    connectionTask?.cancel()
    connectionTask = nil
    let pending = Array(tasks.values) + Array(preparations.values)
    for task in pending { task.cancel() }
    let client = self.client
    let connection = self.connection
    self.client = nil
    self.connection = nil
    let retirement = Task {
      await client?.close()
      await connection?.close()
      for task in pending { await task.value }
    }
    self.retirement = retirement
    return retirement
  }

  // MARK: Navigation

  func list() async {
    guard let client else { return }
    listingID = UUID()
    let listingID = self.listingID
    let generation = self.generation
    let navigationID = self.navigationID
    let directory = path
    entries = []
    message = nil
    do {
      let raw = try await client.listDirectory(directory)
      guard generation == self.generation, navigationID == self.navigationID,
        listingID == self.listingID, !isClosed, path == directory
      else { return }
      entries = raw.filter { !$0.filename.contains("/") }
        .compactMap { entry in
          let attributes = entry.attributes
          guard attributes.isDirectory || attributes.isRegularFile else {
            return nil
          }
          return RemoteEntry(
            name: entry.filename,
            path: Self.join(directory, entry.filename),
            isDirectory: attributes.isDirectory,
            size: attributes.isRegularFile ? attributes.size : nil
          )
        }
        .sorted {
          $0.isDirectory != $1.isDirectory
            ? $0.isDirectory
            : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    } catch {
      guard generation == self.generation, navigationID == self.navigationID,
        listingID == self.listingID, !isClosed, path == directory
      else { return }
      message = .localized("This folder could not be listed.")
      if !client.isActive {
        status = .failed(.localized("The SFTP connection was closed."))
      }
    }
  }

  func open(_ entry: RemoteEntry) async {
    guard entry.isDirectory else { return }
    await navigate(to: entry.path)
  }

  func goUp() async { await navigate(to: Self.join(path, "..")) }

  private func navigate(to target: String) async {
    guard let client else { return }
    navigationID = UUID()
    let navigationID = self.navigationID
    let generation = self.generation
    do {
      let path = try await client.realpath(target)
      guard generation == self.generation, navigationID == self.navigationID,
        !isClosed
      else { return }
      self.path = path
      entries = []
      await list()
    } catch {
      guard generation == self.generation, navigationID == self.navigationID,
        !isClosed
      else { return }
      message = .localized("That folder is not available.")
    }
  }

  private func reconnectIfNeeded() async {
    if let client, !client.isActive { await connect() }
  }

  static func join(_ directory: String, _ name: String) -> String {
    directory.hasSuffix("/") ? directory + name : directory + "/" + name
  }

  // MARK: Transfers

  /// Downloads into app storage first; the user publishes the verified
  /// file with the platform exporter afterwards.
  func download(_ entry: RemoteEntry) {
    guard !entry.isDirectory else { return }
    do {
      let folder = downloads.appending(
        path: UUID().uuidString,
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: folder,
        withIntermediateDirectories: true
      )
      try FileManager.default.createDirectory(
        at: partial,
        withIntermediateDirectories: true
      )
      let manifest = try SFTPTransfers.prepareDownload(
        remotePath: entry.path,
        temporaryDirectory: partial,
        destination: folder.appending(
          path: entry.name,
          directoryHint: .notDirectory
        )
      )
      try store.save(manifest)
      transfers.append(
        TransferItem(manifest: manifest, state: .paused(.localized("Queued")))
      )
      run(manifest.id)
    } catch { message = .localized("The download could not be prepared.") }
  }

  /// Stages `source` and uploads it into the current directory. An
  /// existing destination needs an explicit overwrite decision.
  func upload(from source: URL) async {
    guard !isClosed, !Task.isCancelled else { return }
    let remotePath = Self.join(path, source.lastPathComponent)
    let lifetime = preparationGeneration
    await preparing { [self] in
      if let client, (try? await client.stat(remotePath)) != nil {
        guard ownsPreparation(lifetime) else { return }
        pendingOverwrite = PendingOverwrite(
          source: source,
          remotePath: remotePath
        )
        return
      }
      guard ownsPreparation(lifetime) else { return }
      await stage(
        source,
        remotePath: remotePath,
        overwrite: false,
        lifetime: lifetime
      )
    }
  }

  func resolveOverwrite(_ replace: Bool) async {
    guard !isClosed, !Task.isCancelled, let pending = pendingOverwrite else {
      return
    }
    pendingOverwrite = nil
    if replace {
      let lifetime = preparationGeneration
      await preparing { [self] in
        await stage(
          pending.source,
          remotePath: pending.remotePath,
          overwrite: true,
          lifetime: lifetime
        )
      }
    }
  }

  private func preparing(_ body: @escaping @MainActor () async -> Void) async {
    let id = UUID()
    let task = Task {
      defer { preparations[id] = nil }
      guard !Task.isCancelled else { return }
      await body()
    }
    preparations[id] = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private func ownsPreparation(_ lifetime: UUID) -> Bool {
    !isClosed && preparationGeneration == lifetime && !Task.isCancelled
  }

  private func stage(
    _ source: URL,
    remotePath: String,
    overwrite: Bool,
    lifetime: UUID
  ) async {
    guard ownsPreparation(lifetime) else { return }
    let scoped = source.startAccessingSecurityScopedResource()
    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
    do {
      let manifest = try await prepareUpload(
        source,
        remotePath,
        staging,
        overwrite
      )
      guard ownsPreparation(lifetime) else {
        await SFTPTransfers.discard(manifest, client: nil)
        return
      }
      do { try store.save(manifest) } catch {
        await SFTPTransfers.discard(manifest, client: nil)
        throw error
      }
      transfers.append(
        TransferItem(manifest: manifest, state: .paused(.localized("Queued")))
      )
      run(manifest.id)
    } catch SFTPTransferError.notRegularFile {
      guard ownsPreparation(lifetime) else { return }
      message = .localized("Only regular files can be uploaded.")
    } catch {
      guard ownsPreparation(lifetime) else { return }
      message = .localized("The file could not be staged for upload.")
    }
  }

  func cancel(_ item: TransferItem) { tasks[item.id]?.cancel() }

  func resume(_ item: TransferItem) async {
    await connect()
    run(item.id)
  }

  /// Stops a transfer for good and removes its temporary files (and a
  /// downloaded copy kept in app storage).
  func remove(_ item: TransferItem) async {
    guard removing.insert(item.id).inserted else { return }
    defer { removing.remove(item.id) }
    if let task = tasks[item.id] {
      task.cancel()
      await task.value
    }
    guard let index = transfers.firstIndex(where: { $0.id == item.id }) else {
      return
    }
    let manifest = transfers[index].manifest
    await SFTPTransfers.discard(manifest, client: client)
    if manifest.direction == .download,
      let destination = manifest.localDestinationPath
    {
      let folder = URL(fileURLWithPath: destination).deletingLastPathComponent()
      try? FileManager.default.removeItem(at: folder)
    }
    store.remove(item.id)
    transfers.removeAll { $0.id == item.id }
  }

  func export(_ item: TransferItem) {
    guard item.manifest.direction == .download, item.state == .completed,
      let destination = item.manifest.localDestinationPath
    else { return }
    exportDocument = ExportedFile(url: URL(fileURLWithPath: destination))
    exportName = item.name
    exporting = true
  }

  private func run(_ id: UUID) {
    guard !isClosed, !removing.contains(id), tasks[id] == nil, let client,
      let app, let index = transfers.firstIndex(where: { $0.id == id })
    else {
      if client == nil { message = .localized("Not connected.") }
      return
    }
    let manifest = transfers[index].manifest
    guard !manifest.isComplete else { return }
    transfers[index].state = .running
    let gate = app.transferPolicy.gate
    let store = store
    let checkpoint: TransferCheckpoint = { [weak self] manifest in
      try? store.save(manifest)
      await self?.update(manifest)
    }
    tasks[id] = Task {
      var manifest = manifest
      var failure: (any Error)?
      do {
        if manifest.direction == .upload {
          try await SFTPTransfers.upload(
            &manifest,
            client: client,
            gate: gate,
            checkpoint: checkpoint
          )
        } else {
          try await SFTPTransfers.download(
            &manifest,
            client: client,
            gate: gate,
            checkpoint: checkpoint
          )
        }
      } catch { failure = error }
      try? store.save(manifest)
      finish(id, manifest, failure)
    }
  }

  private func update(_ manifest: TransferManifest) {
    guard let index = transfers.firstIndex(where: { $0.id == manifest.id })
    else { return }
    transfers[index].manifest = manifest
  }

  private func finish(
    _ id: UUID,
    _ manifest: TransferManifest,
    _ error: (any Error)?
  ) {
    tasks[id] = nil
    guard let index = transfers.firstIndex(where: { $0.id == id }) else {
      return
    }
    transfers[index].manifest = manifest
    let state: TransferItem.State
    switch error {
    case nil:
      state =
        manifest.isComplete ? .completed : .paused(.localized("Incomplete"))
    case is CancellationError: state = .paused(.localized("Cancelled"))
    case SFTPTransferError.destinationExists?:
      state = .failed(
        .localized("The destination exists and was not replaced.")
      )
    case SFTPTransferError.notRegularFile?:
      state = .failed(.localized("Only regular files can be transferred."))
    case SFTPTransferError.fileTooLarge?:
      state = .failed(.localized("This file is too large to download."))
    case SFTPTransferError.remoteSourceChanged?,
      SFTPTransferError.stagedSourceChanged?:
      state = .failed(.localized("The source changed during the transfer."))
    case SFTPTransferError.verificationFailed?:
      state = .failed(.localized("Verification failed."))
    case SFTPTransferError.renameOutcomeUncertain?:
      state = .failed(
        .localized(
          "The upload's final rename could not be confirmed. Check the folder."
        )
      )
    default:
      state =
        manifest.state == .failed
        ? .failed(.localized("The transfer failed."))
        : .paused(.localized("Interrupted; resumable"))
    }
    transfers[index].state = state
    if case .ready = status, error != nil { Task { await reconnectIfNeeded() } }
    if manifest.isComplete, manifest.direction == .upload {
      Task { await list() }
    }
  }
}

/// Minimal SFTP browser sheet.
public struct SFTPBrowserView: View {
  /// Created once, on first appearance: the model reads saved transfer
  /// manifests from disk, and `init` runs on every parent redraw.
  @State
  private var model: SFTPBrowserModel?
  private let host: HostProfile
  private let app: RoamingAppModel

  public init(host: HostProfile, app: RoamingAppModel) {
    self.host = host
    self.app = app
  }

  public var body: some View {
    Group {
      if let model {
        SFTPBrowserContent(model: model, app: app)
      } else {
        Color.clear.onAppear {
          model = SFTPBrowserModel(host: host, app: app)
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 480, minHeight: 420)
    #endif
  }
}

private struct SFTPBrowserContent: View {
  @Bindable
  var model: SFTPBrowserModel
  @State
  private var importing = false
  @Environment(\.dismiss)
  private var dismiss
  let app: RoamingAppModel

  var body: some View {
    NavigationStack {
      List {
        if let message = model.message {
          Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange).listRowBackground(Color.clear)
        }
        switch model.status {
        case .closed: EmptyView()
        case .connecting:
          ProgressView(.localized("Connecting")).listRowBackground(Color.clear)
        case .failed(let reason):
          VStack(alignment: .leading) {
            Text(reason)
            Button(.localized("Try Again")) { Task { await model.connect() } }
          }
          .listRowBackground(Color.clear).glassButtonStyle()
        case .ready: SFTPDirectorySection(model: model)
        }
        if !model.transfers.isEmpty { SFTPTransferSection(model: model) }
      }
      .glassListBackground().navigationTitle(model.host.nickname)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(.localized("Done")) { dismiss() }
            .accessibilityIdentifier("sftp.done")
        }
        ToolbarItem(placement: .primaryAction) {
          Button(.localized("Upload"), systemImage: "square.and.arrow.up") {
            importing = true
          }
          .disabled(model.status != .ready)
        }
      }
      .task(id: model.presentationID) { [id = model.presentationID] in
        if let id { await model.startPresentation(id) }
      }
      .onAppear { model.beginPresentation() }
      .onDisappear { model.endPresentation() }
      .background {
        #if os(macOS)
        SFTPBrowserSheetLifetime { [weak model] in model?.endPresentation() }
          .frame(width: 0, height: 0).allowsHitTesting(false)
          .accessibilityHidden(true)
        #endif
      }
      .connectionPrompts(app)
      .fileImporter(
        isPresented: $importing,
        allowedContentTypes: [.item],
        allowsMultipleSelection: false
      ) { result in
        if case let .success(urls) = result, let url = urls.first {
          Task { await model.upload(from: url) }
        }
      }
      .fileExporter(
        isPresented: $model.exporting,
        document: model.exportDocument,
        contentType: .data,
        defaultFilename: model.exportName
      ) { _ in model.exportDocument = nil }
      .alert(
        "Replace \u{201C}\(model.pendingOverwrite?.name ?? "")\u{201D}?",
        isPresented: $model.isOverwritePending
      ) {
        Button(.localized("Replace"), role: .destructive) {
          Task { await model.resolveOverwrite(true) }
        }
        Button(.localized("Cancel"), role: .cancel) {
          Task { await model.resolveOverwrite(false) }
        }
      } message: {
        Text(
          "A file with this name already exists in this folder on the Mac.",
          bundle: #bundle
        )
      }
    }
  }
}

private struct SFTPDirectorySection: View {
  let model: SFTPBrowserModel

  var body: some View {
    Section {
      if model.path != "/" {
        Button {
          Task { await model.goUp() }
        } label: {
          Label {
            Text(verbatim: "..")
          } icon: {
            Image(systemName: "arrow.turn.left.up")
          }
        }
      }
      ForEach(model.entries) { entry in
        RemoteEntryRow(entry: entry, model: model)
      }
    } header: {
      Text(model.path).font(.caption.monospaced())
        .accessibilityIdentifier("sftp.path")
    }
    .listRowBackground(Color.clear)
  }
}

/// One remote entry. A single top-level view for either kind, so `List`
/// can derive row identity without evaluating every row.
private struct RemoteEntryRow: View {
  let entry: RemoteEntry
  let model: SFTPBrowserModel

  var body: some View {
    HStack {
      if entry.isDirectory {
        Button {
          Task { await model.open(entry) }
        } label: {
          Label(entry.name, systemImage: "folder")
        }
      } else {
        Label(entry.name, systemImage: "doc")
        Spacer()
        if let size = entry.sizeDescription {
          Text(size).foregroundStyle(.secondary).font(.caption)
        }
        Button(.localized("Download"), systemImage: "arrow.down.circle") {
          model.download(entry)
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
      }
    }
  }
}

/// Transfers in their own section, so progress updates do not redraw the
/// directory listing.
private struct SFTPTransferSection: View {
  let model: SFTPBrowserModel

  var body: some View {
    Section {
      if model.isPausedForTerminal {
        Label(
          .localized("Paused while terminal input is pending"),
          systemImage: "pause.circle"
        )
        .foregroundStyle(.secondary)
      }
      ForEach(model.transfers) { item in
        TransferRow(item: item, model: model)
      }
    } header: {
      Text("Transfers", bundle: #bundle)
    }
    .listRowBackground(Color.clear)
  }
}

private struct TransferRow: View {
  let item: TransferItem
  let model: SFTPBrowserModel

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(
        item.name,
        systemImage: item.manifest.direction == .upload
          ? "arrow.up.doc" : "arrow.down.doc"
      )
      if let progress = item.progress, item.state != .completed {
        ProgressView(value: progress)
      }
      HStack {
        Text(stateText(item.state)).font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        actions
      }
      .buttonStyle(.borderless)
    }
  }

  @ViewBuilder
  private var actions: some View {
    switch item.state {
    case .running: Button(.localized("Cancel")) { model.cancel(item) }
    case .paused:
      Button(.localized("Resume")) { Task { await model.resume(item) } }
      Button(.localized("Remove"), role: .destructive) {
        Task { await model.remove(item) }
      }
    case .completed:
      if item.manifest.direction == .download {
        Button(.localized("Save…")) { model.export(item) }
      }
      Button(.localized("Remove"), role: .destructive) {
        Task { await model.remove(item) }
      }
    case .failed:
      Button(.localized("Remove"), role: .destructive) {
        Task { await model.remove(item) }
      }
    }
  }

  private func stateText(_ state: TransferItem.State) -> LocalizedStringResource
  {
    switch state {
    case .running: .localized("Transferring")
    case .paused(let reason): reason
    case .completed: .localized("Verified")
    case .failed(let reason): reason
    }
  }
}
#endif
