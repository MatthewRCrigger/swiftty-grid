import XCTest

/// Drives the real roaming SSH client UI end to end against a real OpenSSH
/// server and a real `swifttyd` agent, as a user would. Run through
/// Scripts/test-app-ui.sh, which starts that environment
/// (Scripts/real-ssh-env.sh) and passes it here as `TEST_RUNNER_RST_UI_*`
/// variables (xcodebuild strips the prefix).
///
/// The app is launched with `-ui-testing`: fresh on-disk state for each
/// launch and an invisible `terminal.screen` element carrying the visible
/// terminal text (see Apps/Shared/UITesting.swift).
final class RoamingAppUITests: XCTestCase {
  struct Server {
    let host: String
    let port: String
    let user: String
    let password: String
    let fingerprint: String
  }

  private var server: Server!
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    let env = ProcessInfo.processInfo.environment
    guard let host = env["RST_UI_HOST"], let port = env["RST_UI_PORT"],
      let password = env["RST_UI_PASSWORD"], let fingerprint = env["RST_UI_FINGERPRINT"]
    else {
      throw XCTSkip("Run through Scripts/test-app-ui.sh (RST_UI_* not set)")
    }
    server = Server(
      host: host,
      port: port,
      user: env["RST_UI_USER"] ?? "rst",
      password: password,
      fingerprint: fingerprint
    )
    app = XCUIApplication()
    app.launchArguments += ["-ui-testing"]
    app.launch()
  }

  override func tearDown() {
    app?.terminate()
    super.tearDown()
  }

  // MARK: Tests

  /// Add host → unknown-key prompt with the server's fingerprint → Trust →
  /// password → connected → run a command → (iOS) background/foreground
  /// reconnects to the same shell → SFTP lists ~/files → Detach → reopen
  /// resumes the same shell → Close.
  func testTrustSignInRunCommandRoamSFTPAndDetach() throws {
    addHost(nickname: "UI Box")
    openHost("UI Box")

    let fingerprint = element("trust.fingerprint")
    XCTAssertTrue(fingerprint.waitForExistence(timeout: 30), "no trust prompt")
    XCTAssertEqual(text(of: fingerprint), server.fingerprint)
    XCTAssertTrue(anyText("Unknown host key").exists)
    press(element("trust.accept"))

    signIn()
    waitForConnected()
    waitForPrompt()

    typeLine("echo ui-$((6*7))")
    waitForScreen(containing: "ui-42")

    // State that only the same shell can know.
    typeLine("export UI_MARK=kept-$((3+4)); echo set-$UI_MARK")
    waitForScreen(containing: "set-kept-7")

    #if os(iOS) && !targetEnvironment(macCatalyst)
      // Suspension detaches; foreground return reattaches the same
      // session and installs a complete screen before input (spec §9).
      XCUIDevice.shared.press(.home)
      XCTAssertTrue(
        app.wait(for: .runningBackgroundSuspended, timeout: 10)
          || app.wait(for: .runningBackground, timeout: 1),
        "app did not reach the background"
      )
      sleep(3)
      app.activate()
      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
      waitForConnected()
      typeLine("echo back-$UI_MARK")
      waitForScreen(containing: "back-kept-7")
    #endif

    // SFTP over its own connection to the OpenSSH server (the script puts
    // ui-note.txt in ~/files); credentials come from memory.
    openSessionMenuItem(id: "session.files", title: "Files…")
    let path = element("sftp.path")
    XCTAssertTrue(path.waitForExistence(timeout: 30), "SFTP browser did not list")
    waitUntil("SFTP home listed") { self.path(path) == "/home/rst" }
    let folder = app.buttons["files"].firstMatch
    XCTAssertTrue(folder.waitForExistence(timeout: 10))
    press(folder)
    waitUntil("SFTP entered /home/rst/files") { self.path(path) == "/home/rst/files" }
    XCTAssertTrue(anyText("ui-note.txt").waitForExistence(timeout: 10))
    press(element("sftp.done"))
    XCTAssertTrue(path.waitForNonExistence(timeout: 10))

    // Detach keeps the shell on the host; reopening resumes it.
    openSessionMenuItem(id: "session.detach", title: "Detach")
    let resumable = anyText("Detached session — open to resume")
    XCTAssertTrue(resumable.waitForExistence(timeout: 10), "no resumable session listed")
    openHost("UI Box")
    waitForConnected()
    typeLine("echo again-$UI_MARK")
    waitForScreen(containing: "again-kept-7")

    press(element("terminal.close"))
    XCTAssertTrue(element("hosts.add").waitForExistence(timeout: 10))
  }

  /// Rejecting an unknown host key sends no credentials: no password
  /// prompt, never connected.
  func testRejectUnknownHostKey() throws {
    addHost(nickname: "Untrusted Box")
    openHost("Untrusted Box")

    let fingerprint = element("trust.fingerprint")
    XCTAssertTrue(fingerprint.waitForExistence(timeout: 30), "no trust prompt")
    XCTAssertEqual(text(of: fingerprint), server.fingerprint)
    press(element("trust.reject"))

    XCTAssertTrue(anyText("Host key not trusted").waitForExistence(timeout: 15))
    XCTAssertFalse(element("password.field").waitForExistence(timeout: 3))
    XCTAssertFalse(statusLabel().hasPrefix("Connected"), statusLabel())
    XCTAssertFalse(element("trust.fingerprint").exists)
  }

  // MARK: Steps

  private func addHost(nickname: String) {
    let add = element("hosts.add")
    XCTAssertTrue(add.waitForExistence(timeout: 20), "no Add Host button")
    press(add)
    replaceText(in: element("host.nickname"), with: nickname)
    replaceText(in: element("host.address"), with: server.host)
    replaceText(in: element("host.port"), with: server.port)
    replaceText(in: element("host.username"), with: server.user)
    press(element("host.save"))
    XCTAssertTrue(
      hostRow(nickname).waitForExistence(timeout: 10),
      "host not saved"
    )
  }

  private func openHost(_ nickname: String) {
    let row = hostRow(nickname)
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    press(row)
  }

  private func signIn() {
    let field = element("password.field")
    XCTAssertTrue(field.waitForExistence(timeout: 30), "no password prompt")
    press(field)
    field.typeText(server.password)
    press(element("password.submit"))
    XCTAssertTrue(field.waitForNonExistence(timeout: 10))
  }

  private func waitForConnected() {
    waitUntil("connected", timeout: 60) { self.statusLabel().hasPrefix("Connected") }
  }

  /// Interactive shells may drop typeahead sent before their prompt. The
  /// roaming shell is the agent account's login shell, whose prompt is
  /// not known here, so wait for a nonempty screen that stays unchanged.
  private func waitForPrompt() {
    var last = ""
    var stableSince = Date.now
    waitUntil("a settled shell prompt", timeout: 30) {
      let text = self.screenText()
      if text != last {
        last = text
        stableSince = .now
      }
      return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && Date.now.timeIntervalSince(stableSince) >= 1.5
    }
  }

  private func typeLine(_ line: String) {
    waitForPrompt()
    terminalInputTarget().typeText(line + "\n")
  }

  private func waitForScreen(containing text: String) {
    waitUntil("screen shows \(text)", timeout: 30) { self.screenText().contains(text) }
  }

  private func openSessionMenuItem(id: String, title: String) {
    let menu = element("session.menu")
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    press(menu)
    let byID = app.descendants(matching: .any).matching(identifier: id).firstMatch
    if byID.waitForExistence(timeout: 3) {
      press(byID)
      return
    }
    let item = app.menuItems[title].exists ? app.menuItems[title] : app.buttons[title]
    XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(title) menu item")
    press(item)
  }

  // MARK: Helpers

  /// Displayed text: `label` on iOS; static text exposes `value` on macOS.
  private func text(of element: XCUIElement) -> String {
    if !element.label.isEmpty { return element.label }
    return element.value as? String ?? ""
  }

  /// Text shown anywhere, matched by label or (macOS) value.
  private func anyText(_ text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@ OR value == %@ OR label CONTAINS %@", text, text, text)
    ).firstMatch
  }

  /// A saved host's row: a static text on iOS, one combined button whose
  /// label starts with the nickname on macOS.
  private func hostRow(_ nickname: String) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "label == %@ OR label BEGINSWITH %@", nickname, nickname + ",")
    ).firstMatch
  }

  /// A click on macOS (synthesized taps do not focus fields there), a tap
  /// elsewhere.
  private func press(_ element: XCUIElement) {
    #if os(macOS) || targetEnvironment(macCatalyst)
      // Rows can report not hittable while a sheet finishes closing.
      let deadline = Date.now.addingTimeInterval(5)
      while !element.isHittable, Date.now < deadline {
        RunLoop.current.run(until: .now.addingTimeInterval(0.2))
      }
      if element.isHittable {
        element.click()
      } else {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
      }
    #else
      element.tap()
    #endif
  }

  private func element(_ id: String) -> XCUIElement {
    // Mac Catalyst's toolbar bridge keeps labels but drops SwiftUI
    // identifiers, so toolbar items also match by their label.
    let labels: [String: [String]] = [
      "hosts.add": ["Add Host"], "host.save": ["Save"], "terminal.close": ["Close"],
      // Catalyst shows a toolbar menu as "More".
      "session.menu": ["Session", "More"], "sftp.done": ["Done"],
    ]
    if let names = labels[id] {
      return app.descendants(matching: .any).matching(
        NSPredicate(
          format: "identifier == %@ OR (elementType IN %@ AND (label IN %@ OR title IN %@))",
          id,
          [XCUIElement.ElementType.button, .menuButton, .popUpButton].map(\.rawValue),
          names,
          names
        )
      ).firstMatch
    }
    return app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  private func statusLabel() -> String {
    let status = element("terminal.status")
    return status.exists ? text(of: status) : ""
  }

  private func screenText() -> String {
    #if os(macOS) || targetEnvironment(macCatalyst)
      // The AppKit terminal is itself an accessible text view.
      let view = app.textViews.firstMatch
      if view.exists, let value = view.value as? String, !value.isEmpty {
        return value
      }
    #endif
    let probe = element("terminal.screen")
    guard probe.exists else { return "" }
    return probe.value as? String ?? ""
  }

  private func path(_ element: XCUIElement) -> String {
    element.exists ? text(of: element) : ""
  }

  /// The terminal has keyboard focus once shown; type into it.
  private func terminalInputTarget() -> XCUIElement {
    #if os(macOS)
      return app
    #else
      let terminal = app.descendants(matching: .any)["Terminal"].firstMatch
      if terminal.exists, !terminal.hasFocusForTyping { press(terminal) }
      return terminal.exists ? terminal : app
    #endif
  }

  private func replaceText(in field: XCUIElement, with text: String) {
    guard field.waitForExistence(timeout: 10) else {
      XCTFail("missing \(field)\n\(app.debugDescription)")
      return
    }
    press(field)
    #if os(macOS) || targetEnvironment(macCatalyst)
      field.typeKey("a", modifierFlags: .command)
      field.typeText(text)
    #else
      let current = field.value as? String ?? ""
      let placeholder = field.placeholderValue ?? ""
      if !current.isEmpty, current != placeholder {
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
      }
      field.typeText(text)
    #endif
  }

  private func waitUntil(
    _ what: String,
    timeout: TimeInterval = 15,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
  ) {
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if condition() { return }
      RunLoop.current.run(until: .now.addingTimeInterval(0.25))
    }
    XCTFail(
      "timed out waiting for \(what); status=\(statusLabel()) screen=\(screenText())",
      file: file,
      line: line
    )
  }
}

extension XCUIElement {
  /// Whether this element currently receives typed text.
  fileprivate var hasFocusForTyping: Bool {
    (value(forKey: "hasKeyboardFocus") as? Bool) ?? false
  }
}
