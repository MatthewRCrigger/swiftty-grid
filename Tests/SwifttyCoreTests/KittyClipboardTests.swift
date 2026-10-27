@testable import SwifttyCore
@testable import SwifttyEngine
import Synchronization
import Testing

/// Kitty clipboard protocol (OSC 5522), ported from Ghostty's
/// `kitty clipboard` and `paste: mode 5522` stream tests.
struct KittyClipboardTests {
  final class Capture: Sendable {
    struct State {
      var reads: [KittyClipboard.ReadRequest] = []
      var writes: [KittyClipboard.WriteRequest] = []
      var readResult: KittyClipboard.ReadResult? = .denied
      var writeResult: KittyClipboard.WriteResult? = .success(remember: false)
    }

    let state = Mutex(State())

    var reads: [KittyClipboard.ReadRequest] { state.withLock { $0.reads } }
    var writes: [KittyClipboard.WriteRequest] { state.withLock { $0.writes } }
    var lastRead: KittyClipboard.ReadRequest? { reads.last }
    var lastWrite: KittyClipboard.WriteRequest? { writes.last }

    func set(read: KittyClipboard.ReadResult?) {
      state.withLock { $0.readResult = read }
    }

    func set(write: KittyClipboard.WriteResult?) {
      state.withLock { $0.writeResult = write }
    }

    var reader: KittyClipboard.Reader {
      { [self] request in
        state.withLock {
          $0.reads.append(request)
          return $0.readResult
        }
      }
    }

    var writer: KittyClipboard.Writer {
      { [self] request in
        state.withLock {
          $0.writes.append(request)
          return $0.writeResult
        }
      }
    }
  }

  private func terminal(
    _ capture: Capture,
    read: Bool = false,
    write: Bool = true
  ) -> VT {
    var vt = VT(20, 5)
    if read { vt.state.kittyClipboardReader = capture.reader }
    if write { vt.state.kittyClipboardWriter = capture.writer }
    return vt
  }

  private static func text(_ content: KittyClipboard.Content) -> String {
    String(decoding: content.data, as: UTF8.self)
  }

  // MARK: Writes

