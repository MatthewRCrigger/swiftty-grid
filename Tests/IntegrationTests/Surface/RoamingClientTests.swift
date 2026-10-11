import Foundation
import ScreenProtocol
import SessionCore
import Synchronization
import Testing

@testable import TerminalSurface

struct RoamingClientTests {
  @Test
  func `attach then first complete snapshot makes the client active`() async throws {
    let f = try RoamingFixture()
    try await f.client.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(await f.waitFor(.active))
    let status = await f.client.status
    #expect(status.sessionID == f.host.sessionID)
    #expect(status.screenRevision == 1)
    #expect(status.title == "host")
    #expect(status.lastScreenAt != nil)
    #expect(f.sink.count == 1)
    #expect(await f.host.attachCount == 1)
    #expect(f.bootstrapper.requests.withLock { $0.map(\.operation) } == [.create])
    await f.client.close()
  }

  @Test
  func `input is acknowledged and leaves the pending queue`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    #expect(await f.client.submit(.text("ls")) == .accepted(sequence: 1))
    #expect(await f.client.submit(.key(SemanticKey(.enter))) == .accepted(sequence: 2))
    #expect(await eventually { await f.client.status.pendingInputCount == 0 })
    #expect(await f.host.applied == [1, 2])
    #expect(await f.host.text == "ls")
    #expect(await eventually { f.sink.lastLine == "ls" })
    await f.client.close()
  }

  @Test
  func `severed connection retries unacknowledged input once under the new epoch`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    // Applied but unacknowledged (1, 2) and lost in transit (3, 4).
    await f.host.set(withholdAcks: true, dropInputsAfter: .some(2))
    for (i, s) in ["a", "b", "c", "d"].enumerated() {
      #expect(await f.client.submit(.text(s)) == .accepted(sequence: UInt64(i + 1)))
    }
    #expect(await eventually { await f.host.received.count == 4 })
    #expect(await f.host.applied == [1, 2])
    #expect(await f.client.status.pendingInputCount == 4)

    await f.host.set(withholdAcks: false, dropInputsAfter: .some(nil))
    await f.host.severCurrent()
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await f.waitFor(.active))
    #expect(await eventually { await f.client.status.pendingInputCount == 0 })

    // A3 oracle: each operation applied exactly once, in order.
    #expect(await f.host.applied == [1, 2, 3, 4])
    #expect(await f.host.text == "abcd")
    // Retries carry their original sequence numbers and the new epoch.
    let retried = await f.host.received.filter { $0.epoch == 2 }
    #expect(retried.map(\.sequence) == [3, 4])
    #expect(retried.map(\.operation) == [.committedText("c"), .committedText("d")])
    #expect(await eventually { f.sink.lastLine == "abcd" })
    await f.client.close()
  }

  @Test
  func `input is refused while reconnecting and never queued`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.connector.block()
    await f.host.severCurrent()
    #expect(await eventually { await f.client.state == .attaching })
    let result = await f.client.submit(.text("lost"))
    #expect(result == .refused(.notActive(.attaching)))
    #expect(await f.client.status.refusedInputCount == 1)
    #expect(await f.client.status.pendingInputCount == 0)

    await f.connector.release()
    #expect(await f.waitFor(.active))
    #expect(await f.host.received.isEmpty)
    #expect(await f.host.text == "")
    await f.client.close()
  }

  @Test
  func `stale and older epoch snapshots never regress the display`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    #expect(await f.client.submit(.text("new")) == .accepted(sequence: 1))
    #expect(await eventually { f.sink.lastLine == "new" })
    let revision = await f.client.status.screenRevision
    let installs = f.sink.count

    // Older revision on the current epoch.
    await f.host.sendScreen(epoch: 1, revision: 1, text: "old")
    // Reattach, then a frame from the fenced epoch.
    await f.host.severCurrent()
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await f.waitFor(.active))
    let afterReattach = f.sink.count
    await f.host.sendScreen(epoch: 1, revision: 1000, text: "fenced")
    // A marker frame proves the stale ones were processed first.
    await f.host.sendScreen()
    #expect(await eventually { f.sink.count == afterReattach + 1 })

    let lines = f.sink.frames.withLock { $0.map { $0.line(0) } }
    #expect(!lines.contains("old"))
    #expect(!lines.contains("fenced"))
    #expect(f.sink.lastLine == "new")
    #expect(installs == 2)
    #expect((await f.client.status.screenRevision ?? 0) > (revision ?? 0))
    await f.client.close()
  }

  @Test
  func `reconnect attempts run one at a time with backoff`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.connector.fail(next: 3)
    await f.host.severCurrent()
    #expect(await f.waitFor(.reconnecting))
    // Nudges must not start parallel attempts.
    for _ in 0 ..< 5 { await f.client.wake() }
    #expect(await eventually { await f.client.state == .active })
    #expect(await f.connector.maxInFlight == 1)
    #expect(await f.connector.connectCount == 5)
    #expect(Array(f.clock.backoffSleeps.prefix(4)) == [0.5, 1, 2, 4])
    // Three straight failures ask SSH whether the session still exists.
    #expect(f.bootstrapper.requests.withLock { $0.map(\.operation) } == [.create, .resume])
    #expect(await f.client.status.reconnectAttempt == 0)
    await f.client.close()
  }

  @Test
  func `expired token renews credentials through SSH resume`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    let writer = await f.host.writer
    let oldToken = await f.host.token
    f.clock.advanceWallClock(by: 9 * 3600)
    await f.host.severCurrent()
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await f.waitFor(.active))

    let requests = f.bootstrapper.requests.withLock { $0 }
    #expect(requests.map(\.operation) == [.create, .resume])
    #expect(requests.last?.sessionID == f.host.sessionID)
    #expect(requests.last?.writerID == writer)
    #expect(await f.host.token != oldToken)
    // Same writer: the input sequence continues.
    #expect(await f.client.submit(.text("x")) == .accepted(sequence: 1))
    #expect(await eventually { await f.host.applied == [1] })
    await f.client.close()
  }

  @Test
  func `unknown session ends as session lost without replay`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.host.set(dropInputsAfter: .some(0))
    #expect(await f.client.submit(.text("rm -rf build")) == .accepted(sequence: 1))
    #expect(await eventually { await f.host.received.count == 1 })
    // The helper restarted: the session no longer exists.
    await f.host.set(sessionGone: true)
    await f.host.severCurrent()
    #expect(await f.waitFor(.sessionLost))

    let status = await f.client.status
    #expect(status.pendingInputCount == 1)
    #expect(await f.host.received.count == 1)
    #expect(await f.host.applied.isEmpty)
    #expect(await f.client.submit(.text("y")) == .refused(.closed))
  }

  @Test
  func `authenticated unknown session from SSH ends as session lost`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.connector.fail(next: 100)
    await f.host.set(sessionGone: true)
    await f.host.severCurrent()
    // Unreachable attempts escalate to SSH, which answers authoritatively.
    #expect(await f.waitFor(.sessionLost))
    #expect(
      f.bootstrapper.requests.withLock { $0.last?.operation } == .resume
    )
  }

  @Test
  func `session exit is reported through status and lifecycle`() async throws {
    let clock = TestClock()
    let host = try FakeHost()
    let backend = RoamingScreenBackend(
      bootstrapper: FakeBootstrapper(host: host),
      connector: FakeConnector(host: host),
      configuration: testConfiguration(),
      timing: clock.timing
    )
    let changes = Mutex<[SurfaceLifecycle]>([])
    backend.onLifecycleChange = { change in changes.withLock { $0.append(change) } }
    let invalidations = Mutex(0)
    backend.onInvalidate = { invalidations.withLock { $0 += 1 } }

    try await backend.start(.create(GridSize(columns: 20, rows: 4)))
    #expect(await eventually { backend.lifecycle == .active })
    #expect(backend.capabilities == .roaming)
    #expect(backend.currentFrame()?.frame.title == "host")
    #expect(invalidations.withLock { $0 } == 1)

    await host.exit(status: 3)
    #expect(await eventually { backend.lifecycle == .exited(3) })
    #expect(await backend.client.status.exitStatus == 3)
    #expect(await backend.submit(.text("x")) == .refused(.closed))
    #expect(changes.withLock { $0 } == [.active, .exited(3)])
  }

  @Test
  func `background detach then foreground waits for a full screen before input`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.client.enterBackground()
    #expect(await f.client.state == .backgroundDetached)
    #expect(await f.host.detachCount == 1)
    #expect(await f.client.submit(.text("bg")) == .refused(.notActive(.backgroundDetached)))

    await f.host.set(sendSnapshotOnAttach: false)
    await f.client.enterForeground()
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await eventually { await f.host.currentEpoch == 2 })
    #expect(await f.client.state == .attaching)
    #expect(await f.client.submit(.text("early")) == .refused(.notActive(.attaching)))

    await f.host.sendScreen()
    #expect(await f.waitFor(.active))
    #expect(await f.client.submit(.text("ok")) == .accepted(sequence: 1))
    #expect(await eventually { await f.host.text == "ok" })
    await f.client.close()
  }

  @Test
  func `grid proposals become ordered resize operations`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.client.proposeGrid(columns: 30, rows: 5)
    #expect(await eventually { f.sink.last?.columns == 30 })
    await f.client.proposeGrid(columns: 40, rows: 6)
    #expect(await eventually { f.sink.last?.columns == 40 })
    // Unchanged proposals send nothing.
    await f.client.proposeGrid(columns: 40, rows: 6)
    #expect(
      await f.host.resizes == [
        .resize(columns: 30, rows: 5, resizeRevision: 1),
        .resize(columns: 40, rows: 6, resizeRevision: 2),
      ]
    )
    #expect(f.sink.last?.rows == 6)
    await f.client.close()
  }

  @Test
  func `resume requests the configured grid instead of adopting the grant`() async throws {
    // The view proposed 30x5 while signing in; the session is 20x4.
    let f = try RoamingFixture(initialGrid: GridSize(columns: 30, rows: 5))
    try await f.client.start(.resume(f.host.sessionID))
    #expect(await f.waitFor(.active))
    let requested = f.bootstrapper.requests.withLock { $0.first?.initialGrid }
    #expect(requested == GridSize(columns: 30, rows: 5))
    #expect(await eventually { f.sink.last?.columns == 30 })
    #expect(await f.host.resizes == [.resize(columns: 30, rows: 5, resizeRevision: 1)])
    await f.client.close()
  }

  @Test
  func `reattaching re-requests the grid after another client resized`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.client.proposeGrid(columns: 30, rows: 5)
    #expect(await eventually { f.sink.last?.columns == 30 })

    await f.client.enterBackground()
    // Another client takes over and resizes the session.
    await f.host.resizeExternally(columns: 50, rows: 10)
    await f.client.enterForeground()
    #expect(await f.waitFor(.active))
    #expect(await eventually { f.sink.last?.columns == 30 })
    #expect(f.sink.last?.rows == 5)
    #expect(
      await f.host.resizes == [
        .resize(columns: 30, rows: 5, resizeRevision: 1),
        .resize(columns: 30, rows: 5, resizeRevision: 3),
      ]
    )
    await f.client.close()
  }

  @Test
  func `unanswered input marks the connection stale and recovers`() async throws {
    let f = try RoamingFixture()
    let states = Mutex<[ClientConnectionState]>([])
    await f.client.setStatusHandler { status in
      states.withLock { if $0.last != status.state { $0.append(status.state) } }
    }
    #expect(try await f.startActive())
    await f.host.blackHoleCurrent()
    #expect(await f.client.submit(.text("z")) == .accepted(sequence: 1))
    #expect(await eventually { await f.host.attachCount == 2 })
    #expect(await f.waitFor(.active))
    #expect(await eventually { await f.client.status.pendingInputCount == 0 })
    #expect(await f.host.applied == [1])
    let seen = states.withLock { $0 }
    #expect(seen.contains(.suspect))
    #expect(seen.contains(.reconnecting))
    await f.client.close()
  }

  @Test
  func `explicit terminate closes the session`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    await f.client.close(.terminate)
    #expect(await f.client.state == .userClosed)
    #expect(await f.host.terminateCount == 1)
    #expect(await f.client.submit(.text("x")) == .refused(.closed))
  }

  @Test
  func `status carries no secrets`() async throws {
    let f = try RoamingFixture()
    #expect(try await f.startActive())
    let text = String(describing: await f.client.status)
    let token = await f.host.token
    #expect(!text.contains(Data(token.bytes).base64EncodedString()))
    #expect(!text.contains(hexString(token.bytes)))
    await f.client.close()
  }

  @Test
  func `input whose record cannot fit is refused rather than stalling`() {
    // Control characters escape to six bytes each in JSON.
    let controls = String(repeating: "\u{01}", count: RSTLimits.maxPasteBytes)
    #expect((try? InputOperation.paste(controls).validate()) != nil)
    #expect(!RoamingClient.fitsControlRecord(.paste(controls)))
    #expect(RoamingClient.fitsControlRecord(.paste(String(repeating: "x", count: 32_000))))
    #expect(RoamingClient.fitsControlRecord(.key(SemanticKey(.enter))))
  }
}
