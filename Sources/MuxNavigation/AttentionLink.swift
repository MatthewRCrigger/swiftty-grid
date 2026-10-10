import Foundation

/// Which link forms this app accepts. Associated domains come from
/// configuration only; there is no built-in domain, and
/// `links.example.invalid` in the docs is a placeholder, not a deployed
/// endpoint.
public struct AttentionLinkConfiguration: Sendable, Equatable {
  /// Custom URL scheme for local activation.
  public static let scheme = "swiftty"
  /// Longest link accepted, in UTF-8 bytes.
  public static let maxURLBytes = 2048

  /// Lowercased hostnames for `https://<domain>/a/<locator>` Universal
  /// Links. Empty (the default) disables the Universal Link form.
  public var associatedDomains: Set<String>

  public init(associatedDomains: some Sequence<String> = []) {
    self.associatedDomains = Set(associatedDomains.map { $0.lowercased() })
  }

  /// Reads `SwifttyAssociatedDomains` (an array of hostnames) from an
  /// Info.plist dictionary. Missing or malformed values disable the
  /// Universal Link form.
  public init(infoDictionary: [String: Any]?) {
    let domains = infoDictionary?["SwifttyAssociatedDomains"] as? [String] ?? []
    self.init(associatedDomains: domains.filter(Self.isPlausibleDomain))
  }

  static func isPlausibleDomain(_ domain: String) -> Bool {
    !domain.isEmpty && domain.utf8.count <= 253
      && domain.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x61...0x7A).contains($0 | 0x20)
          || $0 == 0x2E || $0 == 0x2D
      }
  }
}

/// Parses and builds attention links (swiftty-unified-spec.md §9 step 1):
///
/// ```text
/// swiftty://attention/open?ref=<locator>
/// https://<configured associated domain>/a/<locator>
/// ```
///
/// Anything else is rejected: other schemes or domains, user info,
/// ports, fragments, extra or repeated query parameters, extra path
/// components, oversize links and malformed locators. A link never
/// supplies an endpoint to connect to.
public enum AttentionLink {
  public enum Rejection: Error, Sendable, Equatable {
    case tooLong
    case malformedURL
    case unsupportedScheme
    case unknownDomain
    case unexpectedComponent
    case unexpectedPath
    case unexpectedQuery
    case invalidLocator(AttentionLocator.DecodeError)
  }

  public enum Form: Sendable, Equatable {
    case customScheme
    case universal(domain: String)
  }

  public static func parse(
    _ url: URL,
    configuration: AttentionLinkConfiguration
  ) throws(Rejection) -> AttentionDestination {
    try parse(url.absoluteString, configuration: configuration)
  }

  public static func parse(
    _ text: String,
    configuration: AttentionLinkConfiguration
  ) throws(Rejection) -> AttentionDestination {
    guard text.utf8.count <= AttentionLinkConfiguration.maxURLBytes else {
      throw .tooLong
    }
    // Printable ASCII only: no whitespace, controls or IDN tricks.
    guard text.utf8.allSatisfy({ (0x21...0x7E).contains($0) }),
      let components = URLComponents(string: text),
      let scheme = components.scheme?.lowercased()
    else { throw .malformedURL }
    guard components.user == nil, components.password == nil,
      components.port == nil, components.fragment == nil
    else { throw .unexpectedComponent }
    let host = components.percentEncodedHost?.lowercased() ?? ""
    let locator: String
    switch scheme {
    case AttentionLinkConfiguration.scheme:
      guard host == "attention" else { throw .unexpectedPath }
      guard components.percentEncodedPath == "/open" else {
        throw .unexpectedPath
      }
      // Exactly one `ref`, no other parameters, nothing percent-encoded.
      guard let query = components.percentEncodedQuery,
        query.hasPrefix("ref="),
        !query.dropFirst(4).contains(where: { $0 == "&" || $0 == "=" })
      else { throw .unexpectedQuery }
      locator = String(query.dropFirst(4))
    case "https":
      guard !host.isEmpty, configuration.associatedDomains.contains(host) else {
        throw .unknownDomain
      }
      guard components.percentEncodedQuery == nil else {
        throw .unexpectedQuery
      }
      let path = components.percentEncodedPath
      guard path.hasPrefix("/a/") else { throw .unexpectedPath }
      let rest = path.dropFirst(3)
      guard !rest.contains("/") else { throw .unexpectedPath }
      locator = String(rest)
    default:
      throw .unsupportedScheme
    }
    do {
      return try AttentionLocator.decode(locator)
    } catch {
      throw .invalidLocator(error)
    }
  }

  /// `swiftty://attention/open?ref=<locator>`.
  public static func customURL(for destination: AttentionDestination) -> URL {
    let locator = AttentionLocator.encode(destination)
    // The locator alphabet needs no percent-encoding.
    return URL(string: "\(AttentionLinkConfiguration.scheme)://attention/open?ref=\(locator)")!
  }

  /// `https://<domain>/a/<locator>`, or nil when `domain` is not one of
  /// the configured associated domains.
  public static func universalLink(
    for destination: AttentionDestination,
    domain: String,
    configuration: AttentionLinkConfiguration
  ) -> URL? {
    let domain = domain.lowercased()
    guard configuration.associatedDomains.contains(domain) else { return nil }
    return URL(string: "https://\(domain)/a/\(AttentionLocator.encode(destination))")
  }
}
