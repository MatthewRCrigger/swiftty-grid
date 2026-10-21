import Foundation
import MuxNavigation
import ScreenProtocol
import SessionCore
import SwiftMuxProtocol
import Synchronization
import TerminalSurface
import Testing

@testable import RoamingApp

/// Metadata-only service: answers `.workspaces` from a script and counts
/// every request. It can create nothing and holds no lease.
private final class ScriptedWorkspaces: RoamingAttentionMetadataService {
  private struct State {
    var replies: [HostMetadata]
    var requests: [AttentionRequest] = []
    var closed = 0
  }

  private let state: Mutex<State>

  init(_ replies: [HostMetadata]) { state = Mutex(State(replies: replies)) }

  var requests: [AttentionRequest] { state.withLock { $0.requests } }
  var closed: Int { state.withLock { $0.closed } }

  func metadata(
    _ request: AttentionRequest
  ) async throws(AttentionServiceError) -> HostMetadata {
    try state.withLock { state throws(AttentionServiceError) in
      state.requests.append(request)
      guard !state.replies.isEmpty else { throw .offline("gone") }
      return state.replies.count > 1
        ? state.replies.removeFirst() : state.replies[0]
    }
  }

  func serviceEpoch() async throws(AttentionServiceError)
    -> SwiftMuxProtocol.ServerInstanceID
  { try await metadata(.workspaces).serviceEpoch }
  func locate(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) -> AttentionLocation { throw .notFound }
  func leaseState(
    of workspace: WorkspaceID
  ) async throws(AttentionServiceError) -> LeaseState { throw .notFound }
  func open(
    _ target: PaneTarget,
    takeover expectedLease: UInt64?
  ) async throws(AttentionServiceError) { throw .unsupported("not here") }
  func markSeen(
    _ reference: AttentionReference
  ) async throws(AttentionServiceError) {}
  func close() async { state.withLock { $0.closed += 1 } }
}

private struct ScriptedConnector: AttentionServiceConnector {
  let service: ScriptedWorkspaces
  func connect(
    to host: NavigationHost
  ) async throws(AttentionServiceError) -> any AttentionService { service }
}

