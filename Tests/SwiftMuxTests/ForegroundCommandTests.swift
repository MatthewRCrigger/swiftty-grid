import Darwin
import Foundation
import Testing

@testable import SwiftMuxService

@Suite struct ForegroundCommandTests {
  @Test func `names the foreground program of a pty`() throws {
    var master: Int32 = -1
    let shell = forkpty(&master, nil, nil, nil)
    if shell == 0 {
      // Child: a job-control shell that runs `sleep` in the foreground.
      let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup("zsh"), strdup("-f"), strdup("-i"), strdup("-c"),
        strdup("sleep 3; true"), nil,
      ]
      execv("/bin/zsh", argv)
      _exit(127)
    }
    try #require(shell > 0)
    defer {
      kill(shell, SIGKILL)
      close(master)
    }
    var seen: String?
    for _ in 0 ..< 40 {
      usleep(50_000)
      if let name = ForegroundCommand.name(master: master, shell: shell) {
        seen = name
        break
      }
    }
    #expect(seen == "sleep")
  }

  /// A symlinked, versioned binary reports the name it was started as.
  @Test func `uses the typed name for a versioned binary`() throws {
    let dir = NSTemporaryDirectory() + "fg-\(getpid())"
    try FileManager.default.createDirectory(
      atPath: dir,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: dir + "/9.9.9")
    // A copied system binary loses its signature and would be killed.
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "-s", "-", dir + "/9.9.9"]
    try sign.run()
    sign.waitUntilExit()
    var master: Int32 = -1
    let shell = forkpty(&master, nil, nil, nil)
    if shell == 0 {
      let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup("zsh"), strdup("-f"), strdup("-i"), strdup("-c"),
        strdup("(exec -a mytool \(dir)/9.9.9 3); true"), nil,
      ]
      execv("/bin/zsh", argv)
      _exit(127)
    }
    try #require(shell > 0)
    defer {
      kill(shell, SIGKILL)
      close(master)
    }
    var seen: String?
    for _ in 0 ..< 40 {
      usleep(50_000)
      if let name = ForegroundCommand.name(master: master, shell: shell) {
        seen = name
        break
      }
    }
    #expect(seen == "mytool", "saw \(String(describing: seen))")
  }
}
