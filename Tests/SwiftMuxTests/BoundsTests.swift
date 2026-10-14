import Darwin
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct BoundsTests {
  @Test
  func paneLimitRejectsExcessCreation() async throws {
    var limits = MuxLimits()
    limits.maxPanes = 2
    let h = try Harness(limits: limits)
    let c = try await h.connect()
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    try await c.attachAndShow(.id(ws.id))
    _ = try await c.execute(
      .split(
        pane: ws.tabs[0].activePane,
        axis: .leftRight,
        launch: shellLaunch()
      )
    )
    do {
      try await c.execute(.newTab(name: nil, launch: shellLaunch()))
      Issue.record("third pane admitted")
    } catch let e as MuxError { #expect(e.code == .resourceLimit) }
  }

  /// A noisy pane and a client that stops consuming: one frame in
  /// flight, and control traffic is still answered promptly.
  @Test
  func slowClientStaysBoundedAndResponsive() async throws {
    let h = try Harness()
    let c = try await h.connect()
    var noisy = shellLaunch()
    noisy.command = ["/bin/sh", "-c", "yes 'noisy output line'"]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: noisy))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    try await c.attachAndShow(.id(ws.id))
    // Do not consume events for a while; frames must not pile up.
    try await Task.sleep(for: .milliseconds(500))
    let start = ContinuousClock.now
    guard case .status = try await c.execute(.status) else {
      throw MuxError(.invalidRequest, "unexpected reply")
    }
    #expect(ContinuousClock.now - start < .milliseconds(500))
    var frames = 0
    while true {
      let event = try await withTimeout(.milliseconds(200)) {
        try await c.nextEvent()
      }
      if case .frame = event { frames += 1 } else { break }
      if frames > 3 { break }
    }
    // At most the in-flight frame was buffered while we were not reading,
    // plus frames sent after each acknowledgement during the drain.
    #expect(frames >= 1)
    _ = try? await c.execute(.endWorkspace(.id(ws.id)))
  }

  @Test
  func detachedPanesStillAnswerQueries() async throws {
    let h = try Harness()
    let c = try await h.connect(.control)
    var spec = shellLaunch()
    // Ask for device attributes with no frontend attached; the engine
    // replies through the pane's own writer.
    spec.command = [
      "/bin/sh", "-c",
      "stty raw -echo; printf '\\033[c'; dd bs=1 count=3 2>/dev/null | od -c | head -1 > /tmp/swmux-da-$$; stty sane; echo done; exec cat",
    ]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: spec))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    var reply = ""
    for _ in 0 ..< 100 {
      try await Task.sleep(for: .milliseconds(30))
      if let lines = await h.service.screenLines(pane), lines.contains("done"),
        let pid = await h.service.panePID(pane),
        let text = try? String(
          contentsOfFile: "/tmp/swmux-da-\(pid)",
          encoding: .utf8
        )
      {
        reply = text
        try? FileManager.default.removeItem(atPath: "/tmp/swmux-da-\(pid)")
        break
      }
    }
    #expect(reply.contains("033   ["))
  }

  @Test
  func inputBeyondWriterCreditIsRejected() async throws {
    var limits = MuxLimits()
    limits.inputBytesPerPane = 4096
    let h = try Harness(limits: limits)
    let c = try await h.connect()
    var spec = shellLaunch()
    // A program that never reads its input.
    spec.command = ["/bin/sh", "-c", "stty -icanon; sleep 30"]
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(NewWorkspaceRequest(launch: spec))
      )
    else { throw MuxError(.invalidRequest, "unexpected reply") }
    let pane = ws.tabs[0].activePane
    try await c.attachAndShow(.id(ws.id))
    try await Task.sleep(for: .milliseconds(200))
    var rejected: MuxError?
    let chunk = String(repeating: "x", count: 1024)
    for _ in 0 ..< 400 {
      do { try await c.send(.text(chunk), to: pane) } catch let e as MuxError {
        rejected = e
        break
      }
    }
    #expect(rejected?.code == .resourceLimit)
    _ = try? await c.execute(.endPane(pane))
  }

  @Test
  func oversizedRecordsAreRefusedBeforeDecoding() throws {
    #expect(throws: MuxError.self) {
      _ = try SMXCodec.decode(
        ClientMessage.self,
        from: Data(count: MuxLimits.standard.maxControlRecordBytes + 1),
        limit: MuxLimits.standard.maxControlRecordBytes
      )
    }
  }
}

