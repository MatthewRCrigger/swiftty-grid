#if os(macOS)
import Darwin
import Foundation
import ScreenProtocol

/// `swifttyd serve` configuration (spec §4). The bind address and the
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

/// The per-user launchd agent definition (never a root daemon).
public struct LaunchAgent: Sendable, Hashable {
  public static let defaultLabel = "dev.swiftty.swifttyd"

  public var label: String
  public var executable: String
  public var configurationPath: String?

  public init(
    label: String = Self.defaultLabel,
    executable: String,
    configurationPath: String? = nil
  ) {
    self.label = label
    self.executable = executable
    self.configurationPath = configurationPath
  }

  public static var agentsDirectory: URL {
    URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Library/LaunchAgents")
  }

  public var plistURL: URL {
    Self.agentsDirectory.appendingPathComponent("\(label).plist")
  }

  /// `gui/<uid>/<label>` for `launchctl print`/`bootout`.
  public func serviceTarget(uid: uid_t = getuid()) -> String {
    "gui/\(uid)/\(label)"
  }

  public var programArguments: [String] {
    var arguments = [executable, "serve"]
    if let configurationPath {
      arguments += ["--config", configurationPath]
    }
    return arguments
  }

  /// The `--config` path recorded in an installed agent property list.
  public static func configurationPath(inPropertyList data: Data) -> String? {
    guard
      let plist = try? PropertyListSerialization.propertyList(
        from: data,
        format: nil
      ) as? [String: Any],
      let arguments = plist["ProgramArguments"] as? [String],
      let flag = arguments.firstIndex(of: "--config"),
      flag + 1 < arguments.count
    else { return nil }
    return arguments[flag + 1]
  }

  /// The configuration `bootstrap --stdio` must use: the one the installed
  /// agent serves with, so both agree on the control socket. Falls back to
  /// the default configuration location.
  public static func resolvedConfigurationURL(
    label: String = Self.defaultLabel
  ) -> URL {
    let agent = LaunchAgent(label: label, executable: "")
    if let data = try? Data(contentsOf: agent.plistURL),
      let path = configurationPath(inPropertyList: data)
    {
      return URL(fileURLWithPath: path)
    }
    return HostConfiguration.defaultConfigurationURL
  }

  /// XML property list contents.
  public func propertyList() throws -> Data {
    let plist: [String: Any] = [
      "Label": label,
      "ProgramArguments": programArguments,
      "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false],
      "ProcessType": "Interactive",
      "StandardErrorPath": "/dev/null",
      "StandardOutPath": "/dev/null",
    ]
    return try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
  }
}
#endif
