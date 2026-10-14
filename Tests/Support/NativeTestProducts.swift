#if os(macOS)
import Foundation

/// Resolves native test tools from the active test bundle, including builds
/// using a custom scratch directory. An explicit override takes precedence.
public enum NativeTestProducts {
  public enum Failure: Error, Equatable { case launcherUnavailable(String) }

  public static func launcherPath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleURL: URL? = nil
  ) throws -> String {
    let path: String
    if let override = environment["SWMUX_LAUNCHER"] {
      path = override
    } else {
      let bundle = bundleURL ?? Bundle(for: NativeTestBundle.self).bundleURL
      path =
        bundle.deletingLastPathComponent()
        .appendingPathComponent("swmux-launcher").path
    }
    var directory: ObjCBool = false
    guard !path.isEmpty,
      FileManager.default.fileExists(atPath: path, isDirectory: &directory),
      !directory.boolValue, FileManager.default.isExecutableFile(atPath: path)
    else { throw Failure.launcherUnavailable(path) }
    return path
  }
}

/// Its image identifies the loaded test bundle even when the process runs
/// inside a temporary AppKit host rather than the products directory.
private final class NativeTestBundle: NSObject {}
#endif
