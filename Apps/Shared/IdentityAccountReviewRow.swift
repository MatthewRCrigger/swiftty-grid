import SSHIdentity
import SwiftUI

struct IdentityAccountReviewRow: View {
  let model: RoamingAppModel
  let identity: SSHIdentityMetadata
  @State
  private var working = false
  @State
  private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(identity.name).font(.headline)
      Text(identity.fingerprint).font(.caption.monospaced())
      Button(.localized("Restore in Current iCloud Account")) {
        working = true
        error = nil
        Task {
          defer { working = false }
          do throws(IdentityOperationError) {
            try await model.identityStore.restoreAccountReviewedIdentity(
              identity.id
            )
          } catch { self.error = error.message }
        }
      }
      .disabled(working)
      .accessibilityIdentifier("keys.restoreAccount.\(identity.id)")
      if let error { Text(error).foregroundStyle(.red) }
    }
  }
}
