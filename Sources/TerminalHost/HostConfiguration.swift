#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol

/// Roaming configuration of the SwiftMux service (spec §4). The bind address and the
/// endpoint advertised to clients are explicit; nothing changes firewall
/// policy.
public struct HostConfiguration: Sendable, Hashable, Codable {
  /// Project default, not an assigned service port.
  public static let defaultPort: UInt16 = 51222

  /// Local address the QUIC/UDP listener binds (e.g. `0.0.0.0`, a LAN or
  /// VPN address).
  public var bindAddress: String
  public var port: UInt16
  /// Host name or address placed in grants for clients to connect to.
  public var advertisedHost: String
  /// Owner-only state directory holding the control socket.
  public var stateDirectory: String?

  public init(
    bindAddress: String,
    port: UInt16 = Self.defaultPort,
    advertisedHost: String,
    stateDirectory: String? = nil
  ) {
    self.bindAddress = bindAddress
    self.port = port
    self.advertisedHost = advertisedHost
    self.stateDirectory = stateDirectory
  }

  enum CodingKeys: String, CodingKey {
    case bindAddress, port, advertisedHost, stateDirectory
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    bindAddress = try c.decode(String.self, forKey: .bindAddress)
    port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? Self.defaultPort
    advertisedHost = try c.decode(String.self, forKey: .advertisedHost)
    stateDirectory = try c.decodeIfPresent(String.self, forKey: .stateDirectory)
    guard !bindAddress.isEmpty, bindAddress.utf8.count <= 255,
      !advertisedHost.isEmpty, advertisedHost.utf8.count <= 255, port != 0
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .bindAddress,
        in: c,
        debugDescription: "bind address, advertised host and port required"
      )
    }
  }

  public var stateDirectoryURL: URL {
    stateDirectory.map { URL(fileURLWithPath: $0) } ?? ControlDirectory.defaultURL
  }

  public var socketPath: String {
    stateDirectoryURL.appendingPathComponent("control.sock").path
  }

  public static var defaultConfigurationURL: URL {
    ControlDirectory.defaultURL.appendingPathComponent("config.json")
  }

  public static func load(from url: URL) throws -> HostConfiguration {
    let data = try Data(contentsOf: url)
    guard data.count <= 64 * 1024 else {
      throw CocoaError(.fileReadTooLarge)
    }
    return try JSONDecoder().decode(HostConfiguration.self, from: data)
  }
}

extension HostConfiguration {
  /// Overrides the configuration location for both the service and the
  /// bootstrap helper (tests, side-by-side development installs).
  public static let environmentKey = "SWIFTMUX_ROAMING_CONFIG"

  /// The configuration both `swiftmux-agent` and `swifttyd bootstrap`
  /// use, so they agree on the control socket.
  public static func resolvedConfigurationURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let path = environment[environmentKey], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    return defaultConfigurationURL
  }
}
#endif
