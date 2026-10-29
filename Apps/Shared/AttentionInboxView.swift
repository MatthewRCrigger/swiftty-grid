import MuxNavigation
import ScreenProtocol
import SwiftMuxProtocol
import SwiftUI

/// The attention inbox across this device's configured Macs (spec.inbox.md
/// §3, §4). Program text is untrusted: shown verbatim as plain text,
/// never as markup or a link. Opening an item goes through the link
/// navigator, so the exact occurrence is checked and a held workspace
/// asks for explicit takeover.
struct AttentionInboxView: View {
  @Bindable
  var inbox: RoamingInboxModel
  let model: RoamingAppModel
  @Environment(AttentionRouter.self)
  private var router: AttentionRouter?

  var body: some View {
    List {
      if inbox.entries.isEmpty {
        Text(emptyText).foregroundStyle(.secondary)
          .listRowBackground(Color.clear)
      }
      section(.localized("Needs you"), inbox.needsYouEntries)
      section(.localized("Results"), inbox.resultEntries)
      hostProblems
    }
    .glassListBackground().navigationTitle(.localized("Inbox"))
    .inboxRefreshable(inbox)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button(.localized("Refresh"), systemImage: "arrow.clockwise") {
          inbox.refresh()
        }
      }
    }
    .task { if inbox.refreshedAt == nil { inbox.refresh() } }
  }

  private var emptyText: LocalizedStringResource {
    inbox.refreshedAt == nil
      ? .localized("Loading…") : .localized("Nothing needs you.")
  }

  @ViewBuilder
  private func section(
    _ title: LocalizedStringResource,
    _ entries: [RoamingInboxModel.Entry]
  ) -> some View {
    if !entries.isEmpty {
      Section(title) {
        ForEach(entries) { entry in
          AttentionInboxRow(entry: entry, inbox: inbox, router: router)
        }
      }
        .listRowBackground(Color.clear)
    }
  }

  @ViewBuilder
  private var hostProblems: some View {
    let failures = model.hosts.compactMap {
      host -> (id: UUID, name: String, reason: String)? in
      if case let .failed(reason) = inbox.hostStates[host.id] {
        return (host.id, host.nickname, reason)
      }
      return nil
    }
    if !failures.isEmpty {
      Section(.localized("Unavailable")) {
        ForEach(failures, id: \.id) { failure in
          Text(verbatim: "\(failure.name): \(failure.reason)").font(.caption)
        }
      }
      .listRowBackground(Color.clear)
    }
  }
}

/// One inbox entry. Its own view, so a row redraws only when its entry
/// changes rather than with every redraw of the list.
private struct AttentionInboxRow: View {
  let entry: RoamingInboxModel.Entry
  let inbox: RoamingInboxModel
  let router: AttentionRouter?

  var body: some View {
    let item = entry.item
    let snoozed = item.isSnoozed(at: .now)
    Button {
      router?.open(inbox.destination(for: entry))
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(label(item)).font(.headline)
          if !item.seen { Image(systemName: "circle.fill").font(.caption2) }
          Spacer()
          Text(item.updatedAt, style: .relative).font(.caption)
            .foregroundStyle(.secondary)
        }
        if let title = entry.title {
          Text(verbatim: title).lineLimit(2)
        }
        let names = Text(
          verbatim: [entry.host.name, entry.appName].compactMap { $0 }
            .joined(separator: " · ")
        )
        (snoozed ? Text("\(names) · snoozed", bundle: #bundle) : names)
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .contextMenu {
      Button(.localized("Snooze 1 Hour"), systemImage: "moon.zzz") {
        inbox.perform(
          .snooze(reference(item), until: .now.addingTimeInterval(3600)),
          on: entry
        )
      }
      if snoozed {
        Button(.localized("Unsnooze"), systemImage: "bell") {
          inbox.perform(.snooze(reference(item), until: nil), on: entry)
        }
      }
      if item.category != .needsYou {
        Button(.localized("Mark Reviewed"), systemImage: "checkmark") {
          inbox.perform(.markReviewed(reference(item)), on: entry)
        }
      }
    }
  }

  private func reference(_ item: AttentionItem) -> AttentionReference {
    AttentionReference(source: item.source, occurrence: item.occurrence)
  }

  private func label(_ item: AttentionItem) -> LocalizedStringResource {
    switch item.category {
    case .needsYou:
      switch item.status.kind {
      case .permission: .localized("Permission needed")
      case .auth: .localized("Sign-in needed")
      case .question, nil: .localized("Question")
      }
    case .failure: .localized("Failed")
    case .result: .localized("Finished")
    }
  }
}

nonisolated enum AttentionInboxText {
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
    )
    .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? nil : String(cleaned.prefix(200))
  }
}

extension View {
  @ViewBuilder
  fileprivate func inboxRefreshable(_ inbox: RoamingInboxModel) -> some View {
    #if os(tvOS)
    self
    #else
    refreshable { await inbox.refresh().value }
    #endif
  }
}
