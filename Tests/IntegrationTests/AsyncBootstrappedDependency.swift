import Wire

/// Exercises effect-aware emission end-to-end: a `@Provides func`
/// that's `async throws` produces a binding that consumers can
/// `@Inject` normally; WireGen emits `try await makeAsyncToken()`
/// at the construction site; the bootstrap function (already
/// `async throws`) accepts the call colour transparently.
package struct AsyncToken: Sendable {
    package let value: String
}

@Provides
package func makeAsyncToken() async throws -> AsyncToken {
    // Pretend to do async work — yielding to the cooperative scheduler
    // so the `await` is meaningful, not just decorative.
    try await Task.sleep(nanoseconds: 1)
    return AsyncToken(value: "async-token-resolved")
}

/// `@Singleton` consumer that injects the async-bound token. The
/// consumer's own init is sync (macro-synthesised memberwise),
/// so no propagation through to its construction call — only the
/// `makeAsyncToken()` line gets the `try await` prefix in the
/// emitted bootstrap.
@Singleton(allowUnused: true)
package struct AsyncTokenConsumer {
    @Inject package var token: AsyncToken

    package func describe() -> String {
        "consumer holds \(token.value)"
    }
}
