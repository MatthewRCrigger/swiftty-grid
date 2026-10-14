import Testing

/// App model and presentation fixtures share the application's main event loop.
/// Nested AppKit sheet loops can delay sibling model tasks beyond their own
/// unchanged deadlines. Serialize these independent fixtures together; each
/// test's explicitly concurrent operations still run concurrently.
@Suite(.serialized)
struct MainActorIntegrationTests {}
