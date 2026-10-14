import Darwin
import Dispatch
import Foundation
import SwiftMuxBridge
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxTerminal
import SwifttyCore
import SwifttyEngine
import Testing

@Suite
struct InputDecoderTests {
  @Test
  func textControlsAndUTF8AcrossReads() {
    var d = InputDecoder()
    #expect(d.feed(Array("hé".utf8).dropLast()) == [.text("h")])
    #expect(
      d.feed([Array("é".utf8).last!, 0x03, 0x0D]) == [
        .text("é"), .key(.character(0x63), .control), .key(.enter, []),
      ]
    )
  }

  @Test(arguments: [
    [UInt8(0xC2)], [0xE2, 0x82], [0xF0, 0x9F, 0x92], [0xC0], [0xFF],
    [0xED, 0xA0], [0xF4, 0x90],
  ])
  func malformedUTF8PreservesFollowingKeys(_ prefix: [UInt8]) {
    for split in 0 ... prefix.count {
      var decoder = InputDecoder()
      var events = decoder.feed(prefix.prefix(split))
      events += decoder.feed(
        prefix.dropFirst(split) + [0x0D, 0x03, 0x1B, 0x5B, 0x41]
      )
      let text =
        events.compactMap { event -> String? in
          if case let .text(value) = event { return value }
          return nil
        }
        .joined()
      let keys = events.filter {
        if case .key = $0 { return true };
        return false
      }
      #expect(text == String(decoding: prefix, as: UTF8.self))
      #expect(
        keys == [
          .key(.enter, []), .key(.character(0x63), .control), .key(.up, []),
        ]
      )
      #expect(!decoder.hasPending)
    }
  }

  @Test(arguments: [[UInt8(0xC2)], [0xE2, 0x82], [0xF0, 0x9F, 0x92]])
  func malformedAltUTF8PreservesFollowingKeys(_ prefix: [UInt8]) {
    for split in 0 ... prefix.count {
      var decoder = InputDecoder()
      var events = decoder.feed([0x1B] + prefix.prefix(split))
      events += decoder.feed(
        prefix.dropFirst(split) + [0x0D, 0x1B, 0x5B, 0x41]
      )
      #expect(
        events == [
          .key(.character(0xFFFD), .alt), .key(.enter, []), .key(.up, []),
        ]
      )
      #expect(!decoder.hasPending)
    }
  }

  @Test
  func validUTF8BoundariesAndAltKeysSurviveEverySplit() {
    let text = "\u{80}\u{7FF}\u{800}\u{D7FF}\u{E000}\u{FFFF}\u{10000}\u{10FFFF}"
    let bytes = Array((text + "\u{1B}漢\r").utf8)
    for split in 0 ... bytes.count {
      var decoder = InputDecoder()
      var events = decoder.feed(bytes.prefix(split))
      events += decoder.feed(bytes.dropFirst(split))
      let decodedText =
        events.compactMap { event -> String? in
          if case let .text(value) = event { return value }
          return nil
        }
        .joined()
      let keys = events.filter {
        if case .key = $0 { return true };
        return false
      }
      #expect(decodedText == text)
      #expect(keys == [.key(.character(0x6F22), .alt), .key(.enter, [])])
      #expect(!decoder.hasPending)
    }
  }

  @Test(
    arguments: [
      [UInt8(0x1B), 0x5B], [0x1B, 0x5B, 0x31, 0x3B], [0x1B, 0x4F],
    ],
    0 ..< 4
  )
  func malformedEscapePrefixesPreserveFollowingKeys(
    _ prefix: [UInt8],
    _ mode: Int
  ) {
    let suffix: [UInt8]
    let suffixText: String
    let suffixKeys: [DecodedInput]
    switch mode {
    case 0:
      suffix = [0x0D, 0x03, 0x1B, 0x5B, 0x41]
      suffixText = ""
      suffixKeys = [
        .key(.enter, []), .key(.character(0x63), .control), .key(.up, []),
      ]
    case 1:
      suffix = [0x1B, 0x5B, 0x41]
      suffixText = ""
      suffixKeys = [.key(.up, [])]
    case 2:
      suffix = Array("漢\r".utf8)
      suffixText = "漢"
      suffixKeys = [.key(.enter, [])]
    default:
      suffix = [0x7F, 0x1B, 0x5B, 0x41]
      suffixText = ""
      suffixKeys = [.key(.backspace, []), .key(.up, [])]
    }
    let bytes = prefix + suffix
    for split in 0 ... bytes.count {
      var decoder = InputDecoder()
      var events = decoder.feed(bytes.prefix(split))
      events += decoder.feed(bytes.dropFirst(split))
      let text =
        events.compactMap { event -> String? in
          if case let .text(value) = event { return value }
          return nil
        }
        .joined()
      let keys = events.filter {
        if case .key = $0 { return true };
        return false
      }
      #expect(
        text == String(decoding: prefix.dropFirst(2), as: UTF8.self)
          + suffixText
      )
      #expect(keys == [.key(.character(UInt32(prefix[1])), .alt)] + suffixKeys)
      #expect(!decoder.hasPending)
    }
  }

  @Test(arguments: [29, 30, 31, 32, 4096])
  func overlongCSIIsIndependentOfReadBoundaries(_ parameterCount: Int) {
    let parameters = String(repeating: "1", count: parameterCount)
    let bytes = Array(("\u{1B}[" + parameters + "A\r").utf8)
    let splits = Set(
      Array(0 ... min(40, bytes.count)) + [bytes.count - 1, bytes.count]
    )
    for split in splits.sorted() {
      var decoder = InputDecoder()
      var events = decoder.feed(bytes.prefix(split))
      events += decoder.feed(bytes.dropFirst(split))
      let text =
        events.compactMap { event -> String? in
          if case let .text(value) = event { return value }
          return nil
        }
        .joined()
      let keys = events.filter {
        if case .key = $0 { return true };
        return false
      }
      #expect(text == (parameterCount <= 30 ? "" : parameters + "A"))
      #expect(
        keys == [
          parameterCount <= 30 ? .key(.up, []) : .key(.character(0x5B), .alt),
          .key(.enter, []),
        ]
      )
      #expect(!decoder.hasPending)
    }
  }

  @Test
  func cursorAndFunctionKeys() {
    var d = InputDecoder()
    #expect(
      d.feed(
        Array("\u{1B}[A\u{1B}[1;5C\u{1B}OP\u{1B}[15~\u{1B}[3~\u{1B}[Z".utf8)
      ) == [
        .key(.up, []), .key(.right, .control), .key(.function(1), []),
        .key(.function(5), []), .key(.delete, []), .key(.tab, .shift),
      ]
    )
  }

  @Test
  func escapeNeedsTheInterByteDelay() {
    var d = InputDecoder()
    #expect(d.feed([0x1B]).isEmpty)
    #expect(d.hasPending)
    #expect(d.flushPending() == [.key(.escape, [])])
    // ESC followed promptly by a key is Alt+key.
    #expect(d.feed(Array("\u{1B}x".utf8)) == [.key(.character(0x78), .alt)])
    // A split CSI waits for its final byte.
    #expect(d.feed(Array("\u{1B}[1;".utf8)).isEmpty)
    #expect(d.feed(Array("3D".utf8)) == [.key(.left, .alt)])
  }

  @Test
  func bracketedPasteKeepsPrefixBytesLiteral() {
    var d = InputDecoder()
    let start = Array("\u{1B}[200~a\u{02}".utf8)
    #expect(d.feed(start).isEmpty)
    #expect(d.feed(Array("b\u{1B}[20".utf8)).isEmpty)
    #expect(
      d.feed(Array("1~z".utf8)) == [
        .paste("a\u{02}b", truncated: false), .text("z"),
      ]
    )
  }

  @Test
  func oversizedPasteIsTruncatedNotUnbounded() {
    var d = InputDecoder(maxPasteBytes: 4)
    #expect(
      d.feed(Array("\u{1B}[200~abcdefgh\u{1B}[201~".utf8)) == [
        .paste("abcd", truncated: true)
      ]
    )
  }

  @Test(arguments: [Int.min, -1, 0, 1, Int.max])
  func extremeModifierParametersDoNotOverflow(parameter: Int) {
    var decoder = InputDecoder()
    let events = decoder.feed(Array("\u{1B}[1;\(parameter)A".utf8))
    #expect(events == [.key(.up, parameter <= 1 ? [] : [.alt, .control])])
  }
}

