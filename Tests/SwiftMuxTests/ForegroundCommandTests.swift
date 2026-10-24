import Darwin
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
}