struct ServerRecordLimitTests {
  @Test(arguments: [
    0, 1, 16 << 20, Int.max - (64 << 10), Int.max - (64 << 10) + 1, Int.max,
  ])
  func recordEnvelopeRemainsRepresentable(frameBytes: Int) throws {
    var limits = MuxLimits()
    limits.maxFrameBytes = frameBytes
    let limit = SMXCodec.serverRecordLimit(limits)
    let expected =
      switch frameBytes {
      case 0: 65536
      case 1: 65537
      case 16 << 20: 16_842_752
      default: Int.max
      }
    #expect(limit == expected)
    let message = ServerMessage.event(.detached(reason: "record limit probe"))
    let data = try SMXCodec.encode(message, limit: limit)
    guard
      case let .event(.detached(reason)) = try SMXCodec.decode(
        ServerMessage.self,
        from: data,
        limit: limit
      )
    else { throw MuxError(.invalidRequest, "unexpected round-trip message") }
    #expect(reason == "record limit probe")
  }

  @Test(arguments: [Int.max - (64 << 10) + 1, Int.max])
  func serviceWithAnUnrepresentableRecordEnvelopeIsRefused(
    frameBytes: Int
  ) throws {
    var limits = MuxLimits()
    limits.maxFrameBytes = frameBytes
    #expect(throws: MuxError.self) { try Harness(limits: limits) }
  }