@Suite
struct RawTTYTests {
  @Test(arguments: [false, true])
  func restoresOriginalDescriptorFlags(nonblocking: Bool) throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    try PTYAllocation.open(master: &master, slave: &slave)
    defer {
      close(master);
      close(slave)
    }
    let output = open("/dev/null", O_WRONLY)
    try #require(output >= 0)
    defer { close(output) }
    let initial = fcntl(slave, F_GETFL)
    let flags = nonblocking ? initial | O_NONBLOCK : initial & ~O_NONBLOCK
    try #require(fcntl(slave, F_SETFL, flags) == 0)
    let tty = RawTTY(input: slave, output: output)
    // Cleanup before entry must leave the inherited descriptor alone.
    tty.restore()
    #expect(fcntl(slave, F_GETFL) == flags)
    try tty.enter()
    #expect(fcntl(slave, F_GETFL) & O_NONBLOCK != 0)
    tty.restore()
    #expect(fcntl(slave, F_GETFL) == flags)
    tty.restore()
    #expect(fcntl(slave, F_GETFL) == flags)
  }
}

@Suite
struct DiffRendererTests {
  @Test(arguments: [
    LayoutRect(x: 10, y: 0, width: 2, height: 2),
    LayoutRect(x: 0, y: 10, width: 2, height: 2),
    LayoutRect(x: -10, y: 0, width: 2, height: 2),
    LayoutRect(x: 0, y: -10, width: 2, height: 2),
  ])
  func fillingAnOffscreenRectangleDoesNothing(rect: LayoutRect) {
    var screen = ScreenBuffer(columns: 4, rows: 2)
    let original = screen
    screen.fill(rect, style: OuterStyle(background: .palette(1)))
    #expect(screen == original)
  }

