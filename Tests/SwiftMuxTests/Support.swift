import Foundation
import SwiftMuxClient
import SwiftMuxProtocol
import SwiftMuxService
import Testing

/// The launcher built alongside the tests (`swift build` builds it).
func launcherPath() throws -> String {
  if let path = ProcessInfo.processInfo.environment["SWMUX_LAUNCHER"] {
    return path
  }
  var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  while dir.path != "/" {
    for config in [
      "debug", "release", "out/Products/Debug", "out/Products/Release",
    ] {
      let candidate = dir.appending(path: ".build/\(config)/swmux-launcher")
        .path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    dir = dir.deletingLastPathComponent()
  }
  throw MuxError(.notFound, "swmux-launcher not built; run swift build first")
}

struct Harness {
  let service: MuxService
  let endpoint: SMXEndpoint

  init(limits: MuxLimits = .standard) throws {
    var config = MuxServiceConfiguration(launcherPath: try launcherPath())
    config.limits = limits
    service = MuxService(configuration: config)
    endpoint = service.listenAnonymously()
  }

  func connect(_ kind: FrontendKind = .native) async throws -> MuxConnection {
    try await MuxConnection.connect(
      endpoint: endpoint,
      frontend: kind,
      terminalProfile: kind == .terminal ? SMX.terminalProfile : nil
    )
  }
}

/// A shell with a predictable prompt and no user startup files.
func shellLaunch(_ extra: [String: String] = [:]) -> LaunchSpec {
  var env = [
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PS1": "$ ",
    "HOME": NSTemporaryDirectory(),
  ]
  for (k, v) in extra { env[k] = v }
  return LaunchSpec(
    command: ["/bin/sh"],
    workingDirectory: "/tmp",
    environment: env
  )
}

extension MuxConnection {
  /// Waits for a frame of `pane` satisfying `predicate`.
  func frame(
    of pane: PaneID,
    timeout: Duration = .seconds(10),
    where predicate: (PaneFrame) -> Bool
  ) async throws -> PaneFrame {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      let event = try await withTimeout(deadline - ContinuousClock.now) {
        try await self.nextEvent()
      }
      if case let .frame(f)? = event, f.identity.pane == pane, predicate(f) {
        return f
      }
    }
    throw MuxError(.notFound, "timed out waiting for frame")
  }

  /// Attach, size and subscribe the active tab's panes.
  @discardableResult
  func attachAndShow(
    _ selector: WorkspaceSelector,
    columns: Int = 80,
    rows: Int = 24,
    generation: UInt64 = 1
  ) async throws -> WorkspaceSnapshot {
    guard case let .attached(_, ws) = try await execute(.attach(selector))
    else { throw MuxError(.invalidRequest, "attach reply") }
    let panes = ws.activeTabSnapshot!.layout.panes
    try await execute(
      .setGeometry(
        GeometryBatch(
          layoutRevision: ws.layoutRevision,
          generation: generation,
          entries: panes.map { .init(pane: $0, columns: columns, rows: rows) }
        )
      )
    )
    try await execute(.setSubscriptions(panes))
    return ws
  }
}

struct TimeoutError: Error {}

func withTimeout<T: Sendable>(
  _ duration: Duration,
  _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(for: duration)
      throw TimeoutError()
    }
    let value = try await group.next()!
    group.cancelAll()
    return value
  }
}
