import SwiftUI

struct LegacyKeyDeletionRow: View {
  let model: RoamingAppModel
  let intent: IdentityIntent
  let prepared: (LegacyKeyDeletionReview) -> Void
  @State
  private var working = false
  @State
  private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(intent.name).font(.headline)
      Button(.localized("Review Removal…")) {
        working = true
        error = nil
        Task {
          defer { working = false }
          do throws(IdentityOperationError) {
            prepared(
              try await model.identityStore.prepareLegacyDeletion(intent.id)
            )
          } catch { self.error = error.message }
        }
      }
      .disabled(working)
      .accessibilityIdentifier("keys.reviewRemoval.\(intent.id)")
      if let error { Text(error).foregroundStyle(.red) }
    }
  }
}

/// Owned by the keys list, so persisting the decision can remove its row
/// without dismissing a pending-removal result.
struct LegacyKeyDeletionView: View {
  let model: RoamingAppModel
  let review: LegacyKeyDeletionReview
  @Environment(\.dismiss)
  private var dismiss
  @State
  private var working = false
  @State
  private var authorized = false
  @State
  private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(review.name).font(.headline)
          Text(review.fingerprint).font(.caption.monospaced())
            .accessibilityIdentifier("keys.removalFingerprint")
        }
        Section {
          Text(
            "This key matches the saved fingerprint. Removal applies to the currently signed-in iCloud account and may propagate to your other devices through iCloud Keychain. It does not remove the public key from any server's authorized_keys.",
            bundle: #bundle
          )
          if authorized {
            Text(
              "Removal is saved and will be retried. The key has not been confirmed removed.",
              bundle: #bundle
            )
            .accessibilityIdentifier("keys.removalPending")
          } else {
            Button(
              .localized("Remove from Current iCloud Account"),
              role: .destructive
            ) {
              working = true
              error = nil
              Task {
                defer { working = false }
                do throws(IdentityOperationError) {
                  if try await model.identityStore.confirmLegacyDeletion(review)
                  {
                    dismiss()
                  } else {
                    authorized = true
                  }
                } catch { self.error = error.message }
              }
            }
            .disabled(working).accessibilityIdentifier("keys.confirmRemoval")
          }
          if let error { Text(error).foregroundStyle(.red) }
        }
      }
      .formStyle(.grouped).navigationTitle(.localized("Review Key Removal"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(authorized ? .localized("Close") : .localized("Cancel")) {
            dismiss()
          }
          .disabled(working)
        }
      }
      .interactiveDismissDisabled(working)
    }
  }
}
