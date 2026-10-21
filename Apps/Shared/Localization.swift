import Foundation

extension LocalizedStringResource {
  /// `key` from this module's String Catalog. Literal titles passed to
  /// SwiftUI controls look in `Bundle.main`, which in a Swift package
  /// misses this module's strings; this resolves them in `#bundle`.
  static func localized(_ key: String.LocalizationValue) -> Self {
    Self(key, bundle: #bundle)
  }
}
