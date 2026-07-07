import Synchronization
import Wire

/// End-to-end fixture for M4 teardown emission: an owned `@Singleton` (member-form
/// `@Teardown`), a third-party-style produced value (producer-form `@Teardown`), and a
/// consumer depending on both. Each teardown appends to `teardownLog`, so `TeardownTests`
/// can assert the reverse-dependency walk fires them — the consumer (dependent) before
/// the resources it holds. The produced type stays the honest `TeardownHTTPClient`
/// (no wrapper, no unwrap) and consumers `@Inject` it directly.

/// Records which teardown actions ran, in order. `TeardownTests` resets and reads it;
/// only that test calls `graph.teardown()`.
package let teardownLog = Mutex<[String]>([])

/// Stand-in for a third-party resource the consumer can't add a conformance to. Its
/// teardown rides on the `@Provides`. `shutdown` logs, so the producer action stays a
/// bare `client.shutdown()` — the generated teardown never names the log or `Mutex`.
package final class TeardownHTTPClient: Sendable {
    package let label: String
    package init(label: String) { self.label = label }
    package func shutdown() async throws { teardownLog.withLock { $0.append("client") } }
}

/// Owned-type member form — the teardown method is marked with bare `@Teardown`.
@Singleton
package struct TeardownDatabasePool {
    package let dsn: String

    @Inject
    package init() { self.dsn = "memory://pool" }

    @Teardown
    package func teardown() async throws { teardownLog.withLock { $0.append("pool") } }
}

/// Producer form — the teardown action is an explicit-typed closure on the `@Provides`.
@Provides
@Teardown({ (client: TeardownHTTPClient) in try await client.shutdown() })
package func makeTeardownClient() -> TeardownHTTPClient {
    TeardownHTTPClient(label: "live")
}

/// Depends on both resources, so it constructs after them and tears down before them —
/// the reverse-dependency invariant the test asserts.
@Singleton(allowUnused: true)
package struct TeardownConsumer {
    @Inject package var pool: TeardownDatabasePool
    @Inject package var client: TeardownHTTPClient

    @Teardown
    package func teardown() async throws { teardownLog.withLock { $0.append("consumer") } }
}
