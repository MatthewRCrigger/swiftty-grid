#if os(macOS)
import AppKit
import Foundation
@testable import RoamingApp
import SwiftUI
import SwifttyCore
import SwifttyMac
import Synchronization
import Testing

@MainActor
private struct TerminalIdentityRoot: View {
  @Bindable
  var app: RoamingAppModel
  let navigation: Bool

  var body: some View {
    if navigation {
      RoamingRootView(model: app)
    } else if let model = app.activeSession {
      TerminalScreen(model: model) { app.close() }
    }
  }
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct TerminalSurfaceIdentityTests {
    private func close(_ window: NSWindow) {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet)
        close(sheet)
      }
      window.close()
      window.contentView = nil
    }

    private func terminals(in view: NSView) -> [TerminalView] {
      if let terminal = view as? TerminalView { return [terminal] }
      return view.subviews.flatMap { terminals(in: $0) }
    }

    private func until(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(2)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test(arguments: [false, true])
    func replacingTheActiveModelDisplaysAndTypesIntoItsCurrentSession(
      navigation: Bool
    ) async throws {
      _ = NSApplication.shared
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("terminal-identity-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      let suite = "terminal-identity-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let app = RoamingAppModel(
        profile: .profile(for: .catalyst),
        store: ConnectionStore(
          fileURL: directory.appendingPathComponent("hosts.json")
        ),
        resumeStore: SessionResumeStore(defaults: defaults)
      )
      let firstHost = HostProfile(
        nickname: "First",
        host: "first.invalid",
        username: "test"
      )
      let secondHost = HostProfile(
        nickname: "Second",
        host: "second.invalid",
        username: "test"
      )
      let first = TerminalSession(presentationColumns: 80, rows: 24)
      let second = TerminalSession(presentationColumns: 80, rows: 24)
      defer {
        first.stop();
        second.stop()
      }
      let inputs = Mutex<[Int]>([0, 0])
      first.semanticInputHandler = { _ in inputs.withLock { $0[0] += 1 } }
      second.semanticInputHandler = { _ in inputs.withLock { $0[1] += 1 } }
      let factory = TerminalSurfaceFactory { model in
        AnyView(
          TerminalDisplayView(
            session: model.host.id == firstHost.id ? first : second,
            capabilities: model.capabilities
          )
        )
      }
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      defer {
        app.close()
        close(window)
      }
      let root = NSHostingView(
        rootView: TerminalIdentityRoot(app: app, navigation: navigation)
          .environment(\.terminalSurfaceFactory, factory)
      )
      window.contentView = root
      window.makeKeyAndOrderFront(nil)
      app.open(firstHost)
      try #require(try await until { terminals(in: root).count == 1 })
      let original = try #require(terminals(in: root).first)
      #expect(original.session === first)
      original.insertText(
        "first",
        replacementRange: NSRange(location: NSNotFound, length: 0)
      )
      first.queue.sync {}
      #expect(inputs.withLock { $0 } == [1, 0])

      app.open(secondHost)
      #expect(app.activeSession?.host == secondHost)
      #expect(
        try await until {
          let views = terminals(in: root)
          return views.count == 1 && views.first?.session === second
        },
        "Replacing the screen must replace the native renderer's immutable session."
      )
      let current = try #require(terminals(in: root).last)
      current.insertText(
        "second",
        replacementRange: NSRange(location: NSNotFound, length: 0)
      )
      first.queue.sync {}
      second.queue.sync {}
      #expect(inputs.withLock { $0 } == [1, 1])
      #expect(current.session === second)

      let model = try #require(app.activeSession)
      model.capabilities.localCopy.toggle()
      try #require(
        try await until { current.capabilities == model.capabilities }
      )
      #expect(terminals(in: root).count == 1)
      #expect(terminals(in: root).first === current)
      #expect(current.session === second)
    }

    @Test(arguments: [TerminalKind.roaming, .ordinarySSH])
    func replacingALiveSurfaceStartsItsNewController(
      kind: TerminalKind
    ) async throws {
      _ = NSApplication.shared
      let suite = "terminal-live-identity-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let fixture = try await TransferFixture.make()
      let app = RoamingAppModel(
        profile: .profile(for: .catalyst),
        store: ConnectionStore(
          fileURL: fixture.local.appendingPathComponent("hosts.json")
        ),
        resumeStore: SessionResumeStore(defaults: defaults)
      )
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      defer { close(window) }
      let root = NSHostingView(
        rootView: RoamingRootView(model: app)
          .environment(\.terminalSurfaceFactory, .live(app))
      )
      window.contentView = root
      window.makeKeyAndOrderFront(nil)
      var controllers: [any TerminalSurfaceController] = []
      do {
        for name in ["First", "Second"] {
          let host = HostProfile(
            nickname: name,
            host: "127.0.0.1",
            port: fixture.server.port,
            username: "test",
            auth: .password
          )
          if kind == .roaming {
            // A roaming screen signs in only for an explicit workspace
            // choice (spec.connection-setup.md D1). Trust is rejected
            // below, before any create request could be sent.
            app.openWorkspace(host, intent: .create)
          } else {
            app.open(host, kind: kind)
          }
          let model = try #require(app.activeSession)
          try #require(try await until { model.controller != nil })
          let controller = try #require(model.controller)
          controllers.append(controller)
          try #require(
            try await until {
              app.pendingTrust?.host == host && window.attachedSheet != nil
            },
            "The current surface's startup task must run and request its own trust decision."
          )
          let display: TerminalSession
          switch controller {
          case let roaming as RoamingTerminalController:
            display = roaming.display
          case let ssh as SSHShellController: display = ssh.session
          default:
            Issue.record("Unexpected controller for the fixture terminal kind.")
            throw CancellationError()
          }
          try #require(try await until { terminals(in: root).count == 1 })
          #expect(terminals(in: root).first?.session === display)
          // Reject before credentials are requested or trust is persisted.
          app.resolveTrust(.reject)
          try #require(
            try await until {
              app.pendingTrust == nil && window.attachedSheet == nil
            }
          )
        }
      } catch {
        app.resolveTrust(.reject)
        app.resolvePassword(nil)
        app.close()
        for controller in controllers { await controller.close(.detach) }
        close(window)
        await fixture.cleanup()
        throw error
      }
      app.close()
      for controller in controllers { await controller.close(.detach) }
      close(window)
      await fixture.cleanup()
    }
  }
}
#endif
