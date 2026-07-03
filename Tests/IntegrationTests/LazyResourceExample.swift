import Wire

/// End-to-end exercise of the canonical "user-written
/// `@Provides -> Lazy<T>`" pattern under the just-a-type framing.
/// The build plugin treats `Lazy<LazyResource>` as a normal
/// binding — no wrapper recognition, no consumer classification.
/// Bootstrap allocates the wrapper (cheap); the underlying
/// `LazyResource` constructs only on first `.get()` and is cached
/// for the wrapper's lifetime, giving the "heavy-init /
/// first-use singleton" lifecycle from a normal binding setup.
package final class LazyResource: Sendable {
    package let value: String
    package init(value: String) {
        self.value = value
    }
}

/// Counts factory invocations so the integration test can assert
/// the load-bearing semantics of `Lazy<T>`:
///   - The factory does NOT run during bootstrap (counter stays
///     at zero past `Wire.bootstrap()`).
///   - The factory runs exactly once across any number of
///     `.get()` calls (counter == 1 after N calls).
package actor LazyResourceCallCount {
    private(set) package var value: Int = 0
    package init() {}
    package func increment() {
        value += 1
    }
}

/// A `@Provides func` (not `@Provides let`) so each bootstrap
/// gets a fresh counter. Module-scope `let` would share the same
/// actor instance across parallel test bootstraps and cross-
/// contaminate the assertions.
@Provides
package func makeLazyResourceCallCount() -> LazyResourceCallCount {
    LazyResourceCallCount()
}

/// The producer side: a normal `@Provides func` returning a
/// `Lazy<LazyResource>`. The function body runs at bootstrap and
/// constructs the wrapper synchronously; the factory closure
/// passed to `Lazy { ... }` captures `callCount` and defers the
/// actual `LazyResource` construction (plus the counter
/// increment) until the first `.get()` call.
@Provides
package func makeLazyResource(callCount: LazyResourceCallCount) -> Lazy<LazyResource> {
    Lazy {
        await callCount.increment()
        return LazyResource(value: "materialised")
    }
}

/// `@Singleton` consumer that holds the `Lazy<LazyResource>`
/// wrapper. Demonstrates that the wrapper is just another binding
/// type — injected through the same `@Inject` mechanism as any
/// other dependency. `materialise()` exposes the `.get()` call to
/// the test.
@Singleton(allowUnused: true)
package struct LazyResourceConsumer {
    @Inject package var resource: Lazy<LazyResource>

    package func materialise() async throws -> LazyResource {
        try await resource.get()
    }
}
