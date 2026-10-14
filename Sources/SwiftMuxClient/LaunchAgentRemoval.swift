import Darwin
import Foundation

/// Removes a development registration without mistaking probe errors for
/// absence.
public enum LaunchAgentRemoval {
  public enum Failure: Error, Equatable, CustomStringConvertible {
    case stillLoaded(bootoutStatus: Int32)
    case invalidPlistPath
    case cannotVerifyAbsence(status: Int32)

    public var description: String {
      switch self {
      case let .stillLoaded(status):
        "LaunchAgent remains loaded after bootout (status \(status))"
      case let .cannotVerifyAbsence(status):
        "cannot determine LaunchAgent registration (launchctl print status \(status))"
      case .invalidPlistPath:
        "plist must have a local file URL with a nonempty path and no NUL bytes"
      }
    }
  }

  /// launchctl's 113 means "Could not find specified service". Other nonzero
  /// probe statuses can describe permission/domain errors, not an absent agent.
  public static func remove(
    bootout: () throws -> Int32,
    probe: () throws -> Int32,
    removePlist: () throws -> Void,
  ) throws {
    let bootoutStatus = try bootout()
    let probeStatus = try probe()
    if try isLoaded(probeStatus: probeStatus) {
      throw Failure.stillLoaded(bootoutStatus: bootoutStatus)
    }
    do { try removePlist() } catch let error as NSError
      where error.domain == NSCocoaErrorDomain
      && error.code == NSFileNoSuchFileError
    {
      // FileManager reports this for an already absent plist; no preflight
      // exists-check, which would introduce a race and hide access failures.
    }
  }

  /// Only the documented absent-service code is a negative presence result.
  public static func isLoaded(probeStatus: Int32) throws -> Bool {
    switch probeStatus {
    case 0: true
    case 113: false
    default: throw Failure.cannotVerifyAbsence(status: probeStatus)
    }
  }

  /// unlink never recursively removes an unexpected directory and removes
  /// symlink entries without following their targets. Missing paths are done.
  public static func unlinkPlist(at url: URL) throws {
    let path = url.path
    let host = url.host?.lowercased() ?? ""
    guard url.isFileURL, host.isEmpty || host == "localhost", !path.isEmpty,
      !path.utf8.contains(0), !url.path(percentEncoded: true).contains("%00")
    else { throw Failure.invalidPlistPath }
    let (status, failure) = path.withCString { (Darwin.unlink($0), errno) }
    guard status != 0 else { return }
    guard failure != ENOENT else { return }
    throw NSError(
      domain: NSPOSIXErrorDomain,
      code: Int(failure),
      userInfo: [NSFilePathErrorKey: path],
    )
  }
}
