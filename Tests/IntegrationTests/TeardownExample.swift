import Wire

/// Iteration-6 end-to-end exercise of `@Teardown` under the
/// no-magic-type framing: an owned `@Singleton` whose teardown method is
/// marked with bare `@Teardown`, and a third-party-style produced value
/// whose teardown rides on the `@Provides` via `@Teardown({ ... })`.
///
/// What this fixture proves (the M1 validation gate): the producer's
/// return type stays the honest `TeardownHTTPClient` (no wrapper, no
/// unwrap step), the consumer `@Inject`s both honest types, and
/// `_WireGraph.bootstrap()` constructs them. M1 records the teardown
/// actions but emits no teardown calls — nothing here is ever torn down
/// by Wire (that's M4).

/// Stand-in for a third-party resource the consumer can't (or won't) add
/// a conformance to — no Wire protocol, just a plain type. Its teardown
/// is expressed at the `@Provides` site, not on the type.
package final class TeardownHTTPClient: Sendable {
    package let label: String
    package init(label: String) { self.label = label }
    package func shutdown() async throws {}
}

/// Owned-type member form. The teardown method is marked with bare
/// `@Teardown`; Wire records `(method: teardown, async, throws)` but
/// never calls it in M1.
@Singleton
package struct TeardownDatabasePool {
    package let dsn: String

    @Inject
    package init() { self.dsn = "memory://pool" }

    @Teardown
    package func teardown() async throws {
        // Intentionally empty — M1 never invokes this. Present to
        // exercise recognition + recording of the member form.
    }
}

/// Producer form. The teardown action is an explicit-typed closure on
/// the `@Provides`; the produced type stays honest, so consumers inject
/// `TeardownHTTPClient` directly.
@Provides
@Teardown({ (client: TeardownHTTPClient) in try await client.shutdown() })
package func makeTeardownClient() -> TeardownHTTPClient {
    TeardownHTTPClient(label: "live")
}

/// Consumer injecting the honest, un-wrapped types — the point of the
/// design: no `Resource<T>` to unwrap, no `Lifecycle` to probe.
@Singleton(allowUnused: true)
package struct TeardownConsumer {
    @Inject package var pool: TeardownDatabasePool
    @Inject package var client: TeardownHTTPClient
}
