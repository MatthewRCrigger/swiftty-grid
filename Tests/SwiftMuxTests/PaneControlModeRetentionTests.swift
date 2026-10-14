import Dispatch
import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
@testable import SwiftMuxService
import Testing

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneControlModeRetentionTests {
  private static let program = #"""
    import os,sys,time,tty,threading
    tty.setraw(0)
    written,release=sys.argv[1:]
    def watchdog():
        time.sleep(12)
        os._exit(99)
    threading.Thread(target=watchdog,daemon=True).start()
    def emit(data):
        while data: data=data[os.write(1,data):]
    emit(b'\x1bP1000p'+b'%output 1 ignored\n'*65536)
    with open(written,'w') as f: f.write('READY')
    while not os.path.exists(release): time.sleep(0.005)
    emit(b'%output 1 ignored\n'*65536+b'\x1b\\FINAL\n')
    os._exit(7)
    """#

  private func retire(_ service: MuxService) {
    let done = DispatchSemaphore(value: 0)
    service.prepareToExit { done.signal() }
    #expect(done.wait(timeout: .now() + 5) == .success)
  }

  @Test
  func unconsumedControlStreamsAreDrainedAtPublication() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pane-control-retention-" + UUID().uuidString)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    let written = directory.appendingPathComponent("written")
    let release = directory.appendingPathComponent("release")
    let service = try MuxService(
      configuration: MuxServiceConfiguration(launcherPath: launcherPath()),
    )
    defer {
      retire(service)
      try? FileManager.default.removeItem(at: directory)
    }
    let client = try await MuxConnection.connect(
      endpoint: service.listenAnonymously(),
      frontend: .control,
    )
    var launch = shellLaunch()
    launch.command = [
      "/usr/bin/python3", "-u", "-c", Self.program, written.path, release.path,
    ]
    guard
      case let .created(workspace) = try await client.execute(
        .newWorkspace(NewWorkspaceRequest(launch: launch, remainOnExit: true, ))
      )
    else { throw MuxError(.invalidRequest, "unexpected workspace") }
    let runtime = try #require(
      await service.runtime(workspace.tabs[0].activePane)
    )
    let deadline = ContinuousClock.now + .seconds(4)
    while !FileManager.default.fileExists(atPath: written.path),
      ContinuousClock.now < deadline
    { try await Task.sleep(for: .milliseconds(10)) }
    try #require(FileManager.default.fileExists(atPath: written.path))
    // The child has delivered over a megabyte without ending the stream.
    // Inspect between read turns, while the parser remains in control mode.
    let retained = await withCheckedContinuation { continuation in
      runtime.inspect {
        ($0.isControlMode, $0.controlModeData.count)
      } completion: {
        continuation.resume(returning: $0)
      }
    }
    #expect(retained.0)
    #expect(retained.1 == 0)
    try Data().write(to: release, options: .atomic)
    let finalDeadline = ContinuousClock.now + .seconds(4)
    while !runtime.screenLines().contains(where: { $0.contains("FINAL") }),
      ContinuousClock.now < finalDeadline
    { try await Task.sleep(for: .milliseconds(10)) }
    #expect(runtime.screenLines().contains(where: { $0.contains("FINAL") }))
    let finished = await withCheckedContinuation { continuation in
      runtime.inspect {
        ($0.isControlMode, $0.controlModeData.count)
      } completion: {
        continuation.resume(returning: $0)
      }
    }
    #expect(!finished.0)
    #expect(finished.1 == 0)
    await client.close()
  }
}
