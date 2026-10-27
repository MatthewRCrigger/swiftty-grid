import Foundation
@testable import RoamingApp
import SessionCore
import SSHIdentity
import Testing

extension MainActorIntegrationTests.IdentityAccountBoundaryTests {
  func resumeApp(_ defaults: UserDefaults) -> RoamingAppModel {
    let model = RoamingAppModel(
      profile: .profile(for: .mobile),
      store: ConnectionStore(
        fileURL: directory.appendingPathComponent("hosts.json")
      ),
      resumeStore: SessionResumeStore(defaults: defaults),
      secrets: InMemoryIdentitySecretStore(),
      legacyKeys: InMemoryLegacyKeySource(),
      cloud: defaultCloud
    )
    model.load()
    model.sync?.setActive(false)
    return model
  }

  func replaceResumeHost(
    _ original: HostProfile,
    change: String,
    in model: RoamingAppModel
  ) async throws -> HostProfile {
    var host = original
    switch change {
    case "account":
      await select("account-b", in: model)
      #expect(
        model.commitConnections {
          $0.activateRecord(
            ConnectionSnapshot.hostRecord(host.id),
            for: "account-b"
          )
          $0.upsertHost(host)
        }
      )
    case "binding": await select("account-a", in: model)
    case "endpoint": host.host = "other.local"
    case "port": host.port += 1
    case "username": host.username = "other"
    default: break
    }
    if change != "account" { #expect(try model.save(host)) }
    return host
  }

  @Test(arguments: ["account", "binding", "endpoint", "port", "username"])
  func replacementCannotInheritRememberedWorkspace(change: String) async throws
  {
    let suite = "resume-owner-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = resumeApp(defaults)
    if change != "binding" { await select("account-a", in: model) }
    let original = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(original))
    let old = SessionID.random()
    model.openWorkspace(original, intent: .resume(old, nil))
    model.close()
    let replacement = try await replaceResumeHost(
      original,
      change: change,
      in: model
    )
    #expect(model.resumableSessionID(for: replacement) == nil)
    #expect(!model.resumableHosts.contains(replacement.id))
    #expect(!model.resumeLastWorkspace(replacement))
    #expect(model.activeSession == nil)
    model.close()
    let reopened = resumeApp(defaults)
    #expect(reopened.resumableSessionID(for: replacement) == nil)
    #expect(!reopened.resumableHosts.contains(replacement.id))
  }

  @Test(arguments: ["account", "endpoint", "port", "username"])
  func retainedTerminalTerminationPreservesTheNewOwnersChoice(
    change: String
  ) async throws {
    let suite = "resume-close-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = resumeApp(defaults)
    await select("account-a", in: model)
    let original = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(original))
    model.openWorkspace(original, intent: .resume(.random(), nil))
    let retained = try #require(model.activeSession)
    let replacement = try await replaceResumeHost(
      original,
      change: change,
      in: model
    )
    let newChoice = SessionID.random()
    model.rememberSession(
      newChoice,
      for: model.connectionSelection(for: replacement)
    )
    #expect(model.activeSession === retained)
    model.close(.terminate)
    #expect(model.resumableSessionID(for: replacement) == newChoice)
    #expect(model.resumableHosts.contains(replacement.id))
    let reopened = resumeApp(defaults)
    #expect(reopened.resumableSessionID(for: replacement) == newChoice)
  }

  @Test(arguments: ["unchanged", "account", "endpoint"])
  func closingAnUnstartedScreenDiscardsItsWorkspaceIntent(
    change: String
  ) async throws {
    let suite = "resume-intent-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    let model = resumeApp(defaults)
    await select("account-a", in: model)
    let original = HostProfile(nickname: "A", host: "a.local", username: "me")
    #expect(try model.save(original))
    model.openWorkspace(original, intent: .create)
    model.close()
    let replacement = try await replaceResumeHost(
      original,
      change: change,
      in: model
    )
    model.open(replacement)
    let screen = try #require(model.activeSession)
    let controller = RoamingTerminalController(model: screen, app: model)
    controller.start()
    #expect(
      await eventually { @MainActor in
        if case .failed = controller.phase { return true }
        return model.pendingPassword != nil || model.pendingTrust != nil
      }
    )
    #expect(
      controller.phase == .failed(RoamingTerminalController.noWorkspaceChosen)
    )
    #expect(controller.intent == nil)
    #expect(model.pendingPassword == nil)
    #expect(model.pendingTrust == nil)
    await controller.close(.detach)
    model.close()
  }
}
