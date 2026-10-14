#if !os(tvOS)
import Foundation
import Testing
import Synchronization
import SSHClient
@testable import RoamingApp

struct SFTPBrowserTests {
  @Test
  func remoteFileSizeDisplayHandlesUnsignedServerMetadata() {
    func entry(_ size: UInt64?) -> RemoteEntry {
      RemoteEntry(name: "file", path: "/file", isDirectory: false, size: size)
    }
    #expect(entry(nil).sizeDescription == nil)
    #expect(
      entry(0).sizeDescription == Int64(0).formatted(.byteCount(style: .file))
    )
    #expect(
      entry(UInt64(Int64.max)).sizeDescription
        == Int64.max.formatted(.byteCount(style: .file))
    )
    #expect(entry(UInt64.max).sizeDescription == "18446744073709551615 bytes")
  }
}

private actor BrowserConnectionGate {
  private var continuation: CheckedContinuation<Void, Never>?
  func wait() async { await withCheckedContinuation { continuation = $0 } }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct SFTPBrowserLifecycleTests {
    let host = HostProfile(
      nickname: "Test",
      host: "localhost",
      username: "test"
    )

    @Test
    func concurrentConnectsShareOneAttempt() async throws {
      let fixture = try await TransferFixture.make()
      defer { Task { await fixture.cleanup() } }
      let gate = BrowserConnectionGate()
      let attempts = Mutex(0)
      let app = RoamingAppModel()
      let model = SFTPBrowserModel(host: host, app: app) {
        attempts.withLock { $0 += 1 }
        await gate.wait()
        return try await fixture.server.connect()
      }
      let first = Task { await model.connect() }
      #expect(
        try await waitUntil { @Sendable in attempts.withLock { $0 } == 1 }
      )
      let second = Task { await model.connect() }
      try await Task.sleep(for: .milliseconds(50))
      #expect(attempts.withLock { $0 } == 1)
      await gate.release()
      await first.value
      await second.value
      #expect(model.status == .ready)
      await model.shutdown().value
    }

    @Test
    func shutdownAndReopenRejectTheOldConnection() async throws {
      let fixture = try await TransferFixture.make()
      defer { Task { await fixture.cleanup() } }
      let gate = BrowserConnectionGate()
      let attempts = Mutex(0)
      let connections = Mutex<[Int: SSHConnection]>([:])
      let app = RoamingAppModel()
      let model = SFTPBrowserModel(host: host, app: app) {
        let attempt = attempts.withLock { count in
          count += 1;
          return count
        }
        if attempt == 1 { await gate.wait() }
        // This connector deliberately ignores cancellation, so it can hand back
        // the old socket after shutdown. The owned detached task is always joined.
        let connection =
          try await Task.detached { [server = fixture.server] in
            try await server.connect()
          }
          .value
        connections.withLock { $0[attempt] = connection }
        return connection
      }
      let old = Task { await model.connect() }
      #expect(
        try await waitUntil { @Sendable in attempts.withLock { $0 } == 1 }
      )
      await model.shutdown().value
      #expect(model.status == .closed)
      // A delayed reconnect callback from the dismissed view must stay closed.
      await model.connect()
      #expect(attempts.withLock { $0 } == 1)
      await model.start()
      #expect(model.status == .ready)
      await gate.release()
      await old.value
      #expect(model.status == .ready)
      #expect(connections.withLock { $0[1]?.isActive } == false)
      #expect(connections.withLock { $0[2]?.isActive } == true)
      await model.shutdown().value
      #expect(connections.withLock { $0[2]?.isActive } == false)
    }

    @Test
    func delayedNavigationCannotReplaceTheNewerDirectory() async throws {
      let fixture = try await TransferFixture.make()
      defer { Task { await fixture.cleanup() } }
      for directory in ["first", "second"] {
        try FileManager.default.createDirectory(
          at: fixture.server.url("/" + directory),
          withIntermediateDirectories: true
        )
        try fixture.remoteFile(
          "/\(directory)/\(directory).txt",
          data: Data([1])
        )
      }
      let app = RoamingAppModel()
      let model = SFTPBrowserModel(host: host, app: app) {
        try await fixture.server.connect()
      }
      await model.connect()
      #expect(model.status == .ready)
      fixture.server.state.faults.withLock {
        $0.holdNextRealpathResponse = true
      }
      let first = Task {
        await model.open(
          RemoteEntry(
            name: "first",
            path: "/first",
            isDirectory: true,
            size: nil
          )
        )
      }
      #expect(
        try await waitUntil { @Sendable in
          fixture.server.state.heldSFTPResponse.withLock { $0 != nil }
        }
      )
      await model.open(
        RemoteEntry(
          name: "second",
          path: "/second",
          isDirectory: true,
          size: nil
        )
      )
      #expect(model.path == "/second")
      fixture.server.state.heldSFTPResponse.withLock { pending in
        pending?()
        pending = nil
      }
      await first.value
      #expect(model.path == "/second")
      #expect(model.entries.map(\.name) == ["second.txt"])
      await model.shutdown().value
    }

    @Test
    func shutdownCancelsAStalledDownloadAndKeepsItResumable() async throws {
      let fixture = try await TransferFixture.make()
      defer { Task { await fixture.cleanup() } }
      let data = Data(repeating: 7, count: 32 * 1024)
      try fixture.remoteFile("/source.bin", data: data)
      let app = RoamingAppModel()
      let model = SFTPBrowserModel(
        host: host,
        app: app,
        transferDirectory: fixture.local
      ) { try await fixture.server.connect() }
      await model.connect()
      fixture.server.state.faults.withLock { $0.holdNextReadResponse = true }
      model.download(
        RemoteEntry(
          name: "source.bin",
          path: "/source.bin",
          isDirectory: false,
          size: UInt64(data.count)
        )
      )
      #expect(
        try await waitUntil { @Sendable in
          fixture.server.state.heldSFTPResponse.withLock { $0 != nil }
        }
      )
      let finished = Mutex(false)
      let cleanup = model.shutdown()
      let waiter = Task {
        await cleanup.value;
        finished.withLock { $0 = true }
      }
      #expect(
        try await waitUntil(timeout: .seconds(1)) { @Sendable in
          finished.withLock { $0 }
        }
      )
      // Drop the server-side retained reply after the subsystem closed.
      fixture.server.state.heldSFTPResponse.withLock { $0 = nil }
      await waiter.value
      #expect(model.status == .closed)
      let item = try #require(model.transfers.first)
      if case .paused = item.state {
      } else {
        Issue.record("Cancelled download should remain paused")
      }
      await model.start()
      await model.resume(item)
      let deadline = ContinuousClock.now + .seconds(5)
      while model.transfers.first?.state != .completed,
        ContinuousClock.now < deadline
      { try await Task.sleep(for: .milliseconds(5)) }
      let completed = try #require(model.transfers.first)
      #expect(completed.state == .completed)
      let destination = try #require(completed.manifest.localDestinationPath)
      #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == data)
      await model.shutdown().value
    }
  }
}
#endif