  @Test
  func `write transaction round trip`() {
    let capture = Capture()
    var vt = terminal(capture)
    vt.feed("\u{1B}]5522;type=write:id=42\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;dHk=\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9odG1s;PGI+aGk8L2I+\u{1B}\\")
    vt.feed(
      "\u{1B}]5522;type=walias:mime=dGV4dC9wbGFpbg==;VEVYVCBVVEY4X1NUUklORw==\u{1B}\\"
    )
    #expect(capture.writes.isEmpty)
    #expect(vt.takeOutput() == "")
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    let write = capture.lastWrite
    #expect(capture.writes.count == 1)
    #expect(write?.primary == false)
    #expect(
      write?.contents.map(\.mime) == [
        "text/plain", "text/html", "TEXT", "UTF8_STRING",
      ]
    )
    #expect(
      write?.contents.map(Self.text) == [
        "Ghostty", "<b>hi</b>", "Ghostty", "Ghostty",
      ]
    )
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=DONE:id=42\u{1B}\\"
    )
    // A commit without a transaction is ignored.
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(capture.writes.count == 1)
    #expect(vt.takeOutput() == "")
  }

  @Test(arguments: [
    (KittyClipboard.WriteResult?.some(.success(remember: false)), "DONE"),
    (.denied, "EPERM"), (.unsupported, "ENOSYS"), (.busy, "EBUSY"),
    (.invalidData, "EINVAL"), (.ioError, "EIO"), (nil, "EPERM"),
  ])
  func `write results map to response statuses`(
    _ result: KittyClipboard.WriteResult?,
    _ status: String
  ) {
    let capture = Capture()
    capture.set(write: result)
    var vt = terminal(capture)
    // An immediately committed write with no data is a clear.
    vt.feed("\u{1B}]5522;type=write\u{1B}\\\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(capture.lastWrite?.contents == [])
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=\(status)\u{1B}\\"
    )
  }

  @Test
  func `responses echo the terminator and primary writes keep their id`() {
    let capture = Capture()
    var vt = terminal(capture)
    vt.feed(
      "\u{1B}]5522;type=write:loc=primary\u{7}\u{1B}]5522;type=wdata\u{7}"
    )
    #expect(capture.lastWrite?.primary == true)
    #expect(vt.takeOutput() == "\u{1B}]5522;type=write:status=DONE\u{7}")
    capture.set(write: .unsupported)
    vt.feed("\u{1B}]5522;type=write:loc=primary:id=p1\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=ENOSYS:id=p1\u{1B}\\"
    )
  }

  @Test
  func `write without a writer fails once with ENOSYS`() {
    let capture = Capture()
    var vt = terminal(capture, write: false)
    vt.feed("\u{1B}]5522;type=write:id=x\u{1B}\\")
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=ENOSYS:id=x\u{1B}\\"
    )
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `new write replaces the transaction in flight`() {
    let capture = Capture()
    var vt = terminal(capture)
    vt.feed("\u{1B}]5522;type=write:id=old\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;b2xk\u{1B}\\")
    vt.feed("\u{1B}]5522;type=write:id=new\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;bmV3\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(capture.writes.count == 1)
    #expect(capture.lastWrite?.contents.map(Self.text) == ["new"])
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=DONE:id=new\u{1B}\\"
    )
  }

  // MARK: Malformed packets and limits

  @Test
  func `malformed packets are dropped silently`() {
    let capture = Capture()
    var vt = terminal(capture)
    for packet in [
      "5522;", "5522;;", "5522;loc=primary", "5522;type=bobr",
      "5522;type=read:bare", "5522;type=wdata:mime=!!!;R2hvc3Q=",
      "5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=",
      "5522;type=walias:mime=dGV4dC9wbGFpbg==;VEVYVA==",
    ] { vt.feed("\u{1B}]\(packet)\u{1B}\\") }
    #expect(capture.writes.isEmpty)
    #expect(vt.takeOutput() == "")
    vt.feed("ok")
    #expect(vt.lines[0] == "ok")
  }

  @Test(arguments: [
    "5522;type=walias:mime=dGV4dC9wbGFpbg==;/w==", "5522;type=walias;VEVYVA==",
    "5522;type=walias:mime=//4=;VEVYVA==", "5522;type=wdata:mime=//4=;R2hvc3Q=",
    "5522;type=wdata:mime=dGV4dC9wbGFpbg==;!!!bad!!!",
  ])
  func `invalid write packets abort with EINVAL`(_ packet: String) {
    let capture = Capture()
    var vt = terminal(capture)
    vt.feed("\u{1B}]5522;type=write:id=w\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\u{1B}\\")
    vt.feed("\u{1B}]\(packet)\u{1B}\\")
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=EINVAL:id=w\u{1B}\\"
    )
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;V29ybGQ=\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(capture.writes.isEmpty)
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `invalid read text does not abort a write`() {
    let capture = Capture()
    capture.set(read: .success(available: [], contents: [], remember: false))
    var vt = terminal(capture, read: true)
    vt.feed("\u{1B}]5522;type=write:id=w\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\u{1B}\\")
    vt.feed("\u{1B}]5522;type=read;/w==\u{1B}\\")
    #expect(capture.reads.isEmpty)
    #expect(vt.takeOutput() == "")
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=DONE:id=w\u{1B}\\"
    )
  }

  @Test
  func `oversized writes abort with EFBIG`() {
    let capture = Capture()
    var vt = terminal(capture)
    vt.state.kittyClipboardWriteLimit = 4
    vt.feed("\u{1B}]5522;type=write:id=w\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGVsbA==\u{1B}\\")
    #expect(vt.takeOutput() == "")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;bw==\u{1B}\\")
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=EFBIG:id=w\u{1B}\\"
    )
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;IQ==\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(capture.writes.isEmpty)
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `wdata chunks split one base64 stream`() {
    let capture = Capture()
    var vt = terminal(capture)
    vt.feed("\u{1B}]5522;type=write\u{1B}\\")
    for chunk in ["c29", "tZSBk", "YXRh"] {
      vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;\(chunk)\u{1B}\\")
    }
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(capture.lastWrite?.contents.map(Self.text) == ["some data"])
    #expect(vt.takeOutput() == "\u{1B}]5522;type=write:status=DONE\u{1B}\\")
  }

  @Test
  func `independently padded chunks restart the stream`() {
    let capture = Capture()
    var vt = terminal(capture)
    vt.feed("\u{1B}]5522;type=write\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGk=\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;IQ==\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(capture.lastWrite?.contents.map(Self.text) == ["Hi!"])
    // Data after padding inside one packet is invalid.
    vt.feed("\u{1B}]5522;type=write:id=x\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGk=IQ==\u{1B}\\")
    #expect(
      vt.takeOutput()
        .hasSuffix("\u{1B}]5522;type=write:status=EINVAL:id=x\u{1B}\\")
    )
  }

  @Test
  func `unpadded wdata stream aborts at commit`() {
    let capture = Capture()
    var vt = terminal(capture)
    vt.feed("\u{1B}]5522;type=write:id=w\u{1B}\\")
    vt.feed("\u{1B}]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGVsbG8\u{1B}\\")
    #expect(vt.takeOutput() == "")
    vt.feed("\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(capture.writes.isEmpty)
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=EINVAL:id=w\u{1B}\\"
    )
  }

  // MARK: Reads

  @Test
  func `read without a reader is denied`() {
    let capture = Capture()
    var vt = terminal(capture)
    vt.feed(
      "\u{1B}]5522;type=read:loc=primary:id=*4 2*;dGV4dC9wbGFpbg==\u{1B}\\"
    )
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=read:status=EPERM:id=42\u{1B}\\"
    )
    vt.feed("\u{1B}]5522;type=read\u{7}")
    #expect(vt.takeOutput() == "\u{1B}]5522;type=read:status=EPERM\u{7}")
    vt.feed("\u{1B}]5522;type=read;!!!\u{1B}\\")
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `read round trip serves requested types in request order`() {
    let capture = Capture()
    capture.set(
      read: .success(
        available: ["text/plain", "text/html"],
        contents: [
          .init(mime: "image/png", data: [0x89, 0x50, 0x4E, 0x47]),
          .init(mime: "text/html", data: Array("<b>hi</b>".utf8)),
          .init(mime: "text/plain", data: Array("Ghostty".utf8)),
        ],
        remember: false
      )
    )
    var vt = terminal(capture, read: true)
    vt.feed(
      "\u{1B}]5522;type=read:loc=primary:id=r1;LiB0ZXh0L3BsYWluIHRleHQvaHRtbA==\u{1B}\\"
    )
    #expect(
      capture.lastRead
        == KittyClipboard.ReadRequest(
          primary: true,
          mimes: ["text/plain", "text/html"],
          list: true,
          name: "",
          granted: false,
          canRemember: false,
          token: 1
        )
    )
    #expect(
      vt.takeOutput()
        == "\u{1B}]5522;type=read:status=OK:loc=primary:id=r1\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DATA:id=r1:mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DATA:id=r1:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DATA:id=r1:mime=dGV4dC9odG1s;PGI+aGk8L2I+\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DONE:id=r1\u{1B}\\"
    )
    vt.feed("\u{1B}]5522;type=read:id=r2;dGV4dC9wbGFpbg==\u{7}")
    #expect(capture.lastRead?.list == false)
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=read:status=OK:id=r2\u{7}"
        + "\u{1B}]5522;type=read:status=DATA:id=r2:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\u{7}"
        + "\u{1B}]5522;type=read:status=DONE:id=r2\u{7}"
    )
    vt.feed("\u{1B}]5522;type=read;Lg==\u{1B}\\")
    #expect(capture.lastRead?.mimes == [])
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=read:status=OK\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DATA:mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DONE\u{1B}\\"
    )
  }

  @Test(arguments: [
    (KittyClipboard.ReadResult?.some(.denied), "EPERM"),
    (.unsupported, "ENOSYS"), (.busy, "EBUSY"), (.ioError, "EIO"),
    (nil, "EPERM"),
  ])
  func `read results map to response statuses`(
    _ result: KittyClipboard.ReadResult?,
    _ status: String
  ) {
    let capture = Capture()
    capture.set(read: result)
    var vt = terminal(capture, read: true)
    vt.feed("\u{1B}]5522;type=read:id=x;dGV4dC9wbGFpbg==\u{1B}\\")
    #expect(capture.reads.count == 1)
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=read:status=\(status):id=x\u{1B}\\"
    )
  }

  @Test
  func `successful reads with nothing to serve and long data`() {
    let capture = Capture()
    capture.set(read: .success(available: [], contents: [], remember: false))
    var vt = terminal(capture, read: true)
    vt.feed("\u{1B}]5522;type=read:id=x;dGV4dC9wbGFpbg==\u{1B}\\")
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=read:status=OK:id=x\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DONE:id=x\u{1B}\\"
    )
    // DATA packets carry at most 4096 raw bytes each.
    let data = [UInt8](repeating: 0x61, count: 4097)
    capture.set(
      read: .success(
        available: [],
        contents: [.init(mime: "text/plain", data: data)],
        remember: false
      )
    )
    vt.feed("\u{1B}]5522;type=read;dGV4dC9wbGFpbg==\u{1B}\\")
    let output = vt.takeOutput()
    #expect(output.components(separatedBy: "status=DATA").count == 3)
    #expect(output.contains(";YQ==\u{1B}\\"))
  }

  @Test
  func `reads cap requested types but keep the listing`() {
    let capture = Capture()
    capture.set(read: .success(available: [], contents: [], remember: false))
    var vt = terminal(capture, read: true)
    vt.feed(
      "\u{1B}]5522;type=read;YS8wIGEvMSBhLzIgYS8zIGEvNCBhLzUgLg==\u{1B}\\"
    )
    #expect(capture.lastRead?.mimes == ["a/0", "a/1", "a/2", "a/3"])
    #expect(capture.lastRead?.list == true)
  }

  @Test
  func `deferred reads are answered later and in any order`() {
    let capture = Capture()
    capture.set(read: .deferred)
    var vt = terminal(capture, read: true)
    vt.feed("\u{1B}]5522;type=read:id=a;dGV4dC9wbGFpbg==\u{1B}\\")
    vt.feed("\u{1B}]5522;type=read:id=b;dGV4dC9wbGFpbg==\u{7}")
    #expect(vt.takeOutput() == "")
    let tokens = capture.reads.map(\.token)
    #expect(tokens == [1, 2])
    vt.state.completeKittyClipboardRead(2, with: .denied)
    #expect(vt.takeOutput() == "\u{1B}]5522;type=read:status=EPERM:id=b\u{7}")
    vt.state.completeKittyClipboardRead(
      1,
      with: .success(
        available: [],
        contents: [.init(mime: "text/plain", data: Array("hi".utf8))],
        remember: false
      )
    )
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=read:status=OK:id=a\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DATA:id=a:mime=dGV4dC9wbGFpbg==;aGk=\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DONE:id=a\u{1B}\\"
    )
    // Answered and unknown tokens are ignored.
    vt.state.completeKittyClipboardRead(1, with: .denied)
    vt.state.completeKittyClipboardRead(9, with: .denied)
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `deferred reads remember grants, overflow and reset`() {
    let capture = Capture()
    capture.set(read: .deferred)
    var vt = terminal(capture, read: true)
    let secret =
      "\u{1B}]5522;type=read:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\u{1B}\\"
    vt.feed(secret)
    vt.state.completeKittyClipboardRead(
      1,
      with: .success(available: [], contents: [], remember: true)
    )
    vt.feed(secret)
    #expect(capture.lastRead?.granted == true)
    _ = vt.takeOutput()
    for i in 0 ..< 5 {
      vt.feed("\u{1B}]5522;type=read:id=r\(i);dGV4dC9wbGFpbg==\u{1B}\\")
    }
    // Only four may wait (the granted read above waits too): the oldest
    // waiting reads are refused.
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=read:status=EBUSY\u{1B}\\"
        + "\u{1B}]5522;type=read:status=EBUSY:id=r0\u{1B}\\"
    )
    vt.feed("\u{1B}c")
    vt.state.completeKittyClipboardRead(4, with: .denied)
    #expect(vt.takeOutput() == "")
  }

  @Test
  func `deferred writes are answered later`() {
    let capture = Capture()
    capture.set(write: .deferred)
    var vt = terminal(capture)
    vt.feed("\u{1B}]5522;type=write:id=w\u{1B}\\\u{1B}]5522;type=wdata\u{1B}\\")
    #expect(vt.takeOutput() == "")
    let token = capture.lastWrite?.token ?? 0
    vt.state.completeKittyClipboardWrite(token, with: .success(remember: false))
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=DONE:id=w\u{1B}\\"
    )
    vt.state.completeKittyClipboardWrite(token, with: .denied)
    #expect(vt.takeOutput() == "")
    // A new transaction is not blocked by one waiting for its answer.
    vt.feed("\u{1B}]5522;type=write:id=x\u{1B}\\\u{1B}]5522;type=wdata\u{1B}\\")
    vt.state.completeKittyClipboardWrite(token + 1, with: .denied)
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=EPERM:id=x\u{1B}\\"
    )
  }

  // MARK: Permissions

  @Test
  func `read password grants`() {
    let capture = Capture()
    capture.set(read: .success(available: [], contents: [], remember: true))
    var vt = terminal(capture, read: true)
    let secret =
      "\u{1B}]5522;type=read:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\u{1B}\\"
    let other =
      "\u{1B}]5522;type=read:pw=b3RoZXI=:name=YXBw;dGV4dC9wbGFpbg==\u{1B}\\"
    vt.feed(secret)
    #expect(capture.lastRead?.name == "app")
    #expect(capture.lastRead?.granted == false)
    #expect(capture.lastRead?.canRemember == true)
    capture.set(read: .success(available: [], contents: [], remember: false))
    vt.feed(secret)
    #expect(capture.lastRead?.granted == true)
    vt.feed(other)
    #expect(capture.lastRead?.granted == false)
    #expect(capture.lastRead?.canRemember == true)
    // Without a name a password neither grants nor can be remembered.
    capture.set(read: .success(available: [], contents: [], remember: true))
    vt.feed("\u{1B}]5522;type=read:pw=c2VjcmV0;dGV4dC9wbGFpbg==\u{1B}\\")
    #expect(capture.lastRead?.name == "")
    #expect(capture.lastRead?.granted == false)
    #expect(capture.lastRead?.canRemember == false)
    vt.feed("\u{1B}]5522;type=read:pw=b3RoZXI=;dGV4dC9wbGFpbg==\u{1B}\\")
    vt.feed(other)
    #expect(capture.lastRead?.granted == false)
    // A grant is advisory: the host may still deny.
    _ = vt.takeOutput()
    capture.set(read: .denied)
    vt.feed(
      "\u{1B}]5522;type=read:id=d:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\u{1B}\\"
    )
    #expect(capture.lastRead?.granted == true)
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=read:status=EPERM:id=d\u{1B}\\"
    )
  }

  @Test
  func `write password grants are separate from reads`() {
    let capture = Capture()
    capture.set(write: .success(remember: true))
    capture.set(read: .success(available: [], contents: [], remember: false))
    var vt = terminal(capture, read: true)
    let write = "\u{1B}]5522;type=write:pw=c2VjcmV0:name=YXBw\u{1B}\\"
    let commit = "\u{1B}]5522;type=wdata\u{1B}\\"
    vt.feed(write + commit)
    #expect(capture.lastWrite?.name == "app")
    #expect(capture.lastWrite?.granted == false)
    #expect(capture.lastWrite?.canRemember == true)
    capture.set(write: .success(remember: false))
    vt.feed(write + commit)
    #expect(capture.lastWrite?.granted == true)
    vt.feed("\u{1B}]5522;type=write:pw=b3RoZXI=:name=YXBw\u{1B}\\" + commit)
    #expect(capture.lastWrite?.granted == false)
    vt.feed(
      "\u{1B}]5522;type=read:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\u{1B}\\"
    )
    #expect(capture.lastRead?.granted == false)
    capture.set(write: .success(remember: true))
    vt.feed("\u{1B}]5522;type=write:pw=c2VjcmV0\u{1B}\\" + commit)
    #expect(capture.lastWrite?.granted == false)
    #expect(capture.lastWrite?.canRemember == false)
    _ = vt.takeOutput()
    capture.set(write: .denied)
    vt.feed(
      "\u{1B}]5522;type=write:id=d:pw=c2VjcmV0:name=YXBw\u{1B}\\" + commit
    )
    #expect(capture.lastWrite?.granted == true)
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=write:status=EPERM:id=d\u{1B}\\"
    )
  }

  @Test
  func `listing-only reads never consume a one-time grant`() {
    let capture = Capture()
    capture.set(read: .success(available: [], contents: [], remember: false))
    var vt = terminal(capture, read: true)
    vt.state.kittyClipboardGrants.grant(Array("otp".utf8), .read, oneTime: true)
    vt.feed("\u{1B}]5522;type=read:pw=b3Rw:name=YXBw;Lg==\u{1B}\\")
    #expect(capture.lastRead?.list == true)
    #expect(capture.lastRead?.granted == false)
    let data =
      "\u{1B}]5522;type=read:pw=b3Rw:name=YXBw;dGV4dC9wbGFpbg==\u{1B}\\"
    vt.feed(data)
    #expect(capture.lastRead?.granted == true)
    vt.feed(data)
    #expect(capture.lastRead?.granted == false)
  }

  @Test
  func `full reset drops grants`() {
    let capture = Capture()
    capture.set(read: .success(available: [], contents: [], remember: false))
    var vt = terminal(capture, read: true)
    vt.state.kittyClipboardGrants.grant(Array("pw".utf8), .read, oneTime: false)
    vt.feed("\u{1B}c")
    #expect(vt.state.kittyClipboardGrants.count == 0)
    vt.feed("\u{1B}]5522;type=read:pw=cHc=:name=YXBw;dGV4dC9wbGFpbg==\u{1B}\\")
    #expect(capture.lastRead?.granted == false)
  }

  @Test
  func `grants keep the newest thirty-two passwords`() {
    var grants = KittyClipboard.Grants()
    for i in 0 ... 32 {
      grants.grant(Array("pw\(i)".utf8), .read, oneTime: false)
    }
    #expect(grants.count == 32)
    let evicted = grants.use(Array("pw0".utf8), .read)
    let read = grants.use(Array("pw32".utf8), .read)
    let write = grants.use(Array("pw32".utf8), .write)
    #expect(!evicted && read && !write)
  }

  // MARK: Paste events

  @Test
  func `paste events list types and mint a one-time password`() throws {
    let capture = Capture()
    capture.set(
      read: .success(
        available: [],
        contents: [.init(mime: "text/plain", data: Array("Ghostty".utf8))],
        remember: false
      )
    )
    var vt = terminal(capture, read: true)
    let off = vt.state.kittyPasteEvent(available: ["text/plain"])
    #expect(off == nil)
    vt.feed("\u{1B}[?5522h\u{1B}[?2004h")
    let maybeEvent = vt.state.kittyPasteEvent(available: [
      "text/plain", "image/png",
    ])
    let event = try #require(maybeEvent)
    let text = String(decoding: event, as: UTF8.self)
    let prefix = "\u{1B}]5522;type=read:status=OK:pw="
    #expect(text.hasPrefix(prefix))
    let pw = String(text.dropFirst(prefix.count).prefix { $0 != "\u{1B}" })
    #expect(pw.count == 32)  // 22 bytes of base64
    #expect(
      text == "\(prefix)\(pw)\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DATA:mime=Lg==:pw=\(pw);dGV4dC9wbGFpbiBpbWFnZS9wbmcK\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DONE:pw=\(pw)\u{1B}\\"
    )
    let read =
      "\u{1B}]5522;type=read:pw=\(pw):name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\u{1B}\\"
    vt.feed(read)
    #expect(capture.lastRead?.granted == true)
    #expect(capture.lastRead?.name == "Paste event")
    #expect(
      vt.takeOutput() == "\u{1B}]5522;type=read:status=OK\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\u{1B}\\"
        + "\u{1B}]5522;type=read:status=DONE\u{1B}\\"
    )
    vt.feed(read)
    #expect(capture.lastRead?.granted == false)
    let maybeNext = vt.state.kittyPasteEvent(available: ["text/plain"])
    let next = try #require(maybeNext)
    #expect(!String(decoding: next, as: UTF8.self).contains(pw))
  }

  @Test
  func `paste events report the selection as primary on the OK packet`() throws
  {
    let capture = Capture()
    var vt = terminal(capture, read: true)
    vt.feed("\u{1B}[?5522h")
    let maybeEvent = vt.state.kittyPasteEvent(
      available: ["text/plain"],
      primary: true
    )
    let event = String(decoding: try #require(maybeEvent), as: UTF8.self)
    #expect(event.hasPrefix("\u{1B}]5522;type=read:status=OK:loc=primary:pw="))
    #expect(event.components(separatedBy: "loc=primary").count == 2)
  }

  @Test
  func `paste events need a reader`() {
    let capture = Capture()
    var vt = terminal(capture)
    vt.feed("\u{1B}[?5522$p")
    #expect(vt.takeOutput() == "\u{1B}[?5522;0$y")
    vt.feed("\u{1B}[?5522h\u{1B}[?5522$p")
    #expect(vt.state.modes.contains(.kittyPasteEvents))
    #expect(vt.takeOutput() == "\u{1B}[?5522;0$y")
    let event = vt.state.kittyPasteEvent(available: ["text/plain"])
    #expect(event == nil)
    #expect(vt.state.kittyClipboardGrants.count == 0)
    vt.state.kittyClipboardReader = capture.reader
    vt.feed("\u{1B}[?5522$p\u{1B}[?5522l\u{1B}[?5522$p")
    #expect(vt.takeOutput() == "\u{1B}[?5522;1$y\u{1B}[?5522;2$y")
  }

  // MARK: Base64

  @Test(arguments: [("", ""), ("YQ==", "a"), ("YWI=", "ab"), ("YWJj", "abc")])
  func `strict base64 decodes padded values`(_ encoded: String, _ text: String)
  {
    #expect(Base64.decode(Array(encoded.utf8)) == Array(text.utf8))
    #expect(Base64.encode(Array(text.utf8)) == Array(encoded.utf8))
  }

  @Test(arguments: [
    "YQ", "YQ=", "Y===", "YR==", "YQ==YQ==", "Y Q==", "=", "YWJ=",
  ])
  func `strict base64 rejects malformed values`(_ encoded: String) {
    #expect(Base64.decode(Array(encoded.utf8)) == nil)
  }
}

