import Testing

/// Spike #2 from `Documentation/Notes/MultibindingsImplementationPlan.md`.
///
/// Proves the `BuilderKey` emission shape compiles in the no-opaque
/// slice *before* Step 5 codegen depends on it: a `@resultBuilder`-
/// annotated local function that lists the (already-constructed)
/// contributor locals in `withOrder:` sequence, with the explicit
/// concrete return type read from the builder's `buildBlock`.
///
/// **Spike finding:** the result-builder attribute is *not* supported on
/// a closure (`{ @Builder () -> R in … }` fails to compile), so the
/// originally-planned immediately-invoked-closure form is out. A builder-
/// annotated local function captures the contributor locals and works —
/// this is the shape Step 5 codegen must emit.
///
/// This is hand-written, not wired through Wire — `@Contributes`
/// discovery doesn't exist yet. It exists to validate the literal and to
/// confirm the result-builder transform preserves contributor order.
private protocol SpikeMiddleware {
    func tag() -> String
}

@resultBuilder
private enum SpikeMiddlewareBuilder {
    static func buildBlock(_ parts: any SpikeMiddleware...) -> [any SpikeMiddleware] {
        Array(parts)
    }
}

private struct SpikeLogMiddleware: SpikeMiddleware {
    func tag() -> String { "log" }
}

private struct SpikeAuthMiddleware: SpikeMiddleware {
    func tag() -> String { "auth" }
}

@Suite("BuilderKey fold spike")
struct BuilderKeyFoldSpikeTests {
    @Test func builderFoldCompilesAndPreservesOrder() {
        // Contributor locals as Step 5's bootstrap will have already
        // bound them.
        let auth = SpikeAuthMiddleware()
        let log = SpikeLogMiddleware()

        // The shape Step 5 emits for a `BuilderKey` aggregate: a builder-
        // annotated local function with an explicit concrete return type
        // (read from `buildBlock`) listing the contributor locals in
        // order, invoked at the binding site.
        @SpikeMiddlewareBuilder
        func fold() -> [any SpikeMiddleware] {
            auth
            log
        }
        let chain = fold()

        #expect(chain.map { $0.tag() } == ["auth", "log"])
    }
}
