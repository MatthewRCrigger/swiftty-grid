import CompanionModel
import Foundation

/// One validated watch application context, applied as a single update.
/// A cleared companion context cannot carry attention or preview text.
public struct WatchApplicationContext: Equatable, Sendable {
  public let companion: CompanionApplicationContext
  public let attention: AttentionSummaryBatch?

  public enum DecodeError: Error, Equatable { case malformed }

  /// Validates the entire dictionary before exposing either component.
  /// Each codec enforces its own payload, text and collection limits.
  public init(dictionary: [String: Any]) throws(DecodeError) {
    var values = dictionary
    let rawAttention = values.removeValue(
      forKey: AttentionSummaryBatch.dictionaryKey
    )
    guard let companion = try? CompanionApplicationContext(dictionary: values)
    else { throw .malformed }
    let attention: AttentionSummaryBatch?
    if let rawAttention {
      guard case .status = companion, let data = rawAttention as? Data,
        let batch = try? AttentionSummaryBatch.decode(data)
      else { throw .malformed }
      attention = batch
    } else {
      attention = nil
    }
    self.companion = companion
    self.attention = attention
  }
}