extension MainActorIntegrationTests {
  /// spec.connection-setup.md T9–T11: listing and cancelling create
  /// nothing; selection resumes by identity; takeover is confirmed for
  /// the observed generation and races refresh instead of retrying.
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct WorkspaceChooserTests {
    let epoch = SwiftMuxProtocol.ServerInstanceID()

    func model() throws -> (RoamingAppModel, HostProfile, URL) {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
      let app = RoamingAppModel(
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        ),
        resumeStore: SessionResumeStore(
          defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
      )
      let host = HostProfile(nickname: "Mac", host: "mac.local", username: "me")
      #expect(try app.save(host))
      return (app, host, directory)
    }

    func summary(
      _ name: String,
      attached: Bool = false,
      lease: UInt64 = 0
    ) -> WorkspaceSummary {
      WorkspaceSummary(
        id: WorkspaceID(),
        name: name,
        tabCount: 2,
        paneCount: 3,
        createdAt: .now,
        isAttached: attached,
        leaseGeneration: lease,
        leaseHolder: attached
          ? LeaseHolder(transport: .remote, frontend: .terminal, since: .now)
          : nil
      )
    }

    func loaded(_ chooser: WorkspaceChooserModel) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(5)
      while chooser.phase != .loaded {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    func settle(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(5)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test
    func browsingAnEmptyMacAndCancellingCreatesNothing() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      #expect(chooser.rows.isEmpty)
      chooser.close()
      #expect(try await settle { service.closed == 1 })
      // Only lease-free listing was sent; no create, no attachment.
      #expect(service.requests == [.workspaces])
      #expect(app.activeSession == nil)
      #expect(app.resumableSessionID(for: host) == nil)
      #expect(app.takeIntent(for: host) == nil)
    }

    @Test
    func choosingAFreeWorkspaceResumesItsIdentity() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let free = summary("build")
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [free])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      #expect(chooser.rows.first?.summary.livePaneCount == nil)
      chooser.choose(try #require(chooser.rows.first))
      #expect(try await settle { chooser.finished })
      #expect(app.activeSession?.host == host)
      #expect(app.takeIntent(for: host) == .resume(SessionID(free.id), nil))
      #expect(app.resumableSessionID(for: host) == SessionID(free.id))
      app.close()
    }

    @Test
    func newWorkspaceIsTheOnlyCreate() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [summary("a")])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      chooser.createNew()
      #expect(chooser.finished)
      #expect(app.takeIntent(for: host) == .create)
      #expect(app.takeIntent(for: host) == nil)
      app.close()
    }

    @Test
    func takeoverNeedsConfirmationAndSendsTheObservedGeneration() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let held = summary("held", attached: true, lease: 7)
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [held])
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      let row = try #require(chooser.rows.first)
      #expect(row.heldElsewhere)
      chooser.choose(row)
      // Nothing happens until the user confirms.
      #expect(chooser.pendingTakeover == row)
      #expect(app.activeSession == nil)
      chooser.confirmTakeover()
      #expect(try await settle { chooser.finished })
      #expect(
        app.takeIntent(for: host)
          == .resume(SessionID(held.id), ResumeTarget(expectedLease: 7))
      )
      app.close()
    }

    @Test(arguments: [false, true])
    func changedLeaseOrEpochRefreshesInsteadOfRetrying(
      epochChanged: Bool
    ) async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      var held = summary("held", attached: true, lease: 7)
      var moved = held
      moved.leaseGeneration = 8
      let after =
        epochChanged
        ? HostMetadata(
          serviceEpoch: SwiftMuxProtocol.ServerInstanceID(),
          workspaces: [held]
        ) : HostMetadata(serviceEpoch: epoch, workspaces: [moved])
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [held]), after,
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      chooser.choose(try #require(chooser.rows.first))
      chooser.confirmTakeover()
      #expect(try await settle { chooser.notice != nil })
      #expect(try await settle { service.requests.count >= 3 })
      #expect(!chooser.finished)
      #expect(app.activeSession == nil)
      #expect(app.takeIntent(for: host) == nil)
      // The list now shows what is current, for a fresh decision.
      #expect(try await settle { chooser.serviceEpoch == after.serviceEpoch })
      held.leaseGeneration = after.workspaces![0].leaseGeneration
      #expect(
        chooser.rows.first?.summary.leaseGeneration == held.leaseGeneration
      )
      chooser.close()
    }

    @Test
    func vanishedWorkspaceIsNotReplacedByACreate() async throws {
      let (app, host, directory) = try model()
      defer { try? FileManager.default.removeItem(at: directory) }
      let gone = summary("gone")
      let service = ScriptedWorkspaces([
        HostMetadata(serviceEpoch: epoch, workspaces: [gone]),
        HostMetadata(serviceEpoch: epoch, workspaces: []),
      ])
      let chooser = WorkspaceChooserModel(
        model: app,
        host: host,
        connector: ScriptedConnector(service: service)
      )
      chooser.load()
      #expect(try await loaded(chooser))
      chooser.choose(try #require(chooser.rows.first))
      #expect(try await settle { chooser.notice != nil })
      #expect(!chooser.finished)
      #expect(app.takeIntent(for: host) == nil)
      chooser.close()
    }
  }

  /// Remembered identities never turn into creates (T10).
  @MainActor
  struct WorkspaceIntentTests {
    func app() throws -> RoamingAppModel {
      RoamingAppModel(
        store: ConnectionStore(
          fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("hosts.json")
        ),
        resumeStore: SessionResumeStore(
          defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
      )
    }

    @Test
    func resumeLastWorkspaceNeedsARememberedIdentity() throws {
      let app = try app()
      let host = HostProfile(nickname: "Mac", host: "mac.local", username: "me")
      #expect(!app.resumeLastWorkspace(host))
      #expect(app.activeSession == nil)
      #expect(app.takeIntent(for: host) == nil)
      let id = SessionID(WorkspaceID())
      app.rememberSession(id, for: host)
      #expect(app.resumeLastWorkspace(host))
      #expect(app.takeIntent(for: host) == .resume(id, nil))
      app.close()
    }

    @Test
    func aScreenWithoutAChoiceCreatesNothing() async throws {
      let app = try app()
      let host = HostProfile(nickname: "Mac", host: "mac.local", username: "me")
      app.open(host)
      let session = try #require(app.activeSession)
      let controller = RoamingTerminalController(model: session, app: app)
      controller.start()
      let deadline = ContinuousClock.now + .seconds(5)
      while case .preparing = controller.phase, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(
        controller.phase == .failed(RoamingTerminalController.noWorkspaceChosen)
      )
      #expect(controller.intent == nil)
      #expect(app.pendingPassword == nil)
      #expect(app.pendingTrust == nil)
      await controller.close(.detach)
      app.close()
    }

    @Test
    func selectingTheShownWorkspaceKeepsTheTerminal() throws {
      let app = try app()
      let host = HostProfile(nickname: "Mac", host: "mac.local", username: "me")
      let id = SessionID(WorkspaceID())
      app.openWorkspace(host, intent: .resume(id, nil))
      let first = try #require(app.activeSession)
      first.observe(RoamingStatus(state: .active, sessionID: id))
      app.openWorkspace(host, intent: .resume(id, nil))
      #expect(app.activeSession === first)
      app.openWorkspace(host, intent: .create)
      #expect(app.activeSession !== first)
      #expect(first.connectionState == .userClosed)
      app.close()
    }
  }
}
