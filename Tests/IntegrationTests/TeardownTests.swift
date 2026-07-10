import Testing
import Wire

/// M4 end-to-end: the generated graph conforms to `Teardownable` and its `teardown()`
/// runs each `@Teardown` action in reverse construction order — dependents before the
/// dependencies they hold. Drives the `TeardownExample` fixture through a real bootstrap.
@Suite("Teardown (end-to-end)")
struct TeardownTests {
    /// Consumed generically through `Teardownable` — only compiles if the plugin emitted
    /// the conformance on the graph.
    private func drive(_ graph: some Teardownable) async -> [any Error] {
        await graph.teardown()
    }

    @Test func teardownRunsActionsInReverseDependencyOrder() async throws {
        teardownLog.withLock { $0.removeAll() }

        let graph = try await Wire.bootstrap()
        let errors = await drive(graph)

        #expect(errors.isEmpty)
        let log = teardownLog.withLock { $0 }
        // All teardown actions fired — including `opaque`, whose `@Teardown` calls a concrete
        // method absent from its bound protocol (opaque-teardown fix), on a graph made generic by
        // that opaque binding while seed scopes borrow from it (seed-scope + opaque-lift fix).
        #expect(Set(log) == ["consumer", "pool", "client", "opaque"])
        // The consumer (dependent) tears down before the resources it holds.
        let consumer = try #require(log.firstIndex(of: "consumer"))
        let pool = try #require(log.firstIndex(of: "pool"))
        let client = try #require(log.firstIndex(of: "client"))
        #expect(consumer < pool)
        #expect(consumer < client)
    }
}
