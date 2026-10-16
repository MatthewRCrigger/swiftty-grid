import Foundation

/// File-backed JSON storage for saved hosts. Holds no secrets, so plain
/// JSON in app storage is acceptable; it is still written atomically with
/// complete file protection where the platform provides it.
public struct HostProfileStore: Sendable {
  public enum StoreError: Error, Hashable, Sendable {
    case tooLarge
    case unsupportedVersion(Int)
    case malformed
    case tooManyHosts
    case invalidHost(UUID)
    case duplicateHost(UUID)
    case io(String)
  }

  public static let version = 1
  public static let maxHosts = 256
  public static let maxFileBytes = 1 << 20

  struct File: Codable {
    var version: Int
    var hosts: [HostProfile]
  }

  public let fileURL: URL

  public init(fileURL: URL) { self.fileURL = fileURL }

  /// `Application Support/Swiftty/hosts.json`. tvOS offers no durable
  /// local storage to apps, so there the list lives in Caches and may be
  /// purged by the system (spec §2.3: no durable local file workflow).
  public static func defaultURL() -> URL {
    RoamingStorage.directory.appending(path: "hosts.json", directoryHint: .notDirectory)
  }

  /// Loads saved hosts; a missing file is an empty list.
  public func load() throws(StoreError) -> [HostProfile] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return []
    }
    let size: Int
    let data: Data
    do {
      size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= Self.maxFileBytes else { throw StoreError.tooLarge }
      data = try Data(contentsOf: fileURL)
    } catch let error as StoreError { throw error } catch {
      throw .io(String(describing: type(of: error)))
    }
    return try Self.decode(data)
  }

  /// Atomically replaces the saved hosts.
  public func save(_ hosts: [HostProfile]) throws(StoreError) {
    let data = try Self.encode(hosts)
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      #if os(iOS) || os(visionOS)
      try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
      #else
      try data.write(to: fileURL, options: [.atomic])
      #endif
    } catch { throw .io(String(describing: type(of: error))) }
  }

  static func encode(_ hosts: [HostProfile]) throws(StoreError) -> Data {
    guard hosts.count <= maxHosts else { throw .tooManyHosts }
    for host in hosts where !host.isValid { throw .invalidHost(host.id) }
    var identities: Set<UUID> = []
    for host in hosts where !identities.insert(host.id).inserted {
      throw .duplicateHost(host.id)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(File(version: version, hosts: hosts))
    else { throw .malformed }
    guard data.count <= maxFileBytes else { throw .tooLarge }
    return data
  }

  static func decode(_ data: Data) throws(StoreError) -> [HostProfile] {
    guard data.count <= maxFileBytes else { throw .tooLarge }
    guard let file = try? JSONDecoder().decode(File.self, from: data) else {
      throw .malformed
    }
    guard file.version == version else {
      throw .unsupportedVersion(file.version)
    }
    guard file.hosts.count <= maxHosts else { throw .tooManyHosts }
    // Invalid entries and duplicate identities in hand-edited files
    // are skipped. Keep the first valid entry for each saved host.
    var identities: Set<UUID> = []
    return file.hosts.filter { $0.isValid && identities.insert($0.id).inserted }
  }
}