  private func retire(_ h: Harness) async {
    await withCheckedContinuation { continuation in
      h.service.prepareToExit { continuation.resume() }
    }
  }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HistoryBudgetTests {
  private func retire(_ h: Harness, _ c: MuxConnection) async {
    await withCheckedContinuation { continuation in
      h.service.prepareToExit { continuation.resume() }
    }
    await c.close()
  }

  @Test(arguments: [1, 4])
  func anUnaffordableMinimumReservationCannotExceedTheHistoryPool(
    panes: Int
  ) async throws {
    var limits = MuxLimits()
    limits.maxPanes = panes
    limits.totalHistoryBytes = panes * (512 << 10)
    let h = try Harness(limits: limits)
    let c = try await h.connect(.control)
    var created: [WorkspaceID] = []
    do {
      for _ in 0 ..< panes {
        do {
          guard
            case let .created(ws) = try await c.execute(
              .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
            )
          else { throw MuxError(.invalidRequest, "unexpected reply") }
          created.append(ws.id)
          let budget = try #require(
            await h.service.historyBudget(ws.tabs[0].activePane)
          )
          #expect(budget.total <= limits.totalHistoryBytes)
        } catch let error as MuxError {
          #expect(error.code == .resourceLimit)
          break
        }
      }
      #expect(
        created.isEmpty,
        "A minimum reservation that cannot fit must be refused before launch."
      )
      await retire(h, c)
    } catch {
      await retire(h, c)
      throw error
    }
  }

  @Test
  func anUnrepresentableReservationIsRefusedWithoutStartingAPane() async throws
  {
    var limits = MuxLimits()
    limits.maxPanes = Int.max
    let h = try Harness(limits: limits)
    let c = try await h.connect(.control)
    do {
      do {
        _ = try await c.execute(
          .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
        )
        Issue.record("Accepted an overflowing history reservation.")
      } catch let error as MuxError { #expect(error.code == .resourceLimit) }
      #expect(await h.service.isEmpty)
      guard case let .status(status) = try await c.execute(.status) else {
        throw MuxError(.invalidRequest, "unexpected reply")
      }
      #expect(status.panes == 0)
      await retire(h, c)
    } catch {
      await retire(h, c)
      throw error
    }
  }

  @Test(arguments: [false, true])
  func disabledHistoryAndCapsBelowTheMinimumRemainUsable(
    disabled: Bool
  ) async throws {
    var limits = MuxLimits()
    limits.maxPanes = 4
    limits.historyBytesPerPane = disabled ? 0 : 256 << 10
    limits.totalHistoryBytes = disabled ? 0 : 1 << 20
    let h = try Harness(limits: limits)
    let c = try await h.connect(.control)
    do {
      for _ in 0 ..< 4 {
        guard
          case let .created(ws) = try await c.execute(
            .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
          )
        else { throw MuxError(.invalidRequest, "unexpected reply") }
        let budget = try #require(
          await h.service.historyBudget(ws.tabs[0].activePane)
        )
        #expect(budget.pane == limits.historyBytesPerPane)
        #expect(budget.total <= limits.totalHistoryBytes)
      }
      await retire(h, c)
    } catch {
      await retire(h, c)
      throw error
    }
  }

  /// Early panes get the full per-pane cap; later ones share what is
  /// left without the total ever exceeding the service budget.
  @Test
  func sharesStayWithinTheTotal() async throws {
    var limits = MuxLimits()
    limits.maxPanes = 4
    limits.historyBytesPerPane = 4 << 20
    limits.totalHistoryBytes = 8 << 20
    limits.minHistoryBytesPerPane = 1 << 20
    let h = try Harness(limits: limits)
    let c = try await h.connect(.control)
    do {
      var shares: [Int] = []
      var total = 0
      for _ in 0 ..< 4 {
        guard
          case let .created(ws) = try await c.execute(
            .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
          )
        else { throw MuxError(.invalidRequest, "unexpected reply") }
        let budget = try #require(
          await h.service.historyBudget(ws.tabs[0].activePane)
        )
        shares.append(budget.pane >> 20)
        total = budget.total
      }
      #expect(shares == [4, 2, 1, 1])
      #expect(total == 8 << 20)
      await retire(h, c)
    } catch {
      await retire(h, c)
      throw error
    }
  }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ScrollBoundTests {
  @Test(arguments: [10000, Int.max - 256, Int.max - 255, Int.max])
  func scrollBoundsPreserveMovementAndAddressValidation(
    historyRows: Int
  ) async throws {
    var limits = MuxLimits()
    limits.historyRowsPerPane = historyRows
    if historyRows > 1_000_000 {
      #expect(throws: MuxError.self) { try Harness(limits: limits) }
      return
    }
    let h = try Harness(limits: limits)
    let c: MuxConnection
    do { c = try await h.connect() } catch {
      await retire(h)
      throw error
    }
    do {
      guard
        case let .created(ws) = try await c.execute(
          .newWorkspace(NewWorkspaceRequest(launch: shellLaunch()))
        )
      else { throw MuxError(.invalidRequest, "unexpected create reply") }
      let pane = ws.tabs[0].activePane
      try await c.attachAndShow(.id(ws.id), columns: 40, rows: 10)
      try await c.send(
        .text("i=0; while [ $i -lt 60 ]; do echo row-$i; i=$((i+1)); done\r", ),
        to: pane
      )
      var frame = try await c.frame(of: pane) {
        $0.lines.contains("row-59") && $0.history.scrollbackRows > 0
      }

      func move(_ request: ScrollRequest, towardHistory: Bool, ) async throws {
        let revision = frame.identity.viewportRevision
        try await c.execute(.scroll(pane: pane, request))
        frame = try await c.frame(of: pane) {
          $0.identity.viewportRevision > revision
            && $0.history.viewportOffset
              == (towardHistory ? $0.history.scrollbackRows : 0)
        }
      }

      let bound = historyRows == 10000 ? 10256 : Int.max
      for request in [ScrollRequest.lines(bound), .pages(bound)] {
        try await move(request, towardHistory: true)
      }
      let address = frame.history.address(
        viewportRow: 0,
        alternateScreen: false
      )
      try await move(.bottom, towardHistory: false)
      try await move(.top(address), towardHistory: true)
      #expect(frame.history.viewportTop == address.row)
      var stale = address
      stale.generation &+= 1
      do {
        try await c.execute(.scroll(pane: pane, .top(stale)))
        Issue.record("Accepted a stale history address")
      } catch let error as MuxError {
        #expect(error.code == .historyUnavailable)
      }
      for request in [ScrollRequest.lines(-bound), .pages(-bound)] {
        try await move(request, towardHistory: false)
      }
      if historyRows >= Int.max - 255 {
        for request in [ScrollRequest.lines(Int.min), .pages(Int.min)] {
          try await move(request, towardHistory: false)
        }
      } else {
        var rejected = [ScrollRequest.lines(Int.min), .pages(Int.min)]
        if historyRows == 10000 {
          rejected += [
            .lines(10257), .lines(-10257), .pages(10257), .pages(-10257),
          ]
        }
        for request in rejected {
          do {
            try await c.execute(.scroll(pane: pane, request))
            Issue.record(
              "Accepted an out-of-bounds relative scroll: \(request)"
            )
          } catch let error as MuxError {
            #expect(error.code == .invalidRequest)
          }
        }
      }
      guard case .status = try await c.execute(.status) else {
        throw MuxError(.invalidRequest, "unexpected status reply")
      }
      await retire(h, c)
    } catch {
      await retire(h, c)
      throw error
    }
  }

  private func retire(_ h: Harness, _ c: MuxConnection? = nil) async {
    await withCheckedContinuation { continuation in
      h.service.prepareToExit { continuation.resume() }
    }
    await c?.close()
  }
}
