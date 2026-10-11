import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import Synchronization
import Testing

/// `MuxConnection` request, detach, record-size and paste rules.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ConnectionTests {
  /// A service stand-in that answers the handshake and `attach` but never
  /// `detach`, and records whether the client's channel ended.
  final class SilentService: @unchecked Sendable {
    let listener: SMXListener
    let queue = DispatchQueue(label: "silent-service")
    let closed = Mutex(false)
    private let channels = Mutex<[SMXChannel]>([])

    init() {
      listener = SMXListener(anonymousOn: queue)
      listener.activate(connectionQueue: queue) { [self] channel in
        channels.withLock { $0.append(channel) }
        channel.activate { [self] event in
          switch event {
          case .closed: closed.withLock { $0 = true }
          case let .message(data): answer(data, on: channel)
          }
        }
      }
    }

    private func answer(_ data: Data, on channel: SMXChannel) {
      guard
        let message = try? SMXCodec.decode(
          ClientMessage.self,
          from: data,
          limit: 1 << 20
        )
      else { return }
      let reply: ServerMessage
      switch message {
      case .hello:
        reply = .welcome(
          Welcome(
            protocolVersion: SMX.protocolVersion,
            build: SMX.build,
            server: ServerInstanceID(),
            acceptedProfile: nil,
            limits: .standard,
            innerTerm: "xterm-256color"
          )
        )
      case let .request(id, .attach):
        reply = .reply(
          id: id,
          result: .success(
            .attached(
              attachment: AttachmentID(),
              workspace: WorkspaceSnapshot(
                id: WorkspaceID(),
                name: "silent",
                tabs: [],
                activeTab: TabID(),
                panes: [],
                layoutRevision: 1
              )
            )
          )
        )
      default: return
      }
      if let data = try? SMXCodec.encode(reply, limit: 1 << 20) {
        channel.send(data)
      }
    }

    deinit { listener.cancel() }
  }

  /// Quit, window replacement and `swmux` detach wait on this: a service
  /// that never answers must not hang them, and the lease it holds is
  /// released by closing the connection.
  @Test
  func detachIsBoundedWhenTheServiceDoesNotAnswer() async throws {
    let service = SilentService()
    let c = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    _ = try await c.execute(.attach(.name("silent")))
    await c.setDetachTimeout(.milliseconds(200))
    let start = ContinuousClock.now
    try await withTimeout(.seconds(10)) { await c.detach() }
    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(await c.attachment == nil)
    // The connection was closed, which releases the lease.
    #expect(await (try? c.nextEvent()) == nil)
    for _ in 0 ..< 200 where !service.closed.withLock({ $0 }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(service.closed.withLock { $0 })
  }

  /// Cancelling the waiting task resumes `execute` (once); a late reply
  /// is dropped.
  @Test
  func cancellingAnUnansweredRequestStopsWaiting() async throws {
    let service = SilentService()
    let c = try await MuxConnection.connect(
      endpoint: service.listener.endpoint,
      frontend: .native
    )
    let task = Task { try await c.execute(.listWorkspaces) }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await withTimeout(.seconds(5)) { try await task.value }
    }
    await #expect { try await c.execute(.listWorkspaces, timeout: .milliseconds(50)) }
      throws: { ($0 as? MuxError)?.code == .connectionLost }
    await c.close()
  }

  /// A record too large to send is refused on its own: the connection
  /// (and the lease it holds) stays usable.
  @Test
  func anOversizedRequestIsRefusedAlone() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    let name = String(repeating: "n", count: 300 << 10)
    await #expect {
      try await c.execute(.renameWorkspace(.id(ws.id), name: name))
    } throws: { ($0 as? MuxError)?.code == .resourceLimit }
    // Text longer than one record is split, not fatal.
    try await c.send(.text("cat > /dev/null\r"), to: pane)
    let line = String(repeating: "t", count: 63) + "\n"
    await c.post(.text(String(repeating: line, count: (160 << 10) / 64)), to: pane)
    await c.post(.key(.character(0x64), .control), to: pane)
    try await c.send(.text("echo alive-$((1+1))\r"), to: pane)
    _ = try await c.frame(of: pane, timeout: .seconds(20)) {
      $0.lines.contains("alive-2")
    }
    #expect(await c.attachment != nil)
  }

  /// A record that cannot be encoded fails the connection and cancels
  /// its channel, so the service releases the lease (no zombie lease
  /// refusing the next attach with `leaseHeld`); `close` after that is
  /// harmless.
  @Test
  func aFailedConnectionReleasesItsLease() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      ),
      case let .attached(attachment, _) = try await c.execute(
        .attach(.id(ws.id))
      )
    else { return }
    let huge = String(repeating: "x", count: 300 << 10)
    await #expect(throws: MuxError.self) {
      try await c.submit(
        raw: InputRecord(
          sequence: 1,
          attachment: attachment,
          pane: ws.tabs[0].activePane,
          payload: .input(.text(huge))
        )
      )
    }
    await c.close()
    let other = try await h.connect()
    var attached = false
    for _ in 0 ..< 200 {
      if case .attached? = try? await other.execute(.attach(.id(ws.id))) {
        attached = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(attached)
    await other.close()
  }

  /// Two pastes to one pane in a row: the second waits for the first's
  /// envelope (the service refuses a second open paste), and input sent
  /// after it stays after it.
  @Test
  func consecutivePastesToOnePaneBothComplete() async throws {
    let h = try Harness()
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { return }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    // `cat` copies what the pane receives into a file, in order.
    let path = NSTemporaryDirectory() + "paste-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: path) }
    try await c.send(.text("cat > '\(path)'\r"), to: pane)
    try await Task.sleep(for: .milliseconds(300))
    let results = Mutex<[Int: Result<PasteState, MuxError>]>([:])
    let filler = String(repeating: "filler\n", count: 8000)
    c.enqueuePaste(filler + "one\n", to: pane) { r in
      results.withLock { $0[1] = r }
    }
    c.enqueuePaste("two\n", to: pane) { r in results.withLock { $0[2] = r } }
    c.enqueue(.text("three\n"), to: pane)
    c.enqueue(.key(.character(0x64), .control), to: pane)
    var written = ""
    for _ in 0 ..< 500 {
      written = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
      if written.hasSuffix("three\n"), results.withLock({ $0.count }) == 2 {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(try results.withLock { try $0[1]?.get() } == .completed)
    #expect(try results.withLock { try $0[2]?.get() } == .completed)
    #expect(written == filler + "one\ntwo\nthree\n")
  }
}
