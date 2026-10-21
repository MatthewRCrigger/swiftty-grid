import CompanionModel
import SwiftUI

/// Read-only status view. Every value is labelled with the time the
/// iPhone observed it and an explicit fresh/stale/unavailable badge.
/// There are no input controls: the only actions ask the iPhone for its
/// latest cached state.
struct WatchStatusView: View {
  let model: WatchCompanionModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 10)) { context in
      let p = model.presentation(now: context.date)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          header(p)
          observed(p, now: context.date)
          if p.pendingInputCount > 0 {
            Label("\(p.pendingInputCount) input pending", systemImage: "hourglass")
              .font(.footnote)
              .foregroundStyle(.orange)
          }
          actions(p)
          WatchAttentionSection(summaries: model.attention, now: context.date)
          if let preview = p.preview {
            previewSection(preview, now: context.date)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
      }
      .onChange(of: context.date) { _, now in model.tick(now: now) }
    }
  }

  private func header(_ p: WatchCompanionStore.Presentation) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      (p.nickname.map { Text($0) } ?? Text("Session"))
        .font(.headline)
        .lineLimit(1)
      (p.state.map { Text($0.summary) } ?? Text("No status from iPhone"))
        .font(.subheadline)
        .foregroundStyle(p.freshness == .fresh ? .primary : .secondary)
    }
  }

  private func observed(_ p: WatchCompanionStore.Presentation, now: Date) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      FreshnessBadge(freshness: p.freshness)
      if let capturedAt = p.capturedAt {
        Text("Seen by iPhone \(capturedAt, format: .relative(presentation: .named))")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if !p.phoneReachable {
        Label("iPhone not reachable", systemImage: "iphone.slash")
          .font(.footnote)
          .foregroundStyle(.secondary)
      } else if p.lastRefreshFailed {
        Label("Last refresh failed", systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func actions(_ p: WatchCompanionStore.Presentation) -> some View {
    VStack {
      Button {
        model.refresh(.refresh)
      } label: {
        Label(p.refreshing ? "Asking iPhone…" : "Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(p.refreshing || !p.phoneReachable)
      if p.previewAvailable {
        Button {
          model.refresh(.preview)
        } label: {
          Label("Show Preview", systemImage: "text.alignleft")
        }
        .disabled(p.refreshing || !p.phoneReachable)
      }
    }
    .buttonStyle(.glass)
  }

  private func previewSection(_ preview: CompanionPreview, now: Date) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Preview \(preview.capturedAt, format: .relative(presentation: .named))")
        .font(.caption2)
        .foregroundStyle(.secondary)
      ForEach(preview.lines.enumerated(), id: \.offset) { _, line in
        Text(verbatim: line)
          .font(.caption2.monospaced())
          .lineLimit(1)
      }
    }
    // Redacted whenever the system shows a privacy-reduced rendition.
    .privacySensitive()
  }
}

struct FreshnessBadge: View {
  let freshness: CompanionFreshness

  var body: some View {
    let (text, color): (LocalizedStringResource, Color) =
      switch freshness {
      case .fresh: ("Recent", .green)
      case .stale: ("Stale", .orange)
      case .unavailable: ("Unavailable", .gray)
      }
    Text(text)
      .font(.caption2.bold())
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .glassEffect(.regular.tint(color.opacity(0.25)), in: .capsule)
  }
}
