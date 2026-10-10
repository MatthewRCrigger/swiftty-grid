import MuxNavigation
import SwiftUI

/// Redacted attention summaries (spec.inbox.md §4, scenario
/// 20): category, optional app name, counts and a relative time only.
/// The single action advertises a Handoff to a paired, authorized device;
/// the watch never opens panes, takes a writer lease or sends input.
struct WatchAttentionSection: View {
  let summaries: [AttentionSummary]
  let now: Date
  @State private var handoff: AttentionHandoffRequest?

  var body: some View {
    if !summaries.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Attention").font(.caption.bold())
        ForEach(Array(summaries.enumerated()), id: \.offset) { _, summary in
          row(summary)
        }
        if handoff != nil {
          Label("Continue on your iPhone or Mac", systemImage: "iphone.and.arrow.forward")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      // Advertised only after the user asked; the receiving device
      // resolves the locator through its own configured hosts.
      .userActivity(AttentionHandoffRequest.activityType, isActive: handoff != nil) { activity in
        guard let handoff else { return }
        activity.title = "Open attention item"
        activity.userInfo = handoff.userInfo
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
      }
    }
  }

  private func row(_ summary: AttentionSummary) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(summary.categoryLabel).font(.footnote.bold())
        if let app = summary.appName {
          Text(verbatim: app).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Text(summary.relativeTime(now: now)).font(.caption2).foregroundStyle(.secondary)
      if let message = summary.message {
        Text(verbatim: message).font(.caption2).lineLimit(2).privacySensitive()
      }
      if let locator = summary.locator, let request = AttentionHandoffRequest(locator: locator) {
        Button {
          handoff = request
        } label: {
          Label("Open on iPhone", systemImage: "arrow.up.forward.app")
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}
