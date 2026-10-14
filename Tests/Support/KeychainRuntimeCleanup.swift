/// Cleanup of the explicitly named, test-owned labels in a Keychain fixture.
/// Errors are reported independently so one label cannot prevent the others
/// from being attempted. The work owns any child tasks until it returns.
public enum KeychainRuntimeCleanup {
  public static func withCleanup<T>(
    labels: [String],
    isolation: isolated (any Actor)? = #isolation,
    work: () async throws -> T,
    delete: (String) async throws -> Void,
    report: (String, any Error) -> Void
  ) async throws -> T {
    try await RuntimeFixture.withCleanup(
      isolation: isolation,
      work,
      cleanup: {
        for label in labels {
          do { try await delete(label) } catch { report(label, error) }
        }
      }
    )
  }
}
