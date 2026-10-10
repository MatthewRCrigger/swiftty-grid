import Foundation

/// Watch companion bounds (spec.roaming.md §2.3, §12). These are product
/// bounds, not WatchConnectivity system limits.
///
/// The companion model is versioned independently of RST/1 and of every
/// direct-client protocol: it only ever describes what the iPhone has
/// already observed.
public enum CompanionLimits {
  /// The only companion wire version this build understands.
  public static let version = 1
  /// Maximum decoded companion payload (status, preview, or request).
  public static let maxPayloadBytes = 16 * 1024
  /// User-chosen session nickname, in characters (grapheme clusters).
  public static let maxNicknameCharacters = 64
  /// UTF-8 bytes per nickname, so wide graphemes cannot inflate it.
  public static let maxNicknameBytes = 256
  /// Optional preview: at most one, a handful of bounded lines.
  public static let maxPreviewLines = 24
  /// Characters (grapheme clusters) per preview line.
  public static let maxPreviewColumns = 80
  /// UTF-8 bytes per preview line.
  public static let maxPreviewLineBytes = 512
  /// UTF-8 bytes across all preview lines; leaves room for the envelope
  /// within `maxPayloadBytes`.
  public static let maxPreviewTextBytes = 8 * 1024
  /// Upper bound reported for pending input operations.
  public static let maxPendingInputCount = 1 << 20
  /// Request identifiers are short opaque tokens.
  public static let maxRequestIDBytes = 64
  /// A refresh with no reply is abandoned after this long so the watch
  /// can show an honest unreachable state and try again later.
  public static let refreshTimeout: TimeInterval = 15
}
