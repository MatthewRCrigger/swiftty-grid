#if !os(tvOS)
import Foundation
import SwiftUI

struct SFTPTransferRecoveryView: View {
  let model: SFTPBrowserModel
  @State
  private var reviewed: SavedTransfer?
  @Environment(\.dismiss)
  private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if let message = model.message {
          Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
        Text(
          "Review these files before assigning them to this host. Incomplete transfers will restart; old remote temporary files and existing destinations will be left alone.",
          bundle: #bundle
        )
        Text(
          "Destination: \(model.host.username)@\(model.host.host):\(model.host.port)",
          bundle: #bundle
        )
        ForEach(model.recoverableTransfers) { transfer in
          VStack(alignment: .leading, spacing: 6) {
            Label(
              (transfer.manifest.remotePath as NSString).lastPathComponent,
              systemImage: transfer.manifest.direction == .upload
                ? "arrow.up.doc" : "arrow.down.doc"
            )
            Text(transfer.manifest.remotePath).font(.caption)
              .selectableIfSupported()
            Button(.localized("Use for this host")) { reviewed = transfer }
              .accessibilityIdentifier("sftp.recover.\(transfer.id)")
          }
        }
        if model.recoverableTransfers.isEmpty {
          Text("No older transfers need review.", bundle: #bundle)
        }
      }
      .navigationTitle(Text("Review saved transfers", bundle: #bundle))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(.localized("Done")) { dismiss() }
        }
      }
      .confirmationDialog(
        Text(
          "Use this transfer with \(model.host.username)@\(model.host.host)?",
          bundle: #bundle
        ),
        isPresented: Binding(
          get: { reviewed != nil },
          set: { if !$0 { reviewed = nil } }
        ),
        titleVisibility: .visible
      ) {
        Button(.localized("Use for this host")) {
          if let transfer = reviewed { Task { await model.recover(transfer) } }
          reviewed = nil
        }
        .accessibilityIdentifier("sftp.confirmRecovery")
        Button(.localized("Cancel"), role: .cancel) { reviewed = nil }
          .accessibilityIdentifier("sftp.cancelRecovery")
      } message: {
        Text(
          "This assigns the saved file to the current host and account. Nothing is transferred until you choose Resume.",
          bundle: #bundle
        )
      }
    }
  }
}
#endif
