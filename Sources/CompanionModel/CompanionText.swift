import Foundation

/// Text hygiene for every string that crosses the companion boundary.
///
/// Terminal output is untrusted presentation content. Before it can be
/// shown on the watch, control characters (C0, DEL, C1), line/paragraph
/// separators and bidirectional overrides are removed; a tab becomes one
/// space. The result is display-only text with no escape semantics.
public enum CompanionText {
  /// Returns `text` with control and bidi-formatting scalars removed.
  public static func stripControls(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      if scalar == "\t" {
        scalars.append(" ")
      } else if !isDisallowed(scalar) {
        scalars.append(scalar)
      }
    }
    return String(scalars)
  }

  /// Whether `scalar` is stripped by `stripControls`.
  public static func isDisallowed(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x00...0x1F, 0x7F...0x9F: true
    // Line/paragraph separators would break line bounds.
    case 0x2028, 0x2029: true
    // Bidirectional embedding, override and isolate controls.
    case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
    // Byte-order mark / zero-width no-break space.
    case 0xFEFF: true
    default: false
    }
  }

  /// Strips controls, then truncates to `characters` grapheme clusters
  /// and `bytes` UTF-8 bytes without splitting a grapheme.
  public static func bounded(
    _ text: String,
    characters: Int,
    bytes: Int
  ) -> String {
    var out = ""
    var count = 0
    var used = 0
    for character in stripControls(text) {
      let size = character.utf8.count
      guard count < characters, used + size <= bytes else { break }
      out.append(character)
      count += 1
      used += size
    }
    return out
  }

  /// Whether `text` is already clean and within both bounds.
  static func isValid(_ text: String, characters: Int, bytes: Int) -> Bool {
    text.utf8.count <= bytes && text.count <= characters
      && !text.unicodeScalars.contains(where: isDisallowed)
  }
}
