import Darwin
import Foundation

/// Names the program in a pty's foreground process group, so a client can
/// theme a pane for as long as, say, `claude` runs in it.
enum ForegroundCommand {
  /// Interpreters whose script argument is the name users know the command by.
  private static let interpreters: Set<String> = [
    "node", "bun", "deno", "python", "python3", "ruby", "perl", "bash", "sh",
    "zsh",
  ]

  /// The command running in the foreground of `master`'s terminal, or nil
  /// while the shell (process `shell`) itself holds it.
  static func name(master: Int32, shell: pid_t) -> String? {
    let group = tcgetpgrp(master)
    guard group > 0, group != shell else { return nil }
    var buffer = [CChar](repeating: 0, count: 256)
    guard proc_name(group, &buffer, UInt32(buffer.count)) > 0 else {
      return nil
    }
    let name = String(cString: buffer)
    let args = arguments(of: group)
    if interpreters.contains(name) {
      let script = args.dropFirst().first(where: { !$0.hasPrefix("-") })
      return script.map { ($0 as NSString).lastPathComponent } ?? name
    }
    // `proc_name` is the resolved binary (a versioned file behind a
    // symlink, say), not the name the user typed.
    let typed = args.first.map { ($0 as NSString).lastPathComponent }
      .map { $0.hasPrefix("-") ? String($0.dropFirst()) : $0 }
    return typed.flatMap { $0.isEmpty ? nil : $0 } ?? name
  }

  /// The process's argv, empty when unreadable.
  private static func arguments(of pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var data = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &data, &size, nil, 0) == 0, size > 4 else {
      return []
    }
    var argc: Int32 = 0
    withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: data[0 ..< 4]) }
    var i = 4
    while i < size, data[i] != 0 { i += 1 }  // exec path
    while i < size, data[i] == 0 { i += 1 }  // padding
    var args: [String] = []
    while i < size, args.count < Int(argc) {
      var end = i
      while end < size, data[end] != 0 { end += 1 }
      args.append(String(decoding: data[i ..< end], as: UTF8.self))
      i = end + 1
    }
    return args
  }
}
