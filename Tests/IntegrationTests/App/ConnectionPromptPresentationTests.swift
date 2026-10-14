#if os(macOS)
import AppKit
import Observation
import SwiftUI
import Testing

@testable import RoamingApp

@MainActor
@Observable
private final class PromptPresentationState {
  let app = RoamingAppModel()
  var childPresented = false
  var childAppeared = false
  var childDismissRequested = false
  var sftpHost: HostProfile?

  func openChild() {
    // Attention links disable the root anchor before presenting their sheet.
    app.modalDepth += 1
    childPresented = true
  }

  func closeChild() {
    // Attention-link dismissal restores the root before the sheet disappears.
    app.modalDepth -= 1
    childPresented = false
  }
}

private struct PromptPresentationRoot: View {
  @Bindable
  var state: PromptPresentationState
  @State
  private var presentedSFTPHost: HostProfile?

  var body: some View {
    Text("Prompt presentation fixture").frame(width: 520, height: 360)
      .connectionPrompts(state.app, enabled: state.app.modalDepth == 0)
      .sheet(isPresented: $state.childPresented) {
        Text("Child presentation fixture").frame(width: 520, height: 360)
          .connectionPrompts(state.app).onAppear { state.childAppeared = true }
          .onDisappear { state.childAppeared = false }
      }
      .onChange(of: state.childPresented) { _, presented in
        if !presented { state.childDismissRequested = true }
      }
      .sheet(item: $presentedSFTPHost) { host in
        SFTPBrowserView(host: host, app: state.app)
          .frame(width: 560, height: 480)
      }
      .onChange(of: state.sftpHost, initial: true) { _, host in
        presentedSFTPHost = host
      }
  }
}

extension MainActorIntegrationTests {
  @MainActor
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct ConnectionPromptPresentationTests {
    private func close(_ window: NSWindow) {
      if let sheet = window.attachedSheet {
        window.endSheet(sheet)
        close(sheet)
      }
      window.close()
      window.contentView = nil
    }

    private func until(_ condition: () -> Bool) async throws -> Bool {
      let deadline = ContinuousClock.now + .seconds(2)
      while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test
    func closingTheActualSFTPBrowserRestoresRootPromptOwnership() async throws {
      _ = NSApplication.shared
      let fixture = try await TransferFixture.make()
      let state = PromptPresentationState()
      let app = state.app
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      defer { close(window) }
      window.contentView = NSHostingView(
        rootView: PromptPresentationRoot(state: state)
      )
      window.makeKeyAndOrderFront(nil)
      do {
        for _ in 0 ..< 2 {
          state.sftpHost = HostProfile(
            nickname: "SFTP fixture",
            host: "127.0.0.1",
            port: fixture.server.port,
            username: "test",
            auth: .password
          )
          try #require(
            try await until {
              app.pendingTrust != nil
                && window.attachedSheet?.attachedSheet != nil
            }
          )
          #expect(app.modalDepth == 1)
          #expect(app.pendingTrust?.host == state.sftpHost)
          let browserWindow = try #require(window.attachedSheet)
          defer { close(browserWindow) }
          // Reject the real loopback server's key: no credential or trust record
          // is persisted, and the browser's connection attempt finishes.
          app.resolveTrust(.reject)
          try #require(
            try await until {
              window.attachedSheet != nil
                && window.attachedSheet?.attachedSheet == nil
            }
          )
          #expect(
            app.modalDepth == 1,
            "Ending the trust prompt must keep the browser's ownership."
          )
          state.sftpHost = nil
          try #require(try await until { window.attachedSheet == nil })
          #expect(
            try await until { !browserWindow.isVisible },
            Comment(
              rawValue: """
                Browser visible=\(browserWindow.isVisible), parent=\(browserWindow.sheetParent != nil),
                frame=\(browserWindow.frame), title=\(browserWindow.title)
                """
            )
          )
          #expect(
            try await until { app.modalDepth == 0 },
            Comment(
              rawValue:
                "Closed browser modal depth=\(app.modalDepth); root prompts must regain ownership."
            )
          )
        }
      } catch {
        app.resolveTrust(.reject)
        app.resolvePassword(nil)
        close(window)
        await fixture.cleanup()
        throw error
      }
      close(window)
      await fixture.cleanup()
    }

    @Test(arguments: [false, true])
    func childPresentationAndDismissalKeepTheCurrentPromptPending(
      trust: Bool
    ) async throws {
      _ = NSApplication.shared
      let state = PromptPresentationState()
      let app = state.app
      let host = HostProfile(
        nickname: "fixture",
        host: "fixture.local",
        username: "test"
      )
      var finished = false
      let request = Task {
        defer { finished = true }
        if trust {
          return await app.requestTrust(
            TrustPrompt(
              host: host,
              kind: .unknownKey,
              keyAlgorithm: "ssh-ed25519",
              fingerprint: "SHA256:fixture"
            )
          ) == .trust
        }
        return await app.password(for: host, retry: false) != nil
      }
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      defer { close(window) }
      window.contentView = NSHostingView(
        rootView: PromptPresentationRoot(state: state)
      )
      window.orderFront(nil)
      do {
        try #require(try await until { window.attachedSheet != nil })
        let originalID = try #require(
          trust ? app.pendingTrust?.id : app.pendingPassword?.id
        )
        state.openChild()
        try #require(try await until { state.childAppeared })
        try #require(
          try await until {
            window.attachedSheet?.attachedSheet != nil || finished
          }
        )
        #expect(!finished)
        #expect(
          (trust ? app.pendingTrust?.id : app.pendingPassword?.id) == originalID
        )
        state.closeChild()
        try #require(try await until { state.childDismissRequested })
        #expect(app.modalDepth == 0)
        #expect(!finished)
        #expect(
          (trust ? app.pendingTrust?.id : app.pendingPassword?.id) == originalID
        )
        if trust {
          app.resolveTrust(.trust, for: originalID)
        } else {
          app.resolvePassword("fixture-password", for: originalID)
        }
        #expect(await request.value)
        // AppKit's sheet ownership is the closure evidence. A hosted SwiftUI
        // onDisappear callback need not run when the sheet has already closed.
        try #require(
          try await until { window.attachedSheet == nil },
          Comment(
            rawValue: """
              dismiss requested=\(state.childDismissRequested)
              child presented=\(state.childPresented), appeared=\(state.childAppeared)
              modal depth=\(app.modalDepth)
              root sheet=\(window.attachedSheet != nil)
              nested sheet=\(window.attachedSheet?.attachedSheet != nil)
              pending trust=\(app.pendingTrust != nil), password=\(app.pendingPassword != nil)
              """
          )
        )
      } catch {
        request.cancel()
        _ = await request.value
        throw error
      }
      request.cancel()
      _ = await request.value
    }
  }
}
#endif