/// The surfaces' read policy.
struct KittyClipboardPolicyTests {
  private func request(
    mimes: [String] = ["text/plain"],
    granted: Bool = false,
    primary: Bool = false,
    canRemember: Bool = true
  ) -> KittyClipboard.ReadRequest {
    KittyClipboard.ReadRequest(
      primary: primary,
      mimes: mimes,
      list: false,
      name: "app",
      granted: granted,
      canRemember: canRemember,
      token: 7
    )
  }

  private let contents: KittyClipboardPolicy.Contents = { mimes in
    (["text/plain"], mimes.map { .init(mime: $0, data: [0x61]) })
  }

  @Test
  func `granted and listing reads are served without asking`() {
    let reader = KittyClipboardPolicy.reader(contents)
    let served = KittyClipboard.ReadResult.success(
      available: ["text/plain"],
      contents: [.init(mime: "text/plain", data: [0x61])],
      remember: false
    )
    #expect(reader(request(granted: true)) == served)
    #expect(
      reader(request(mimes: []))
        == .success(available: ["text/plain"], contents: [], remember: false)
    )
    #expect(reader(request()) == .denied)
    #expect(reader(request(granted: true, primary: true)) == .unsupported)
  }

  @Test
  func `other reads are deferred to the prompt`() {
    let asked = Mutex<[UInt64]>([])
    let reader = KittyClipboardPolicy.reader(
      prompt: { request in asked.withLock { $0.append(request.token) } },
      contents
    )
    #expect(reader(request()) == .deferred)
    #expect(asked.withLock { $0 } == [7])
    #expect(
      KittyClipboardPolicy.result(for: request(), .deny, read: contents)
        == .denied
    )
    #expect(
      KittyClipboardPolicy.result(for: request(), .allowAlways, read: contents)
        == .success(
          available: ["text/plain"],
          contents: [.init(mime: "text/plain", data: [0x61])],
          remember: true
        )
    )
    #expect(
      KittyClipboardPolicy.result(
        for: request(canRemember: false),
        .allowAlways,
        read: contents
      )
        == .success(
          available: ["text/plain"],
          contents: [.init(mime: "text/plain", data: [0x61])],
          remember: false
        )
    )
    #expect(
      KittyClipboardPolicy.message(for: request())
        == "“app” wants to read the clipboard (text/plain)."
    )
  }
}
