import Foundation
import SwiftMuxProtocol

/// The inner `swmux-256color` entry: the tested engine/input profile.
/// It extends xterm-256color with truecolor and cursor-style capabilities
/// the engine implements, and removes mouse reporting, which panes do not
/// receive in this profile.
public enum InnerTerminfo {
  public static let source = """
    \(SMX.innerTerm)|SwiftMux pane (Swiftty engine),
    \tTc, RGB,
    \tSs=\\E[%p1%d q, Se=\\E[2 q,
    \tkmous@, XM@, xm@,
    \tuse=xterm-256color,

    """

  /// Compiles the entry into `directory` with `tic`. Returns false when
  /// unavailable; the service then falls back to xterm-256color.
  public static func install(into directory: URL) -> Bool {
    let fm = FileManager.default
    do {
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appending(path: "\(SMX.innerTerm).terminfo")
      try source.write(to: file, atomically: true, encoding: .utf8)
      let tic = Process()
      tic.executableURL = URL(fileURLWithPath: "/usr/bin/tic")
      tic.arguments = ["-x", "-o", directory.path, file.path]
      tic.standardOutput = FileHandle.nullDevice
      tic.standardError = FileHandle.nullDevice
      try tic.run()
      tic.waitUntilExit()
      guard tic.terminationStatus == 0 else { return false }
      // Verify the compiled entry resolves from this directory.
      let check = Process()
      check.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
      check.arguments = ["-A", directory.path, SMX.innerTerm]
      check.standardOutput = FileHandle.nullDevice
      check.standardError = FileHandle.nullDevice
      try check.run()
      check.waitUntilExit()
      return check.terminationStatus == 0
    } catch { return false }
  }

  public static var defaultDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appending(
      path: "Library/Application Support/SwiftMux/terminfo"
    )
  }
}
