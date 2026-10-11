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
  }

  /// Non-secret transfer checkpoints, one JSON file per manifest, so a
  /// transfer resumes with a fresh `SFTPClient` after reconnect or
  /// relaunch.
  struct TransferManifestStore: Sendable {
    let directory: URL

    init(directory: URL) {
      self.directory = directory
    }

    private func url(for id: UUID) -> URL {
      directory.appending(path: id.uuidString + ".json", directoryHint: .notDirectory)
    }

    func save(_ manifest: TransferManifest) throws {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try manifest.encoded().write(to: url(for: manifest.id), options: [.atomic])
    }

    func remove(_ id: UUID) {
      try? FileManager.default.removeItem(at: url(for: id))
    }

    func loadAll() -> [TransferManifest] {
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: nil
        )) ?? []
      return files.filter { $0.pathExtension == "json" }.compactMap { file in
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? TransferManifest.decode(data)
      }
    }
  }

  /// A transfer row: its latest checkpoint and what the user can do.
  struct TransferItem: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
      case running
      /// Stopped by the user or the connection; resumable.
      case paused(String)
      case completed
      case failed(String)
    }

    var manifest: TransferManifest
    var state: State
    var id: UUID { manifest.id }

    var name: String {
      let path =
        manifest.direction == .upload
        ? manifest.remotePath : (manifest.localDestinationPath ?? manifest.remotePath)
      return (path as NSString).lastPathComponent
    }

    var progress: Double? {
      guard manifest.sourceSize > 0 else { return nil }
      return min(1, Double(manifest.acknowledgedOffset) / Double(manifest.sourceSize))
    }
  }

  /// A file exported through the platform document picker.
  struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let url: URL

    init(url: URL) {
      self.url = url
    }

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
    enum Status: Hashable {
      case connecting
      case ready
      case failed(String)
    }

    let host: HostProfile
    private(set) var status = Status.connecting
    private(set) var path = ""
    private(set) var entries: [RemoteEntry] = []
    private(set) var transfers: [TransferItem] = []
    var message: String?
    var pendingOverwrite: PendingOverwrite?
    var exportDocument: ExportedFile?
    var exportName = ""
    var exporting = false

    @ObservationIgnored private weak var app: RoamingAppModel?
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var client: SFTPClient?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let store: TransferManifestStore

    init(host: HostProfile, app: RoamingAppModel) {
      self.host = host
      self.app = app
      root = RoamingStorage.directory
        .appending(path: "Transfers", directoryHint: .isDirectory)
        .appending(path: host.id.uuidString, directoryHint: .isDirectory)
      store = TransferManifestStore(
        directory: root.appending(path: "manifests", directoryHint: .isDirectory)
      )
      transfers = store.loadAll().map { manifest in
        TransferItem(
          manifest: manifest,
          state: manifest.isComplete
            ? .completed
            : manifest.state == .failed ? .failed("Needs attention") : .paused("Interrupted")
        )
      }
    }

    private var staging: URL { root.appending(path: "staging", directoryHint: .isDirectory) }
    private var partial: URL { root.appending(path: "partial", directoryHint: .isDirectory) }
    private var downloads: URL { root.appending(path: "downloads", directoryHint: .isDirectory) }

    var isPausedForTerminal: Bool { app?.transferPolicy.isPaused ?? false }

    // MARK: Connection

    /// Connects (or reconnects with fresh handles) and lists `path`.
    func connect() async {
      guard let app else { return }
      if let client, client.isActive { return }
      status = .connecting
      await disconnect()
      do {
        let connection = try await app.ssh.connect(host)
        self.connection = connection
        let client = try await connection.openSFTP()
        self.client = client
        if path.isEmpty { path = try await client.realpath(".") }
        status = .ready
        await list()
      } catch let error as SSHAccessError {
        status = .failed(error.title)
      } catch {
        status = .failed("SFTP is not available on this host.")
      }
    }

    private func disconnect() async {
      await client?.close()
      await connection?.close()
      client = nil
      connection = nil
    }

    /// Stops transfers (they stay resumable) and closes the connection.
    func shutdown() async {
      for task in tasks.values { task.cancel() }
      for task in tasks.values { await task.value }
      tasks = [:]
      await disconnect()
    }

    // MARK: Navigation

    func list() async {
      guard let client else { return }
      do {
        let raw = try await client.listDirectory(path)
        entries =
          raw
          .filter { !$0.filename.contains("/") }
          .compactMap { entry in
            let attributes = entry.attributes
            guard attributes.isDirectory || attributes.isRegularFile else { return nil }
            return RemoteEntry(
              name: entry.filename,
              path: Self.join(path, entry.filename),
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
        message = "This folder could not be listed."
        await reconnectIfNeeded()
      }
    }

    func open(_ entry: RemoteEntry) async {
      guard entry.isDirectory else { return }
      await navigate(to: entry.path)
    }

    func goUp() async {
      await navigate(to: Self.join(path, ".."))
    }

    private func navigate(to target: String) async {
      guard let client else { return }
      do {
        path = try await client.realpath(target)
        await list()
      } catch {
        message = "That folder is not available."
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
        let folder = downloads.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let manifest = try SFTPTransfers.prepareDownload(
          remotePath: entry.path,
          temporaryDirectory: partial,
          destination: folder.appending(path: entry.name, directoryHint: .notDirectory)
        )
        try store.save(manifest)
        transfers.append(TransferItem(manifest: manifest, state: .paused("Queued")))
        run(manifest.id)
      } catch {
        message = "The download could not be prepared."
      }
    }

    /// Stages `source` and uploads it into the current directory. An
    /// existing destination needs an explicit overwrite decision.
    func upload(from source: URL) async {
      let remotePath = Self.join(path, source.lastPathComponent)
      if let client, (try? await client.stat(remotePath)) != nil {
        pendingOverwrite = PendingOverwrite(source: source, remotePath: remotePath)
        return
      }
      await stage(source, remotePath: remotePath, overwrite: false)
    }

    func resolveOverwrite(_ replace: Bool) async {
      guard let pending = pendingOverwrite else { return }
      pendingOverwrite = nil
      if replace { await stage(pending.source, remotePath: pending.remotePath, overwrite: true) }
    }

    private func stage(_ source: URL, remotePath: String, overwrite: Bool) async {
      let scoped = source.startAccessingSecurityScopedResource()
      defer { if scoped { source.stopAccessingSecurityScopedResource() } }
      do {
        let manifest = try await SFTPTransfers.prepareUpload(
          source: source,
          remotePath: remotePath,
          stagingDirectory: staging,
          overwriteExisting: overwrite
        )
        try store.save(manifest)
        transfers.append(TransferItem(manifest: manifest, state: .paused("Queued")))
        run(manifest.id)
      } catch SFTPTransferError.notRegularFile {
        message = "Only regular files can be uploaded."
      } catch {
        message = "The file could not be staged for upload."
      }
    }

    func cancel(_ item: TransferItem) {
      tasks[item.id]?.cancel()
    }

    func resume(_ item: TransferItem) async {
      await connect()
      run(item.id)
    }

    /// Stops a transfer for good and removes its temporary files (and a
    /// downloaded copy kept in app storage).
    func remove(_ item: TransferItem) async {
      if let task = tasks[item.id] {
        task.cancel()
        await task.value
      }
      guard let index = transfers.firstIndex(where: { $0.id == item.id }) else { return }
      let manifest = transfers[index].manifest
      await SFTPTransfers.discard(manifest, client: client)
      if manifest.direction == .download, let destination = manifest.localDestinationPath {
        let folder = URL(fileURLWithPath: destination).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: folder)
      }
      store.remove(item.id)
      transfers.remove(at: index)
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
      guard tasks[id] == nil, let client, let app,
        let index = transfers.firstIndex(where: { $0.id == id })
      else {
        if client == nil { message = "Not connected." }
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
        } catch {
          failure = error
        }
        try? store.save(manifest)
        finish(id, manifest, failure)
      }
    }

    private func update(_ manifest: TransferManifest) {
      guard let index = transfers.firstIndex(where: { $0.id == manifest.id }) else { return }
      transfers[index].manifest = manifest
    }

    private func finish(_ id: UUID, _ manifest: TransferManifest, _ error: (any Error)?) {
      tasks[id] = nil
      guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
      transfers[index].manifest = manifest
      let state: TransferItem.State
      switch error {
      case nil:
        state = manifest.isComplete ? .completed : .paused("Incomplete")
      case is CancellationError:
        state = .paused("Cancelled")
      case SFTPTransferError.destinationExists?:
        state = .failed("The destination exists and was not replaced.")
      case SFTPTransferError.notRegularFile?:
        state = .failed("Only regular files can be transferred.")
      case SFTPTransferError.remoteSourceChanged?, SFTPTransferError.stagedSourceChanged?:
        state = .failed("The source changed during the transfer.")
      case SFTPTransferError.verificationFailed?:
        state = .failed("Verification failed.")
      case SFTPTransferError.renameOutcomeUncertain?:
        state = .failed("The upload's final rename could not be confirmed. Check the folder.")
      default:
        state =
          manifest.state == .failed
          ? .failed("The transfer failed.") : .paused("Interrupted; resumable")
      }
      transfers[index].state = state
      if case .ready = status, error != nil { Task { await reconnectIfNeeded() } }
      if manifest.isComplete, manifest.direction == .upload { Task { await list() } }
    }
  }

  /// Minimal SFTP browser sheet.
  public struct SFTPBrowserView: View {
    @State private var model: SFTPBrowserModel
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss
    private let app: RoamingAppModel

    public init(host: HostProfile, app: RoamingAppModel) {
      self.app = app
      _model = State(initialValue: SFTPBrowserModel(host: host, app: app))
    }

    public var body: some View {
      NavigationStack {
        List {
          if let message = model.message {
            Label(message, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.orange)
              .listRowBackground(Color.clear)
          }
          switch model.status {
          case .connecting:
            ProgressView("Connecting")
              .listRowBackground(Color.clear)
          case .failed(let reason):
            VStack(alignment: .leading) {
              Text(reason)
              Button("Try Again") { Task { await model.connect() } }
            }
            .listRowBackground(Color.clear)
            .glassButtonStyle()
          case .ready:
            directorySection
          }
          if !model.transfers.isEmpty { transferSection }
        }
        .glassListBackground()
        .navigationTitle(model.host.nickname)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
              .accessibilityIdentifier("sftp.done")
          }
          ToolbarItem(placement: .primaryAction) {
            Button("Upload", systemImage: "square.and.arrow.up") { importing = true }
              .disabled(model.status != .ready)
          }
        }
        .task { await model.connect() }
        .onAppear { app.modalDepth += 1 }
        .onDisappear {
          app.modalDepth -= 1
          Task { await model.shutdown() }
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
        ) { _ in
          model.exportDocument = nil
        }
        .alert(
          "Replace \u{201C}\(model.pendingOverwrite?.name ?? "")\u{201D}?",
          isPresented: overwriteBinding
        ) {
          Button("Replace", role: .destructive) {
            Task { await model.resolveOverwrite(true) }
          }
          Button("Cancel", role: .cancel) {
            Task { await model.resolveOverwrite(false) }
          }
        } message: {
          Text("A file with this name already exists in this folder on the Mac.")
        }
      }
      #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
      #endif
    }

    private var overwriteBinding: Binding<Bool> {
      Binding(
        get: { model.pendingOverwrite != nil },
        set: { if !$0, model.pendingOverwrite != nil { Task { await model.resolveOverwrite(false) } } }
      )
    }

    private var directorySection: some View {
      Section {
        if model.path != "/" {
          Button {
            Task { await model.goUp() }
          } label: {
            Label("..", systemImage: "arrow.turn.left.up")
          }
        }
        ForEach(model.entries) { entry in
          if entry.isDirectory {
            Button {
              Task { await model.open(entry) }
            } label: {
              Label(entry.name, systemImage: "folder")
            }
          } else {
            HStack {
              Label(entry.name, systemImage: "doc")
              Spacer()
              if let size = entry.size {
                Text(Int64(size), format: .byteCount(style: .file))
                  .foregroundStyle(.secondary)
                  .font(.caption)
              }
              Button("Download", systemImage: "arrow.down.circle") { model.download(entry) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
          }
        }
      } header: {
        Text(model.path).font(.caption.monospaced())
          .accessibilityIdentifier("sftp.path")
      }
      .listRowBackground(Color.clear)
    }

    private var transferSection: some View {
      Section {
        if model.isPausedForTerminal {
          Label("Paused while terminal input is pending", systemImage: "pause.circle")
            .foregroundStyle(.secondary)
        }
        ForEach(model.transfers) { item in
          VStack(alignment: .leading, spacing: 4) {
            Label(
              item.name,
              systemImage: item.manifest.direction == .upload ? "arrow.up.doc" : "arrow.down.doc"
            )
            if let progress = item.progress, item.state != .completed {
              ProgressView(value: progress)
            }
            HStack {
              Text(stateText(item.state)).font(.caption).foregroundStyle(.secondary)
              Spacer()
              actions(for: item)
            }
            .buttonStyle(.borderless)
          }
        }
      } header: {
        Text("Transfers")
      }
      .listRowBackground(Color.clear)
    }

    @ViewBuilder private func actions(for item: TransferItem) -> some View {
      switch item.state {
      case .running:
        Button("Cancel") { model.cancel(item) }
      case .paused:
        Button("Resume") { Task { await model.resume(item) } }
        Button("Remove", role: .destructive) { Task { await model.remove(item) } }
      case .completed:
        if item.manifest.direction == .download {
          Button("Save…") { model.export(item) }
        }
        Button("Remove", role: .destructive) { Task { await model.remove(item) } }
      case .failed:
        Button("Remove", role: .destructive) { Task { await model.remove(item) } }
      }
    }

    private func stateText(_ state: TransferItem.State) -> String {
      switch state {
      case .running: "Transferring"
      case .paused(let reason): reason
      case .completed: "Verified"
      case .failed(let reason): reason
      }
    }
  }
#endif
