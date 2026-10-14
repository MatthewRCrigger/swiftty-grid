import CompanionModel
import Foundation
import Synchronization

/// Serializes phone snapshots, attention and transport submission. A revision
/// is saved before its dictionary or reply can leave this owner.
public final class PhoneWatchPublication: Sendable {
  private struct State: Sendable {
    var bridge: PhoneCompanionBridge
    var attention: Data?
  }

  private let state: Mutex<State>
  private let saveIdentity: @Sendable (CompanionPublicationIdentity) -> Bool

  public init(
    bridge: PhoneCompanionBridge,
    saveIdentity: @escaping @Sendable (CompanionPublicationIdentity) -> Bool
  ) {
    state = Mutex(State(bridge: bridge))
    self.saveIdentity = saveIdentity
  }

  public func withBridge<R: Sendable>(
    _ body: (inout PhoneCompanionBridge) -> R
  ) -> R {
    state.withLock {
      let result = body(&$0.bridge)
      if !$0.bridge.settings.sharingEnabled { $0.attention = nil }
      return result
    }
  }

  @discardableResult
  public func setAttention(_ summaries: [AttentionSummary]) -> Bool {
    guard
      let encoded = try? AttentionSummaryBatch(summaries: summaries).encoded()
    else { return false }
    return state.withLock {
      guard $0.bridge.settings.sharingEnabled else {
        $0.attention = nil
        return false
      }
      $0.attention = encoded
      return true
    }
  }

  /// The synchronous submit callback runs inside the same lock as mutations.
  /// It must not call back into this owner. No captured pre-lock snapshot is
  /// submitted after a newer opt-out or attention update.
  @discardableResult
  public func publish(_ submit: ([String: Data]) -> Bool) -> Bool {
    state.withLock {
      guard $0.bridge.advancePublication(),
        saveIdentity($0.bridge.publicationIdentity),
        var dictionary = try? $0.bridge.applicationContext.dictionary()
      else { return false }
      if $0.bridge.settings.sharingEnabled, let attention = $0.attention {
        dictionary[AttentionSummaryBatch.dictionaryKey] = attention
      }
      return submit(dictionary)
    }
  }

  /// Replies are immediate cached-state values, under the same publication
  /// sequence as contexts. Later delivery is fenced by the watch watermark.
  public func reply(toMessageData data: Data) -> Data? {
    guard (try? CompanionCodec.decodeRequest(data)) != nil else { return nil }
    return state.withLock {
      guard $0.bridge.advancePublication(),
        saveIdentity($0.bridge.publicationIdentity)
      else { return nil }
      return $0.bridge.reply(toMessageData: data)
    }
  }
}

/// Only publisher identity and sequence are durable; no companion content
/// is persisted. A legacy decimal counter receives a new publisher identity
/// and is upgraded atomically before its first transmission.
public struct CompanionPublicationSequenceFile: Sendable {
  public let url: URL

  public init(url: URL) { self.url = url }

  public func load() throws -> CompanionPublicationIdentity {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return .init()
    }
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var data = Data()
    while data.count < 60 {
      guard let part = try file.read(upToCount: 60 - data.count), !part.isEmpty
      else { break }
      data.append(part)
    }
    guard data.count < 60, let text = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
    if parts.count == 1, let revision = Self.revision(parts[0]) {
      return .init(revision: revision)
    }
    guard parts.count == 3, parts[0] == "1", parts[1].utf8.count == 36,
      let publisher = UUID(uuidString: String(parts[1])),
      let revision = Self.revision(parts[2])
    else { throw CocoaError(.fileReadCorruptFile) }
    return .init(publisherID: publisher, revision: revision)
  }

  private static func revision(_ text: Substring) -> UInt64? {
    guard !text.isEmpty, text.utf8.count <= 20,
      text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
    else { return nil }
    return UInt64(text)
  }

  public func save(_ identity: CompanionPublicationIdentity) throws {
    var directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    let value = "1\n\(identity.publisherID.uuidString)\n\(identity.revision)"
    try Data(value.utf8).write(to: url, options: .atomic)
  }
}
