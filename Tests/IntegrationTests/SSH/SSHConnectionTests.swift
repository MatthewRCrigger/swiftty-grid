import Crypto
import Foundation
import NIOCore
import NIOSSH
import ScreenProtocol
import SessionCore
import Synchronization
import TestSupport
import Testing

@testable import SSHClient

/// Records trust prompts and answers with a fixed decision.
final class RecordingDecider: HostTrustDecider {
  let decision: HostTrustDecision
  let requests = Mutex<[HostTrustRequest]>([])

  init(_ decision: HostTrustDecision) { self.decision = decision }

  func decide(_ request: HostTrustRequest) async -> HostTrustDecision {
    requests.withLock { $0.append(request) }
    return decision
  }
}

/// Collects shell events from the event loop.
final class ShellRecorder: Sendable {
  let output = Mutex<[UInt8]>([])
  let events = Mutex<[SSHShellEvent]>([])

  func record(_ event: SSHShellEvent) {
    if case let .output(bytes) = event {
      output.withLock { $0 += bytes }
    } else {
      events.withLock { $0.append(event) }
    }
  }

  var text: String { String(decoding: output.withLock { $0 }, as: UTF8.self) }
}

/// Polls `condition` every 5 ms until it holds or `timeout` elapses.
func waitUntil(
  timeout: Duration = .seconds(5),
  _ condition: () -> Bool
) async throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    if ContinuousClock.now >= deadline { return false }
    try await Task.sleep(for: .milliseconds(5))
  }
  return true
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct SSHConnectionTests {
  @Test
  func serverShutdownClosesAcceptedConnections() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let first = try await server.connect()
    do {
      let second = try await server.connect()
      await server.shutdown()
      #expect(
        try await waitUntil(timeout: .seconds(1)) {
          !first.isActive && !second.isActive
        }
      )
      await first.close()
      await second.close()
    } catch {
      await first.close()
      await server.shutdown()
      throw error
    }
  }

  // MARK: Host trust

  @Test
  func `unknown host key requires an explicit decision before auth`()
    async throws
  {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let store = InMemoryHostTrustStore()

    let rejecting = RecordingDecider(.reject)
    await #expect(throws: SSHClientError.self) {
      _ = try await SSHConnection.connect(
        configuration: server.configuration(),
        credential: .password(TestSSHServer.password),
        trustStore: store,
        trustDecider: rejecting
      )
    }
    let prompt = try #require(rejecting.requests.withLock { $0.first })
    #expect(prompt.host == server.identity)
    #expect(prompt.keyType == "ssh-ed25519")
    #expect(prompt.fingerprint.hasPrefix("SHA256:"))
    #expect(prompt.fingerprint.count == 7 + 43)
    #expect(!prompt.fingerprint.hasSuffix("="))
    // No credential was sent for an untrusted key.
    #expect(server.state.authRequests.withLock { $0 } == 0)
    #expect(await store.trustedKey(for: server.identity) == nil)

    let approving = RecordingDecider(.trustAndRemember)
    let connection = try await SSHConnection.connect(
      configuration: server.configuration(),
      credential: .password(TestSSHServer.password),
      trustStore: store,
      trustDecider: approving
    )
    #expect(connection.hostKeyFingerprint == prompt.fingerprint)
    #expect(await store.trustedKey(for: server.identity) == server.hostKeyLine)
    await connection.close()

    // A remembered key needs no further prompt.
    let silent = RecordingDecider(.reject)
    let again = try await SSHConnection.connect(
      configuration: server.configuration(),
      credential: .password(TestSSHServer.password),
      trustStore: store,
      trustDecider: silent
    )
    #expect(silent.requests.withLock { $0.isEmpty })
    await again.close()
  }

  @Test
  func `host key can be verified before any credential exists`() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let store = InMemoryHostTrustStore()

    let rejecting = RecordingDecider(.reject)
    await #expect {
      _ = try await SSHConnection.verifyHostKey(
        configuration: server.configuration(),
        trustStore: store,
        trustDecider: rejecting
      )
    } throws: { error in
      guard case .hostKeyRejected = error as? SSHClientError else {
        return false
      }
      return true
    }
    #expect(rejecting.requests.withLock { $0.count } == 1)

    let approving = RecordingDecider(.trustAndRemember)
    let fingerprint = try await SSHConnection.verifyHostKey(
      configuration: server.configuration(),
      trustStore: store,
      trustDecider: approving
    )
    #expect(
      fingerprint == approving.requests.withLock { $0.first?.fingerprint }
    )
    #expect(await store.trustedKey(for: server.identity) == server.hostKeyLine)
    // Neither probe offered a credential.
    #expect(server.state.authRequests.withLock { $0 } == 0)

    // The remembered key then authenticates without another prompt.
    let silent = RecordingDecider(.reject)
    let connection = try await SSHConnection.connect(
      configuration: server.configuration(),
      credential: .password(TestSSHServer.password),
      trustStore: store,
      trustDecider: silent
    )
    #expect(silent.requests.withLock { $0.isEmpty })
    await connection.close()
  }

  @Test
  func `changed host key fails closed and blocks reconnection`() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let other = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    let otherLine = String(openSSHPublicKey: other)
    let store = InMemoryHostTrustStore(keys: [server.identity: otherLine])
    let decider = RecordingDecider(.trustAndRemember)

    do {
      _ = try await SSHConnection.connect(
        configuration: server.configuration(),
        credential: .password(TestSSHServer.password),
        trustStore: store,
        trustDecider: decider
      )
      Issue.record("connected despite a changed host key")
    } catch let error as SSHClientError {
      guard case let .hostKeyChanged(host, expected, presented) = error else {
        Issue.record("unexpected error \(error)")
        return
      }
      #expect(host == server.identity)
      #expect(
        expected == SSHPublicKeyFormat.fingerprint(openSSHPublicKey: otherLine)
      )
      #expect(
        presented
          == SSHPublicKeyFormat.fingerprint(
            openSSHPublicKey: server.hostKeyLine
          )
      )
      #expect(error.blocksAutomaticReconnect)
    }
    // Never prompted, never replaced, never authenticated.
    #expect(decider.requests.withLock { $0.isEmpty })
    #expect(await store.trustedKey(for: server.identity) == otherLine)
    #expect(server.state.authRequests.withLock { $0 } == 0)
  }

  @Test
  func `trust is scoped to configured host and port`() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    // Same address, different configured name: a separate identity.
    let store = InMemoryHostTrustStore(keys: [
      HostIdentity(host: "LocalHost", port: server.port)!: server.hostKeyLine
    ])
    #expect(
      HostIdentity(host: "localhost", port: server.port)
        == HostIdentity(host: "LOCALHOST", port: server.port)
    )
    await #expect(throws: SSHClientError.self) {
      _ = try await SSHConnection.connect(
        configuration: server.configuration(),
        credential: .password(TestSSHServer.password),
        trustStore: store,
        trustDecider: RejectUnknownHostKeys()
      )
    }
    #expect(HostIdentity(host: "", port: 22) == nil)
    #expect(HostIdentity(host: "a b", port: 22) == nil)
    #expect(HostIdentity(host: "host", port: 0) == nil)
  }

  @Test
  func `file trust store persists public keys only`() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "trust-" + UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("known_hosts.json")
    let key = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    let line = String(openSSHPublicKey: key)
    let id = HostIdentity(host: "Example.com", port: 2222)!

    let store = FileHostTrustStore(fileURL: file)
    try await store.setTrustedKey(line, for: id)
    let reloaded = FileHostTrustStore(fileURL: file)
    #expect(try await reloaded.trustedKey(for: id) == line)
    #expect(
      try await reloaded.trustedKey(
        for: HostIdentity(host: "example.com", port: 22)!
      ) == nil
    )
    let json = try String(contentsOf: file, encoding: .utf8)
    #expect(json.contains("example.com"))
    #expect(!json.lowercased().contains("private"))

    try await reloaded.removeTrustedKey(for: id)
    #expect(
      try await FileHostTrustStore(fileURL: file).trustedKey(for: id) == nil
    )

    try Data("{not json".utf8).write(to: file)
    await #expect(throws: FileHostTrustStore.StoreError.corrupt) {
      _ = try await FileHostTrustStore(fileURL: file).trustedKey(for: id)
    }
  }

  // MARK: Authentication

  @Test
  func durationConversionSaturatesAtNanosecondBounds() {
    #expect(TimeAmount(clamping: .seconds(Int64.max)).nanoseconds == .max)
    #expect(TimeAmount(clamping: .seconds(Int64.min)).nanoseconds == .min)
    #expect(
      TimeAmount(
        clamping: Duration(
          secondsComponent: 9_223_372_036,
          attosecondsComponent: 854_775_808_000_000_000
        )
      )
      .nanoseconds == .max
    )
    #expect(
      TimeAmount(
        clamping: Duration(
          secondsComponent: -9_223_372_036,
          attosecondsComponent: -854_775_809_000_000_000
        )
      )
      .nanoseconds == .min
    )
    #expect(
      TimeAmount(clamping: .milliseconds(1500)).nanoseconds == 1_500_000_000
    )
  }

  @Test
  func oversizedTrustStoreWritesPreserveTheLastReadableFile() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "trust-" + UUID().uuidString
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("known_hosts.json")
    let key = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
    let line = String(openSSHPublicKey: key)
    let id = try #require(HostIdentity(host: "example.com", port: 22))
    let store = FileHostTrustStore(fileURL: file)
    try await store.setTrustedKey(line, for: id)
    let original = try Data(contentsOf: file)
    let oversized =
      line + " "
      + String(repeating: "x", count: FileHostTrustStore.maxFileBytes)
    await #expect(throws: FileHostTrustStore.StoreError.tooLarge) {
      try await store.setTrustedKey(oversized, for: id)
    }
    #expect(try Data(contentsOf: file) == original)
    #expect(try await store.trustedKey(for: id) == line)
    #expect(
      try await FileHostTrustStore(fileURL: file).trustedKey(for: id) == line
    )
  }

  @Test
  func execTimeoutFailsInsteadOfReturningPartialOutput() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect()
    defer { Task { await connection.close() } }
    await #expect(throws: SSHClientError.execTimeout) {
      _ = try await connection.execute(
        command: "wait-forever",
        limits: SSHExecLimits(timeout: .milliseconds(50))
      )
    }
    #expect(connection.isActive)
    let result = try await connection.execute(command: "echo-split")
    #expect(result.exitStatus == 3)
  }

  @Test
  func `password authentication succeeds and wrong password fails`()
    async throws
  {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect()
    #expect(connection.isActive)
    await connection.close()
    #expect(!connection.isActive)

    await #expect(throws: SSHClientError.authenticationFailed) {
      _ = try await server.connect(credential: .password("wrong"))
    }
    #expect(
      String(describing: SSHCredential.password("hunter2")).contains("hunter2")
        == false
    )
  }

  @Test
  func concurrentKeyCreationReturnsOneNamedIdentity() async throws {
    let keys: any Ed25519KeyStore = InMemoryEd25519KeyStore()
    let publicKeys = try await withThrowingTaskGroup(of: Data.self) { group in
      for _ in 0 ..< 32 {
        group.addTask {
          try await keys.loadOrCreateKey(label: "shared").publicKey
            .rawRepresentation
        }
      }
      var values: Set<Data> = []
      for try await key in group { values.insert(key) }
      return values
    }
    #expect(publicKeys.count == 1)
  }

  @Test
  func `app-managed ed25519 key authenticates`() async throws {
    let keys = InMemoryEd25519KeyStore()
    let key = try await keys.loadOrCreateKey(label: "default")
    #expect(
      try await keys.loadOrCreateKey(label: "default").rawRepresentation
        == key.rawRepresentation
    )
    let line = SSHEd25519Key.authorizedKeysLine(
      for: key.publicKey,
      comment: "swiftty\ninjected"
    )
    #expect(line.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
    #expect(!line.contains("\n"))
    #expect(line.hasSuffix(" swifttyinjected"))
    #expect(
      SSHEd25519Key.fingerprint(of: key.publicKey)
        == SSHPublicKeyFormat.fingerprint(openSSHPublicKey: line)
    )
    let authorized = try NIOSSHPublicKey(openSSHPublicKey: line)
    #expect(authorized == NIOSSHPrivateKey(ed25519Key: key).publicKey)

    let server = try await TestSSHServer.start(authorizedKeys: [authorized])
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect(credential: .ed25519(key))
    #expect(connection.isActive)
    await connection.close()

    await #expect(throws: SSHClientError.authenticationFailed) {
      _ = try await server.connect(
        credential: .ed25519(SSHEd25519Key.generate())
      )
    }
  }

  @Test
  func `keychain key store round trips when available`() async throws {
    let store = KeychainEd25519KeyStore(
      service: "swiftty.tests." + UUID().uuidString
    )
    let key = SSHEd25519Key.generate()
    do { try await store.storeKey(key, label: "probe") } catch let
      KeychainEd25519KeyStore.KeychainError.status(status)
    {
      // Unsigned test runners may lack keychain entitlements.
      #expect(status != 0)
      return
    }
    #expect(
      try await store.loadKey(label: "probe")?.rawRepresentation
        == key.rawRepresentation
    )
    try await store.deleteKey(label: "probe")
    #expect(try await store.loadKey(label: "probe") == nil)
  }

  // MARK: Exec and bootstrap

  @Test
  func `exec keeps stdout and stderr separate`() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect()
    defer { Task { await connection.close() } }

    let result = try await connection.execute(
      command: "echo-split",
      stdin: Array("payload".utf8)
    )
    #expect(result.stdout == Array("out:payload".utf8))
    #expect(result.stderr == Array("err".utf8))
    #expect(result.exitStatus == 3)
    #expect(!result.stderrTruncated)

    await #expect(throws: SSHClientError.outputLimitExceeded) {
      _ = try await connection.execute(
        command: "flood-stdout",
        limits: SSHExecLimits(maxStdoutBytes: 1024 * 1024)
      )
    }
    // The connection survives a failed channel.
    #expect(connection.isActive)
  }

  @Test
  func `bootstrap exchanges exactly one envelope`() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect()
    defer { Task { await connection.close() } }

    let response = try await connection.runBootstrap(
      helperPath: TestSSHServer.helperPath,
      request: BootstrapRequest(operation: .list)
    )
    #expect(response == .sessions([]))
    #expect(
      server.state.bootstrapRequests.withLock { $0 } == [
        BootstrapRequest(operation: .list)
      ]
    )

    // Diagnostics are bounded and never part of the protocol.
    let noisy = try await connection.runBootstrap(
      helperPath: "/opt/noisy/swifttyd",
      request: BootstrapRequest(operation: .list)
    )
    #expect(noisy == .sessions([]))
  }

  @Test
  func `unexpected bootstrap stdout is a protocol error`() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect()
    defer { Task { await connection.close() } }

    for path in ["/opt/garbage/swifttyd", "/opt/banner/swifttyd"] {
      do {
        _ = try await connection.runBootstrap(
          helperPath: path,
          request: BootstrapRequest(operation: .list)
        )
        Issue.record("accepted unexpected stdout from \(path)")
      } catch let error as SSHClientError {
        guard case .bootstrapProtocol = error else {
          Issue.record("unexpected error \(error)")
          continue
        }
      }
    }

    await #expect(
      throws: SSHClientError.bootstrapFailed(
        exitStatus: 1,
        diagnostics: "agent unavailable"
      )
    ) {
      _ = try await connection.runBootstrap(
        helperPath: "/opt/silent/swifttyd",
        request: BootstrapRequest(operation: .list)
      )
    }
  }

  @Test(arguments: [
    "swifttyd", "/opt/rst host", "/opt/rst;rm", "/opt/$(id)", "/opt/../x",
    "/opt/rst\nhost", "", "/opt/a|b",
  ])
  func `bootstrap helper path is validated`(path: String) async throws {
    #expect(!SSHConnection.isValidHelperPath(path))
  }

  @Test
  func `valid helper paths are accepted`() {
    #expect(SSHConnection.isValidHelperPath("/usr/local/libexec/swifttyd"))
    #expect(
      SSHConnection.isValidHelperPath(
        "/Applications/Swiftty.app/Contents/MacOS/swifttyd_2.0"
      )
    )
  }

  // MARK: Shell

  @Test
  func `shell echoes input and propagates resize`() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect()
    defer { Task { await connection.close() } }

    let recorder = ShellRecorder()
    let shell = try await connection.openShell(columns: 80, rows: 24) {
      recorder.record($0)
    }
    let pty = try #require(server.state.ptyRequest.withLock { $0 })
    #expect(pty.term == "xterm-256color")
    #expect(pty.terminalCharacterWidth == 80)
    #expect(pty.terminalRowHeight == 24)

    try await shell.write(Array("hello\r".utf8))
    #expect(try await waitUntil { recorder.text.contains("hello\r") })

    try await shell.resize(columns: 100, rows: 30)
    #expect(try await waitUntil { recorder.text.contains("[resize 100x30]") })
    #expect(server.state.windowSize.withLock { $0 }! == (100, 30))

    await #expect(throws: SSHClientError.invalidGridSize) {
      try await shell.resize(columns: 0, rows: 30)
    }
    await #expect(throws: SSHClientError.self) {
      try await shell.write(
        [UInt8](repeating: 0, count: SSHShellChannel.maxWriteBytes + 1)
      )
    }

    await shell.close()
    #expect(
      try await waitUntil { recorder.events.withLock { $0.contains(.closed) } }
    )
  }

  @Test
  func `shell output is bounded by read credit`() async throws {
    let server = try await TestSSHServer.start()
    defer { Task { await server.shutdown() } }
    let connection = try await server.connect()
    defer { Task { await connection.close() } }

    let recorder = ShellRecorder()
    let shell = try await connection.openShell(
      columns: 80,
      rows: 24,
      initialReadCredit: 16 * 1024
    ) { recorder.record($0) }
    let total = 96 * 64 * 1024
    try await shell.write(Array("flood".utf8))
    #expect(try await waitUntil { recorder.output.withLock { $0.count } > 0 })
    try await Task.sleep(for: .milliseconds(200))
    // Without credit, delivery stops within one SSH window (2 MiB).
    let stalled = recorder.output.withLock { $0.count }
    #expect(stalled < 3 * 1024 * 1024)
    #expect(stalled < total)

    shell.grantReadCredit(total)
    #expect(
      try await waitUntil(timeout: .seconds(10)) {
        recorder.output.withLock { $0.count } == total
      }
    )
    await shell.close()
  }
}