  @Test(arguments: [0, 1, 2])
  func searchHighlightsAreClippedWhenPaneHeightShrinks(height: Int) throws {
    var frame = try BridgeTests.validFrame()
    frame.search = FrameSearch(
      matchCount: 1,
      selected: 0,
      visible: [
        FrameSpan(startRow: 1, startColumn: 0, endRow: 1, endColumn: 0)
      ],
      selectedVisible: 0
    )
    try FrameValidator.validate(frame)
    var screen = ScreenBuffer(columns: 4, rows: 2)
    Compositor(columns: 4, rows: 2)
      .draw(
        frame,
        in: LayoutRect(x: 0, y: 0, width: 4, height: height),
        overlay: nil,
        into: &screen
      )
    #expect(
      screen[0, 1].style.background == (height == 2 ? .palette(3) : .default)
    )
  }

  @Test
  func onlyChangedCellsAreRedrawn() {
    var r = DiffRenderer()
    var a = ScreenBuffer(columns: 10, rows: 2)
    a.write("hello", x: 0, y: 0, style: .plain)
    let first = String(decoding: r.update(to: a), as: UTF8.self)
    #expect(first.contains("\u{1B}[2J"))
    r.commit(a)
    var b = a
    b.write("J", x: 0, y: 1, style: .plain)
    let second = String(decoding: r.update(to: b), as: UTF8.self)
    #expect(!second.contains("\u{1B}[2J"))
    #expect(second.contains("\u{1B}[2;1H"))
    #expect(!second.contains("hello"))
    #expect(second.hasPrefix("\u{1B}[?2026h"))
    #expect(second.hasSuffix("\u{1B}[?2026l"))
  }

  @Test
  func outputThroughTheEngineReproducesTheScreen() {
    var r = DiffRenderer()
    var s = ScreenBuffer(columns: 12, rows: 3)
    s.write("abc", x: 0, y: 0, style: OuterStyle(foreground: .palette(1)))
    s.put(ScreenCell(text: "界", width: 2), x: 4, y: 1)
    s.write("│", x: 8, y: 2, style: .plain)
    let session = TerminalSession(columns: 12, rows: 3)
    session.feed(r.update(to: s))
    r.commit(s)
    #expect(session.withState { $0.screenLines } == (0 ..< 3).map(s.text(row:)))
  }
}

