import Foundation

/// Where a pane's shell says it is (OSC 7), for the status bar and the
/// pane header's remote mark.
struct GridLocation: Equatable {
  var directory: String?
  /// Host named by the shell; empty or nil for this machine.
  var host: String?

  /// Whether the host names another machine.
  var isRemote: Bool {
    guard let host, !host.isEmpty else { return false }
    return !Self.isLocal(host)
  }

  static func isLocal(_ host: String) -> Bool {
    func first(_ name: String) -> String {
      name.lowercased().split(separator: ".").first.map(String.init) ?? ""
    }
    let h = first(host)
    return h == "localhost" || h == first(ProcessInfo.processInfo.hostName)
      || h == first(Host.current().name ?? "")
  }

  /// The directory with the home directory abbreviated; never a sentence.
  var displayPath: String {
    guard let directory, !directory.isEmpty else { return "" }
    if !isRemote {
      let home = NSHomeDirectory()
      if directory == home { return "~" }
      if directory.hasPrefix(home + "/") {
        return "~" + directory.dropFirst(home.count)
      }
    }
    return directory
  }

  /// The checked-out branch of a local directory, read from `.git/HEAD`.
  var branch: String? {
    guard !isRemote, var url = directory.map({ URL(fileURLWithPath: $0) })
    else { return nil }
    for _ in 0 ..< 24 {
      let head = url.appendingPathComponent(".git/HEAD")
      if let text = try? String(contentsOf: head, encoding: .utf8) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        return String(line.prefix(7))
      }
      let parent = url.deletingLastPathComponent()
      if parent == url { break }
      url = parent
    }
    return nil
  }
}
