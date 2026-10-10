import MuxNavigation
import ScreenProtocol
import SwiftMuxProtocol
import SwiftUI

/// The attention inbox across this device's configured Macs (unified
/// spec §8, §9). Program text is untrusted: shown verbatim as plain text,
/// never as markup or a link. Opening an item goes through the link
/// navigator, so the exact occurrence is checked and a held workspace
/// asks for explicit takeover.
struct AttentionInboxView: View {
  @Bindable var inbox: RoamingInboxModel
  let model: RoamingAppModel
  @Environment(\.openAttention) private var openAttention

  var body: some View {
    List {
      if inbox.entries.isEmpty {
        Text(emptyText).foregroundStyle(.secondary)
      }
      section("Needs you", inbox.entries.filter { $0.item.category != .result })
      section("Results", inbox.entries.filter { $0.item.category == .result })
      hostProblems
    }
    .navigationTitle("Inbox")
    #if !os(tvOS)
      .refreshable { inbox.refresh() }
    #endif
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button("Refresh", systemImage: "arrow.clockwise") { inbox.refresh() }
      }
    }
    .task { if inbox.refreshedAt == nil { inbox.refresh() } }
  }

  private var emptyText: String {
    inbox.refreshedAt == nil ? "Loading…" : "Nothing needs you."
  }

  @ViewBuilder
  private func section(_ title: String, _ entries: [RoamingInboxModel.Entry]) -> some View {
    if !entries.isEmpty {
      Section(title) {
        ForEach(entries) { entry in row(entry) }
      }
    }
  }

  private func row(_ entry: RoamingInboxModel.Entry) -> some View {
    let item = entry.item
    let snoozed = item.isSnoozed(at: .now)
    return Button {
      openAttention(inbox.destination(for: entry))
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(label(item)).font(.headline)
          if !item.seen { Image(systemName: "circle.fill").font(.caption2) }
          Spacer()
          Text(item.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
        }
        if let title = Self.plain(item.status.title ?? item.status.message) {
          Text(verbatim: title).lineLimit(2)
        }
        Text(verbatim: [entry.host.name, Self.plain(item.status.app), snoozed ? "snoozed" : nil]
          .compactMap { $0 }.joined(separator: " · "))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .contextMenu {
      Button("Snooze 1 Hour", systemImage: "moon.zzz") {
        inbox.perform(
          .snooze(reference(item), until: .now.addingTimeInterval(3600)),
          on: entry
        )
      }
      if snoozed {
        Button("Unsnooze", systemImage: "bell") {
          inbox.perform(.snooze(reference(item), until: nil), on: entry)
        }
      }
      if item.category != .needsYou {
        Button("Mark Reviewed", systemImage: "checkmark") {
          inbox.perform(.markReviewed(reference(item)), on: entry)
        }
      }
    }
  }

  @ViewBuilder
  private var hostProblems: some View {
    let failures = model.hosts.compactMap { host -> (String, String)? in
      if case let .failed(reason) = inbox.hostStates[host.id] {
        return (host.nickname, reason)
      }
      return nil
    }
    if !failures.isEmpty {
      Section("Unavailable") {
        ForEach(failures, id: \.0) { name, reason in
          Text(verbatim: "\(name): \(reason)").font(.caption)
        }
      }
    }
  }

  private func reference(_ item: AttentionItem) -> AttentionReference {
    AttentionReference(source: item.source, occurrence: item.occurrence)
  }

  private func label(_ item: AttentionItem) -> String {
    switch item.category {
    case .needsYou:
      switch item.status.kind {
      case .permission: "Permission needed"
      case .auth: "Sign-in needed"
      case .question, nil: "Question"
      }
    case .failure: "Failed"
    case .result: "Finished"
    }
  }

  /// Untrusted program text as one plain line.
  static func plain(_ text: String?) -> String? {
    guard let text else { return nil }
    let cleaned = String(
      String.UnicodeScalarView(
        text.unicodeScalars.map {
          switch $0.properties.generalCategory {
          case .control, .format, .lineSeparator, .paragraphSeparator: " "
          default: $0
          }
        }
      )
    ).trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
  }
}
