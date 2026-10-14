import Darwin
import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneRegistrationTests {
  private func retire(_ service: MuxService) {
    let done = DispatchSemaphore(value: 0)
    service.prepareToExit { done.signal() }
    #expect(done.wait(timeout: .now() + 5) == .success)
  }

  @Test(arguments: [false, true])
  func exitBeforeLaunchReturnsPreservesStatus(remainOnExit: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pane-registration-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    let executable = directory.appendingPathComponent("launcher")
    // Keep the report pipe open in a separate, finite-lived group after
    // the PTY leader exits. launch() therefore returns an already-dead
    // child, exercising its synchronous exit check deterministically.
    try """
    #!/usr/bin/python3
    import ctypes,os,select,signal,sys,time
    assert ctypes.CDLL(None).login_tty(3)==0
    ready_read,ready_write=os.pipe()
    helper=os.fork()
    if helper==0:
        os.setpgid(0,0)
        signal.signal(signal.SIGHUP,signal.SIG_IGN)
        for fd in (0,1,2): os.close(fd)
        os.write(ready_write,b'ready')
        time.sleep(0.3)
        os._exit(0)
    os.close(ready_write)
    assert select.select([ready_read],[],[],1)[0]
    assert os.read(ready_read,5)==b'ready'
    os.close(ready_read)
    with open(os.path.join(sys.argv[1],'pid'),'w') as f: f.write(str(os.getpid()))
    os.write(4,b'S exec 0\\n')
    os.close(4)
    print('\\033]0;early-title\\007\\033]7501;state=error:id=early:msg=ZmluYWw=\\007final-line',flush=True)
    os._exit(7)
    """
    .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executable.path,
    )
    let service = try MuxService(
      configuration: MuxServiceConfiguration(launcherPath: executable.path)
    )
    defer {
      retire(service)
      try? FileManager.default.removeItem(at: directory)
    }
    let c = try await MuxConnection.connect(
      endpoint: service.listenAnonymously(),
      frontend: .native,
    )
    var launch = shellLaunch()
    launch.command = ["/bin/true"]
    launch.workingDirectory = directory.path
    guard
      case let .created(ws) = try await c.execute(
        .newWorkspace(
          NewWorkspaceRequest(launch: launch, remainOnExit: remainOnExit, )
        ),
      )
    else { throw MuxError(.invalidRequest, "creation reply") }
    let pane = ws.tabs[0].activePane
    let deadline = ContinuousClock.now + .seconds(2)
    var list: [WorkspaceSummary] = []
    repeat {
      guard case let .workspaces(current) = try await c.execute(.listWorkspaces)
      else { throw MuxError(.invalidRequest, "workspace list") }
      list = current
      if remainOnExit ? list.first?.livePaneCount == 0 : list.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    } while ContinuousClock.now < deadline
    if remainOnExit {
      let snapshot = try await c.attachAndShow(.id(ws.id))
      #expect(snapshot.pane(pane)?.exitStatus == 7)
    } else {
      #expect(list.isEmpty)
    }
    let pidFile = directory.appendingPathComponent("pid")
    let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
    var info = siginfo_t()
    #expect(waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == -1)
    #expect(errno == ECHILD)
    await c.close()
  }

  @Test
  func immediateRealLaunchesPreserveFinalOutputAndMetadata() async throws {
    let h = try Harness()
    defer { retire(h.service) }
    let c = try await h.connect()
    for index in 0 ..< 12 {
      var launch = shellLaunch()
      launch.command = [
        "/bin/sh", "-c",
        "printf '\\033]0;early-title\\007\\033]7501;state=error:id=early:msg=ZmluYWw=\\007final-\(index)\\n'; exit 7",
      ]
      guard
        case let .created(ws) = try await c.execute(
          .newWorkspace(NewWorkspaceRequest(launch: launch, remainOnExit: true)),
        )
      else { throw MuxError(.invalidRequest, "creation reply") }
      let pane = ws.tabs[0].activePane
      let deadline = ContinuousClock.now + .seconds(2)
      while await h.service.panes[pane]?.exitStatus == nil,
        ContinuousClock.now < deadline
      { try await Task.sleep(for: .milliseconds(10)) }
      let snapshot = try await c.attachAndShow(.id(ws.id))
      #expect(snapshot.pane(pane)?.exitStatus == 7)
      #expect(snapshot.pane(pane)?.title == "early-title")
      _ = try await c.frame(of: pane) { $0.lines.contains("final-\(index)") }
      try await c.execute(.endWorkspace(.id(ws.id)))
    }
    guard
      case let .inbox(page) = try await c.execute(.inbox(InboxQuery(limit: 20)))
    else { throw MuxError(.invalidRequest, "inbox reply") }
    #expect(page.items.count == 12)
    #expect(
      page.items.allSatisfy {
        $0.status.message == "final" && $0.resolution == .paneExited
      }
    )
    await c.close()
  }
}