/// Runs the real `swmux` client against the service with an outer PTY
/// whose output is parsed by the Swiftty engine (the fixed host profile).
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct TerminalClientTests {
  final class Outer: @unchecked Sendable {
    let master: Int32
    let slave: Int32
    let host = TerminalSession(columns: 80, rows: 24)
    private let source: DispatchSourceRead

    init() throws {
      var m: Int32 = -1
      var s: Int32 = -1
      var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
      try PTYAllocation.open(master: &m, slave: &s, size: &size)
      master = m
      slave = s
      _ = fcntl(m, F_SETFL, fcntl(m, F_GETFL) | O_NONBLOCK)
      source = DispatchSource.makeReadSource(
        fileDescriptor: m,
        queue: .global()
      )
      let host = self.host
      source.setEventHandler {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = read(m, &buffer, buffer.count)
        if n > 0 { host.feed(Array(buffer[0 ..< n])) }
      }
      source.resume()
    }

    func type(_ s: String) {
      _ = s.utf8CString.withUnsafeBufferPointer {
        write(master, $0.baseAddress, $0.count - 1)
      }
    }

    var lines: [String] { host.withState { $0.screenLines } }

    func wait(_ predicate: @Sendable ([String]) -> Bool) async -> Bool {
      for _ in 0 ..< 200 {
        if predicate(lines) { return true }
        try? await Task.sleep(for: .milliseconds(25))
      }
      return false
    }

    deinit {
      source.cancel()
      close(master)
      close(slave)
    }
  }

  @Test
  func copyModeLineEndUsesDisplayColumns() async throws {
    let h = try Harness()
    let connection = try await h.connect(.terminal)
    guard
      case let .created(ws) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(name: "demo", launch: shellLaunch()))
      ),
      case let .attached(attachment, workspace) = try await connection.execute(
        .attach(.id(ws.id))
      )
    else {
      Issue.record("setup")
      return
    }
    let outer = try Outer()
    let client = TerminalClient(
      connection: connection,
      attachment: attachment,
      workspace: workspace,
      limits: .standard,
      tty: RawTTY(input: outer.slave, output: outer.slave)
    )
    let session = TerminalSession(columns: 8, rows: 2)
    session.feed(Array("e\u{301} a漢\r".utf8))
    var identity = BridgeTests.identity()
    identity.attachment = attachment
    identity.pane = try #require(workspace.activeTabSnapshot?.activePane)
    let frame = try FrameExporter.frame(
      from: session.withState { $0.captureOwnedScreen() },
      identity: identity
    )
    client.handle(.frame(frame))
    client.feed(Array("\u{02}[$".utf8))
    #expect(client.compose()[3, 0].style.flags & OuterStyle.inverse != 0)
    // Moving to the next word stays within the display grid.
    client.feed(Array("w".utf8))
    #expect(client.compose()[7, 0].style.flags & OuterStyle.inverse != 0)
    await connection.close()
  }

  @Test(arguments: [false, true])
  func cancellationRestoresTerminalAndSignalDisposition(
    beforeStart: Bool
  ) async throws {
    let h = try Harness()
    let control = try await h.connect(.control)
    let connection = try await h.connect(.terminal)
    var original = sigaction()
    try #require(sigaction(SIGWINCH, nil, &original) == 0)
    defer { _ = sigaction(SIGWINCH, &original, nil) }
    var expected = sigaction()
    expected.__sigaction_u.__sa_handler = SIG_IGN
    expected.sa_flags = SA_RESTART
    sigemptyset(&expected.sa_mask)
    sigaddset(&expected.sa_mask, SIGUSR1)
    try #require(sigaction(SIGWINCH, &expected, nil) == 0)
    do {
      guard
        case let .created(ws) = try await connection.execute(
          .newWorkspace(
            NewWorkspaceRequest(name: "cancel", launch: shellLaunch())
          )
        ),
        case let .attached(attachment, workspace) =
          try await connection.execute(.attach(.id(ws.id)))
      else { throw MuxError(.invalidRequest, "setup") }
      let outer = try Outer()
      var saved = termios()
      try #require(tcgetattr(outer.slave, &saved) == 0)
      let savedFlags = fcntl(outer.slave, F_GETFL)
      let client = TerminalClient(
        connection: connection,
        attachment: attachment,
        workspace: workspace,
        limits: .standard,
        tty: RawTTY(input: outer.slave, output: outer.slave)
      )
      let run = Task { await client.run() }
      defer { run.cancel() }
      if !beforeStart {
        try #require(
          await outer.wait { $0.last?.hasPrefix("[cancel] 0:1*") == true }
        )
        #expect(
          await client.run() == .failed("terminal client is already running")
        )
      }
      run.cancel()
      // Give the old implementation a bounded escape without concealing its
      // lack of cancellation: that escape returns a different outcome.
      let fallback = Task {
        try? await Task.sleep(for: .milliseconds(500))
        if !Task.isCancelled {
          client.handle(.detached(reason: "cancel timeout"))
        }
      }
      defer { fallback.cancel() }
      #expect(await run.value == .detached("cancelled"))
      #expect(await client.run() == .detached("cancelled"))
      var restored = termios()
      try #require(tcgetattr(outer.slave, &restored) == 0)
      #expect(restored.c_lflag == saved.c_lflag)
      #expect(restored.c_iflag == saved.c_iflag)
      #expect(restored.c_oflag == saved.c_oflag)
      #expect(restored.c_cflag == saved.c_cflag)
      // Darwin records an internal written bit after output; F_SETFL cannot
      // clear it. Compare the caller-controlled status flags instead.
      let mutableFlags = O_NONBLOCK | O_APPEND | O_ASYNC
      #expect(
        fcntl(outer.slave, F_GETFL) & mutableFlags == savedFlags & mutableFlags
      )
      var actual = sigaction()
      try #require(sigaction(SIGWINCH, nil, &actual) == 0)
      #expect(actual.sa_flags == expected.sa_flags)
      #expect(actual.sa_mask == expected.sa_mask)
      #expect(
        unsafeBitCast(actual.__sigaction_u.__sa_handler, to: UInt.self)
          == unsafeBitCast(expected.__sigaction_u.__sa_handler, to: UInt.self)
      )
      guard
        case let .workspaces(list) = try await control.execute(.listWorkspaces)
      else { throw MuxError(.invalidRequest, "workspaces reply") }
      #expect(list.first?.isAttached == false)
      try await control.execute(.endAllWorkspaces)
      await connection.close()
      await control.close()
    } catch {
      await connection.close()
      _ = try? await control.execute(.endAllWorkspaces)
      await control.close()
      throw error
    }
  }

  @Test
  func closingTheConnectionEndsTheTerminalRun() async throws {
    let h = try Harness()
    let connection = try await h.connect(.terminal)
    guard
      case let .created(ws) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(name: "demo", launch: shellLaunch()))
      ),
      case let .attached(attachment, workspace) = try await connection.execute(
        .attach(.id(ws.id))
      )
    else {
      Issue.record("setup")
      return
    }
    let outer = try Outer()
    let client = TerminalClient(
      connection: connection,
      attachment: attachment,
      workspace: workspace,
      limits: .standard,
      tty: RawTTY(input: outer.slave, output: outer.slave)
    )
    let run = Task { await client.run() }
    #expect(await outer.wait { $0.last?.hasPrefix("[demo] 0:1*") == true })
    await connection.close()
    // Bound the regression even if EOF leaves run waiting forever.
    let fallback = Task {
      try? await Task.sleep(for: .milliseconds(500))
      if !Task.isCancelled { client.handle(.detached(reason: "EOF timeout")) }
    }
    defer { fallback.cancel() }
    #expect(await run.value == .lost("connection closed"))
    var restored = termios()
    try #require(tcgetattr(outer.slave, &restored) == 0)
    #expect(restored.c_lflag & UInt(ICANON) != 0)
  }

  @Test
  func attachTypeSplitAndDetach() async throws {
    let h = try Harness()
    let connection = try await h.connect(.terminal)
    guard
      case let .created(ws) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(name: "demo", launch: shellLaunch()))
      ),
      case let .attached(attachment, workspace) = try await connection.execute(
        .attach(.id(ws.id))
      )
    else {
      Issue.record("setup");
      return
    }
    let outer = try Outer()
    let client = TerminalClient(
      connection: connection,
      attachment: attachment,
      workspace: workspace,
      limits: .standard,
      tty: RawTTY(input: outer.slave, output: outer.slave)
    )
    let run = Task { await client.run() }
    #expect(await outer.wait { $0.last?.hasPrefix("[demo] 0:1*") == true })
    outer.type("echo typed-$((6*7))\r")
    #expect(await outer.wait { $0.contains("typed-42") })
    // Prefix + % splits left/right: a divider column appears.
    outer.type("\u{02}%")
    #expect(
      await outer.wait { lines in
        lines.prefix(3).allSatisfy { $0.contains("│") }
      }
    )
    // The new pane is active and receives typing.
    outer.type("echo right-pane\r")
    #expect(
      await outer.wait {
        $0.contains { $0.contains("│") && $0.hasSuffix("right-pane") }
      }
    )
    // Copy mode and quit leave the panes intact.
    outer.type("\u{02}[")
    #expect(await outer.wait { $0.last?.contains("[copy") == true })
    outer.type("q")
    #expect(await outer.wait { $0.last?.contains("[copy") == false })
    // Detach restores the outer screen and keeps the workspace.
    outer.type("\u{02}d")
    let outcome = await run.value
    #expect(outcome == .detached("detached from demo"))
    let control = try await h.connect(.control)
    guard
      case let .workspaces(list) = try await control.execute(.listWorkspaces)
    else { return }
    #expect(list.first?.paneCount == 2)
    #expect(list.first?.isAttached == false)
  }

  /// prefix-w with the current workspace's name: the service drops the
  /// connection's subscriptions on every switch, so the client must
  /// resubscribe or the pane stops updating.
  @Test
  func switchingToTheCurrentWorkspaceKeepsPanesLive() async throws {
    let h = try Harness()
    let connection = try await h.connect(.terminal)
    guard
      case let .created(ws) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(name: "demo", launch: shellLaunch()))
      ),
      case let .attached(attachment, workspace) = try await connection.execute(
        .attach(.id(ws.id))
      )
    else {
      Issue.record("setup")
      return
    }
    let outer = try Outer()
    let client = TerminalClient(
      connection: connection,
      attachment: attachment,
      workspace: workspace,
      limits: .standard,
      tty: RawTTY(input: outer.slave, output: outer.slave)
    )
    let run = Task { await client.run() }
    #expect(await outer.wait { $0.last?.hasPrefix("[demo] 0:1*") == true })
    outer.type("\u{02}w")
    #expect(await outer.wait { $0.last?.contains("workspace (") == true })
    outer.type("demo\r")
    outer.type("echo after-$((6*7))\r")
    #expect(await outer.wait { $0.contains { $0.contains("after-42") } })
    outer.type("\u{02}d")
    #expect(await run.value == .detached("detached from demo"))
  }

  /// Layout events and the switch reply arrive on different paths: a
  /// newer layout of the target that overtakes the reply is kept, late
  /// layouts of the old workspace are ignored, and revisions never go
  /// backwards.
  @Test
  func switchKeepsTheNewestLayoutAcrossReorderedReplies() async throws {
    let h = try Harness()
    let connection = try await h.connect(.terminal)
    guard
      case let .created(one) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(name: "one", launch: shellLaunch()))
      ),
      case let .created(two) = try await connection.execute(
        .newWorkspace(NewWorkspaceRequest(name: "two", launch: shellLaunch()))
      ),
      case let .attached(attachment, workspace) = try await connection.execute(
        .attach(.id(one.id))
      ),
      case let .layout(reply) = try await connection.execute(
        .switchWorkspace(.id(two.id))
      )
    else {
      Issue.record("setup")
      return
    }
    let outer = try Outer()
    let client = TerminalClient(
      connection: connection,
      attachment: attachment,
      workspace: workspace,
      limits: .standard,
      tty: RawTTY(input: outer.slave, output: outer.slave)
    )
    // The target's newer layout event overtakes the switch reply.
    var newer = reply
    newer.name = "two-renamed"
    newer.layoutRevision += 1
    client.handle(.layout(newer))
    #expect(client.workspace.id == one.id)
    client.apply(reply, attached: true)
    #expect(client.workspace == newer)
    // A late layout of the old workspace and an older one are ignored.
    var late = workspace
    late.layoutRevision += 5
    client.handle(.layout(late))
    client.handle(.layout(reply))
    #expect(client.workspace == newer)
    await connection.close()
  }
}
