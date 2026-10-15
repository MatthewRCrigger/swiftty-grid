import Foundation

/// The one Bonjour service a Mac registers while its Connect a Device
/// panel asks it to be discoverable (spec.connection-setup.md §3). The
/// record's port is the Mac's existing SSH port; Swiftty starts no
/// listener for it.
///
/// `_swiftty._tcp` is a product discovery identifier, not an assigned
/// port or a new SSH protocol.
public enum HostDiscovery {
  public static let serviceType = "_swiftty._tcp"
  /// Local discovery only: no wide-area registration or browsing.
  public static let domain = "local."

  /// TXT keys. The record carries only a descriptor version and product
  /// marker: never usernames, workspace names, titles, fingerprints,
  /// credentials or session tokens.
  public static let versionKey = "txtvers"
  public static let productKey = "product"
  public static let txtVersion = "1"
  public static let product = "swiftty"

  /// Accepted TXT data per candidate.
  public static let maxTXTBytes = 512
  /// Visible candidates while browsing.
  public static let maxCandidates = 256
  /// DNS-SD instance names are at most 63 bytes of UTF-8.
  public static let maxInstanceNameBytes = 63

  /// The TXT entries a Mac advertises.
  public static var advertisedTXT: [String: String] {
    [versionKey: txtVersion, productKey: product]
  }

  /// RFC 6763 TXT wire bytes for `entries`, key-sorted.
  public static func txtRecord(_ entries: [String: String]) -> [UInt8] {
    var bytes: [UInt8] = []
    for key in entries.keys.sorted() {
      let pair = Array("\(key)=\(entries[key] ?? "")".utf8)
      guard pair.count <= 255 else { continue }
      bytes.append(UInt8(pair.count))
      bytes += pair
    }
    return bytes
  }

  public enum TXTValidation: Hashable, Sendable {
    case accepted
    case tooLarge
    case unsupported
  }

  /// Whether a browsed record is a Swiftty Mac of a supported descriptor
  /// version. `byteCount` is the record's wire size.
  public static func validate(
    txt entries: [String: String],
    byteCount: Int
  ) -> TXTValidation {
    guard byteCount <= maxTXTBytes else { return .tooLarge }
    guard entries[productKey] == product, entries[versionKey] == txtVersion
    else { return .unsupported }
    return .accepted
  }

  /// Display text for an instance name: control, format and separator
  /// characters removed, whitespace collapsed, at most 63 UTF-8 bytes.
  /// Never used as a host name.
  public static func sanitizedName(_ raw: String) -> String {
    var scalars = String.UnicodeScalarView()
    var lastWasSpace = true
    for scalar in raw.unicodeScalars {
      let category = scalar.properties.generalCategory
      if scalar.properties.isWhitespace || category == .lineSeparator
        || category == .paragraphSeparator
      {
        if !lastWasSpace { scalars.append(" ") }
        lastWasSpace = true
        continue
      }
      switch category {
      case .control, .format, .surrogate, .privateUse, .unassigned: continue
      default: break
      }
      scalars.append(scalar)
      lastWasSpace = false
    }
    var text = String(scalars).trimmingCharacters(in: .whitespaces)
    while text.utf8.count > maxInstanceNameBytes { text.removeLast() }
    return text.trimmingCharacters(in: .whitespaces)
  }
}
