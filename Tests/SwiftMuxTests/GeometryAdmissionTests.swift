import Dispatch
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct GeometryAdmissionTests {
  @Test(arguments: 0 ..< 8)
  func invalidServiceLimitsAreRejectedBeforeStorage(caseIndex: Int) {
    var configuration = MuxServiceConfiguration(launcherPath: "unused")
    switch caseIndex {
    case 0: configuration.limits.maxColumns = Int.max
    case 1: configuration.limits.maxRows = Int(UInt16.max) + 1
    case 2: configuration.limits.historyRowsPerPane = Int.max
    case 3: configuration.limits.historyBytesPerPane = Int.max
    case 4: configuration.limits.totalHistoryBytes = Int.max
    case 5: configuration.limits.maxStyles = Int(UInt16.max) + 1
    case 6: configuration.limits.maxRows = 4096
    default: configuration.limits.minPaneColumns = 513
    }
    #expect(throws: MuxError.self) {
      try MuxService(configuration: configuration)
    }
  }

  @Test
  func clientRejectsUnrepresentableStyleCapacity() {
    var limits = MuxLimits.standard
    limits.maxStyles = Int(UInt16.max) + 1
    #expect(throws: MuxError.self) { try limits.validateForClient() }
    limits.maxStyles = Int(UInt16.max)
    #expect(throws: Never.self) { try limits.validateForClient() }
  }

  @Test
  func queuedResizeBurstAppliesOnlyTheLatestGeometry() {
    let runtime = PaneRuntime(
      id: PaneID(),
      workspace: WorkspaceID(),
      columns: 80,
      rows: 24,
      historyBytes: 0,
      limits: .standard,
    )
    runtime.queue.suspend()
    for generation in 1 ... 1000 {
      runtime.resize(columns: generation.isMultiple(of: 2) ? 40 : 80, rows: 10,
      )
    }
    runtime.queue.resume()
    runtime.queue.sync {
      // One applied resize, carrying the latest request's generation.
      #expect(runtime.geometryGeneration == 1000)
      #expect(runtime.revision == 1)
    }
    #expect(runtime.screenLines().count == 10)
  }

  @Test
  func resizeArrivingDuringATurnYieldsToOtherPaneWork() {
    let runtime = PaneRuntime(
      id: PaneID(),
      workspace: WorkspaceID(),
      columns: 80,
      rows: 24,
      historyBytes: 0,
      limits: .standard,
    )
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    runtime.onChange = {
      started.signal()
      _ = release.wait(timeout: .now() + 5)
    }
    defer { release.signal() }
    runtime.resize(columns: 40, rows: 10)
    #expect(started.wait(timeout: .now() + 2) == .success)
    let observed = Mutex<UInt64?>(nil)
    runtime.queue.async {
      observed.withLock { $0 = runtime.geometryGeneration }
    }
    for _ in 2 ... 1000 { runtime.resize(columns: 60, rows: 12) }
    release.signal()
    runtime.queue.sync {}
    runtime.queue.sync {
      // The burst coalesces into one more resize: the latest request.
      #expect(runtime.geometryGeneration == 1000)
      #expect(runtime.revision == 2)
    }
    #expect(observed.withLock { $0 } == 1)
  }

  @Test
  func duplicateGeometryUsesLastEntryAndRejectsBelowMinimum() async throws {
    let h = try Harness()
    let client = try await h.connect()
    do {
      guard
        case let .created(workspace) = try await client.execute(
          .newWorkspace(NewWorkspaceRequest(launch: shellLaunch())),
        )
      else { throw MuxError(.invalidRequest) }
      let shown = try await client.attachAndShow(.id(workspace.id))
      let pane = workspace.tabs[0].activePane
      try await client.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: shown.layoutRevision,
            generation: 2,
            entries: [
              .init(pane: pane, columns: 40, rows: 10),
              .init(pane: pane, columns: 60, rows: 12),
            ],
          )
        )
      )
      let runtime = try #require(await h.service.runtime(pane))
      runtime.queue.sync { #expect(runtime.geometryGeneration == 2) }
      #expect(runtime.screenLines().count == 12)
      await #expect(throws: MuxError.self) {
        try await client.execute(
          .setGeometry(
            GeometryBatch(
              layoutRevision: shown.layoutRevision,
              generation: 3,
              entries: [.init(pane: pane, columns: 9, rows: 12)],
            )
          )
        )
      }
      // Rejected requests must not consume the next generation.
      try await client.execute(
        .setGeometry(
          GeometryBatch(
            layoutRevision: shown.layoutRevision,
            generation: 3,
            entries: [.init(pane: pane, columns: 10, rows: 2)],
          )
        )
      )
      for axis in [SplitAxis.leftRight, .topBottom] {
        await #expect(throws: MuxError.self) {
          try await client.execute(
            .split(pane: pane, axis: axis, launch: shellLaunch(), )
          )
        }
      }
    } catch {
      await retire(h, client)
      throw error
    }
    await retire(h, client)
  }

  private func retire(_ h: Harness, _ client: MuxConnection) async {
    await withCheckedContinuation { continuation in
      h.service.prepareToExit { continuation.resume() }
    }
    await client.close()
  }
}
