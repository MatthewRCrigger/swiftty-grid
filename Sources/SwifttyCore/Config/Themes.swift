import Foundation

/// Theme files: Ghostty's format, a configuration file containing only
/// color keys. Looked up by name in the theme directories, then among the
/// built-ins; a name with a `/` is a path.
public enum Themes {
  /// Maximum UTF-8 bytes read from one theme file.
  public static let maxFileBytes = 64 * 1024
  /// Built-in themes, as theme-file text.
  public static let builtIn: [String: String] = [
    "Swiftty Dark": """
    background = #282c34
    foreground = #ffffff
    cursor-color = #ffffff
    """,
    "GRID": """
    background = #000000
    foreground = #e4f2f8
    cursor-color = #f4be4f
    cursor-text = #000000
    selection-background = #4d3f18
    selection-foreground = #e4f2f8
    palette = 0=#0c1013
    palette = 1=#ff655a
    palette = 2=#74e29f
    palette = 3=#f4be4f
    palette = 4=#2286a7
    palette = 5=#d5b2ff
    palette = 6=#44daff
    palette = 7=#a8bcc6
    palette = 8=#4a5a63
    palette = 9=#ff655a
    palette = 10=#74e29f
    palette = 11=#f4be4f
    palette = 12=#44daff
    palette = 13=#d5b2ff
    palette = 14=#44daff
    palette = 15=#e4f2f8
    """,
    "Swiftty Light": """
    background = #fafafa
    foreground = #383a42
    cursor-color = #383a42
    selection-background = #c8d6f0
    palette = 0=#383a42
    palette = 1=#e45649
    palette = 2=#50a14f
    palette = 3=#c18401
    palette = 4=#4078f2
    palette = 5=#a626a4
    palette = 6=#0184bc
    palette = 7=#a0a1a7
    palette = 8=#696c77
    palette = 9=#e45649
    palette = 10=#50a14f
    palette = 11=#c18401
    palette = 12=#4078f2
    palette = 13=#a626a4
    palette = 14=#0184bc
    palette = 15=#fafafa
    """,
  ]

  public static func colors(
    named name: String,
    searching directories: [URL]
  ) -> ColorSet? {
    guard let text = text(named: name, searching: directories) else {
      return nil
    }
    return parse(text)
  }

  static func text(named name: String, searching directories: [URL]) -> String?
  {
    guard !name.unicodeScalars.contains("\0") else { return nil }
    if name.unicodeScalars.contains("/") {
      return try? ConfigurationFile.read(
        URL(fileURLWithPath: (name as NSString).expandingTildeInPath),
        maxBytes: maxFileBytes
      )
    }
    for directory in directories {
      if let text = try? ConfigurationFile.read(
        directory.appendingPathComponent(name),
        maxBytes: maxFileBytes
      ) {
        return text
      }
    }
    return builtIn[name]
  }

  /// The color keys of a theme file; anything else is ignored.
  public static func parse(_ text: String) -> ColorSet {
    var colors = ColorSet()
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      let scalars = line.unicodeScalars
      guard scalars.first != "#", let eq = scalars.firstIndex(of: "=") else {
        continue
      }
      let key = String(scalars[..<eq]).trimmingCharacters(in: .whitespaces)
      let value = String(scalars[scalars.index(after: eq)...])
        .trimmingCharacters(in: .whitespaces)
      _ = colors.set(key, Configuration.unquote(value))
    }
    return colors
  }
}
