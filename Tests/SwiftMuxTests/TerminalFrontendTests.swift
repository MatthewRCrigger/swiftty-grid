import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxTerminal
import SwifttyCore
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
}

@Suite
struct DiffRendererTests {
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

    init() {
      var m: Int32 = -1
      var s: Int32 = -1
      var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
      openpty(&m, &s, nil, nil, &size)
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
    let outer = Outer()
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
}
