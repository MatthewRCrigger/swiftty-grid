#if !os(tvOS)
import Foundation
import SSHClient
import Synchronization
import Testing
@testable import RoamingApp

private actor UploadPreparationGate {
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var open = false
  private(set) var arrivals = 0

  func wait() async {
    arrivals += 1
    guard !open else { return }
    await withCheckedContinuation { continuations.append($0) }
  }

  func release() {
    open = true
    let pending = continuations
    continuations = []
    for continuation in pending { continuation.resume() }
  }
}

private struct BrowserTimeout: Error { let condition: String }

@MainActor
private func browserEventually(
  _ condition: String,
  _ predicate: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !predicate() {
    guard ContinuousClock.now < deadline else {
      throw BrowserTimeout(condition: condition)
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct SFTPBrowserOwnershipTests {
    let host = HostProfile(
      nickname: "Owned SFTP",
      host: "localhost",
      username: "test"
    )

    @Test(arguments: [false, true])
    func failedNavigationAndReconnectLeaveNoPreviousRows(
      _ reconnect: Bool
    ) async throws {
      let fixture = try await TransferFixture.make()
      defer { Task { await fixture.cleanup() } }
      for name in ["first", "blocked"] {
        try FileManager.default.createDirectory(
          at: fixture.server.url("/" + name),
          withIntermediateDirectories: true
        )
      }
      try fixture.remoteFile("/first/old.txt", data: Data([1]))
      let app = RoamingAppModel()
      let model = SFTPBrowserModel(
        host: host,
        app: app,
        transferDirectory: fixture.local
      ) { try await fixture.server.connect() }
      defer { model.shutdown() }
      await model.connect()
      await model.open(
        .init(name: "first", path: "/first", isDirectory: true, size: nil)
      )
      #expect(model.entries.map(\.path) == ["/first/old.txt"])
      let rejected = reconnect ? "/first" : "/blocked"
      fixture.server.state.faults.withLock {
        $0.rejectedDirectoryPaths = [rejected]
      }
      if reconnect {
        await model.shutdown().value
        await model.start()
      } else {
        await model.open(
          .init(name: "blocked", path: "/blocked", isDirectory: true, size: nil)
        )
      }
      #expect(model.path == rejected)
      #expect(model.entries.isEmpty)
      #expect(model.message == "This folder could not be listed.")
      #expect(model.status == .ready)
      fixture.server.state.faults.withLock { $0.rejectedDirectoryPaths = [] }
      await model.open(
        .init(name: "first", path: "/first", isDirectory: true, size: nil)
      )
      #expect(model.entries.map(\.path) == ["/first/old.txt"])
      #expect(model.message == nil)
      await model.shutdown().value
      await fixture.cleanup()
    }

    @Test
    func slowerRefreshCannotReplaceNewerListingOfSamePath() async throws {
      let fixture = try await TransferFixture.make()
      defer { Task { await fixture.cleanup() } }
      try fixture.remoteFile("/old.txt", data: Data([1]))
      let app = RoamingAppModel()
      let model = SFTPBrowserModel(
        host: host,
        app: app,
        transferDirectory: fixture.local
      ) { try await fixture.server.connect() }
      defer { model.shutdown() }
      await model.connect()
      fixture.server.state.faults.withLock { $0.holdNextOpenResponse = true }
      let old = Task { await model.list() }
      defer { old.cancel() }
      try #require(
        try await waitUntil { @Sendable in
          fixture.server.state.heldSFTPResponse.withLock { $0 != nil }
        }
      )
      #expect(model.entries.isEmpty)
      try FileManager.default.removeItem(at: fixture.server.url("/old.txt"))
      try fixture.remoteFile("/new.txt", data: Data([2]))
      await model.list()
      #expect(model.entries.map(\.name) == ["new.txt"])
      fixture.server.state.heldSFTPResponse.withLock { pending in
        pending?()
        pending = nil
      }
      await old.value
      #expect(model.entries.map(\.name) == ["new.txt"])
      await model.shutdown().value
      await fixture.cleanup()
    }

    @Test(arguments: [false, true])
    func shutdownJoinsPreparationAndReopenCannotPublishItsUpload(
      _ overwrite: Bool
    ) async throws {
      let fixture = try await TransferFixture.make()
      defer { Task { await fixture.cleanup() } }
      let source = fixture.local.appendingPathComponent("source.bin")
      try Data([1, 2, 3]).write(to: source)
      if overwrite { try fixture.remoteFile("/source.bin", data: Data([9])) }
      let gate = UploadPreparationGate()
      defer { Task { await gate.release() } }
      let staged = Mutex<[String]>([])
      let app = RoamingAppModel()
      let model = SFTPBrowserModel(
        host: host,
        app: app,
        transferDirectory: fixture.local,
        connectSSH: { try await fixture.server.connect() },
        prepareUpload: { source, remote, directory, overwrite in
          // Deliberately ignores cancellation, like an already queued copy.
          await gate.wait()
          let manifest =
            try await Task.detached {
              try await SFTPTransfers.prepareUpload(
                source: source,
                remotePath: remote,
                stagingDirectory: directory,
                overwriteExisting: overwrite
              )
            }
            .value
          staged.withLock { $0.append(manifest.localPath) }
          return manifest
        }
      )
      defer { model.shutdown() }
      await model.connect()
      if overwrite {
        await model.upload(from: source)
        try #require(model.pendingOverwrite != nil)
      }
      let upload = Task {
        if overwrite {
          await model.resolveOverwrite(true)
        } else {
          await model.upload(from: source)
        }
      }
      defer { upload.cancel() }
      let deadline = ContinuousClock.now + .seconds(5)
      while await gate.arrivals == 0 {
        guard ContinuousClock.now < deadline else {
          throw BrowserTimeout(condition: "preparation gate")
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      let cleanup = model.shutdown()
      let repeated = model.shutdown()
      let finished = Mutex(0)
      let firstWaiter = Task {
        await cleanup.value;
        finished.withLock { $0 += 1 }
      }
      let secondWaiter = Task {
        await repeated.value;
        finished.withLock { $0 += 1 }
      }
      await model.start()
      #expect(model.status == .ready)
      #expect(model.pendingOverwrite == nil)
      model.message = "Current presentation"
      #expect(finished.withLock { $0 } == 0)
      await gate.release()
      await upload.value
      await firstWaiter.value
      await secondWaiter.value
      #expect(finished.withLock { $0 } == 2)
      #expect(model.transfers.isEmpty)
      #expect(model.message == "Current presentation")
      #expect(fixture.server.state.writes.withLock { $0 } == 0)
      #expect(
        staged.withLock {
          $0.allSatisfy { !FileManager.default.fileExists(atPath: $0) }
        }
      )
      let store = TransferManifestStore(
        directory: fixture.local.appendingPathComponent("manifests")
      )
      #expect(store.loadAll().isEmpty)
      #expect(
        fixture.remoteData("/source.bin") == (overwrite ? Data([9]) : nil)
      )
      let fresh = fixture.local.appendingPathComponent("fresh.bin")
      try Data([4, 5, 6]).write(to: fresh)
      await model.upload(from: fresh)
      try await browserEventually("fresh upload") {
        model.transfers.first?.state == .completed
      }
      #expect(fixture.remoteData("/fresh.bin") == Data([4, 5, 6]))
      await model.shutdown().value
      await fixture.cleanup()
    }

    @Test
    func failedCheckpointSaveDiscardsItsStagedUpload() async throws {
      let fixture = try await TransferFixture.make()
      defer { Task { await fixture.cleanup() } }
      let source = fixture.local.appendingPathComponent("unsaved.bin")
      try Data([1]).write(to: source)
      let staged = Mutex<String?>(nil)
      let app = RoamingAppModel()
      let model = SFTPBrowserModel(
        host: host,
        app: app,
        transferDirectory: fixture.local,
        connectSSH: { try await fixture.server.connect() },
        prepareUpload: { source, remote, directory, overwrite in
          let manifest = try await SFTPTransfers.prepareUpload(
            source: source,
            remotePath: remote,
            stagingDirectory: directory,
            overwriteExisting: overwrite
          )
          staged.withLock { $0 = manifest.localPath }
          return manifest
        }
      )
      defer { model.shutdown() }
      await model.connect()
      let blockedStore = fixture.local.appendingPathComponent("manifests")
      try Data([9]).write(to: blockedStore)
      await model.upload(from: source)
      #expect(model.transfers.isEmpty)
      #expect(model.message == "The file could not be staged for upload.")
      let path = try #require(staged.withLock { $0 })
      #expect(!FileManager.default.fileExists(atPath: path))
      #expect(try Data(contentsOf: blockedStore) == Data([9]))
      #expect(fixture.server.state.writes.withLock { $0 } == 0)
      await model.shutdown().value
      await fixture.cleanup()
    }

    @Test
    func callerCancellationDiscardsLatePreparationWithoutClosingBrowser()
      async throws
    {
      let fixture = try await TransferFixture.make()
      defer { Task { await fixture.cleanup() } }
      let source = fixture.local.appendingPathComponent("cancelled.bin")
      try Data([1]).write(to: source)
      let gate = UploadPreparationGate()
      defer { Task { await gate.release() } }
      let staged = Mutex<String?>(nil)
      let app = RoamingAppModel()
      let model = SFTPBrowserModel(
        host: host,
        app: app,
        transferDirectory: fixture.local,
        connectSSH: { try await fixture.server.connect() },
        prepareUpload: { source, remote, directory, overwrite in
          await gate.wait()
          let manifest =
            try await Task.detached {
              try await SFTPTransfers.prepareUpload(
                source: source,
                remotePath: remote,
                stagingDirectory: directory,
                overwriteExisting: overwrite
              )
            }
            .value
          staged.withLock { $0 = manifest.localPath }
          return manifest
        }
      )
      defer { model.shutdown() }
      await model.connect()
      let upload = Task { await model.upload(from: source) }
      defer { upload.cancel() }
      let deadline = ContinuousClock.now + .seconds(5)
      while await gate.arrivals == 0 {
        guard ContinuousClock.now < deadline else {
          throw BrowserTimeout(condition: "cancelled preparation gate")
        }
        try await Task.sleep(for: .milliseconds(5))
      }
      upload.cancel()
      await gate.release()
      await upload.value
      #expect(model.status == .ready)
      #expect(model.transfers.isEmpty)
      #expect(model.message == nil)
      let path = try #require(staged.withLock { $0 })
      #expect(!FileManager.default.fileExists(atPath: path))
      #expect(fixture.server.state.writes.withLock { $0 } == 0)
      await model.shutdown().value
      await fixture.cleanup()
    }
  }
}
#endif
