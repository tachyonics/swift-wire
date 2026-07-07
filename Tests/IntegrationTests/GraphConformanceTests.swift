import Testing
import Wire

/// M2.1 end-to-end: the generated `_WireGraph` conforms to an app-declared
/// protocol via a `WireGraphConformanceV1`, and is consumed *generically* through
/// that protocol — so this only compiles if the build plugin emitted a valid
/// `extension _WireGraph: GraphComposable` and the associated `Context` resolved.
@Suite("GraphConformance (end-to-end)")
struct GraphConformanceTests {
    /// Generic over the protocol — sees only `things`, never the concrete graph.
    private func labels<Graph: GraphComposable>(of graph: Graph) -> Set<String> {
        Set(graph.things.map { $0.label() })
    }

    @Test func generatedGraphConformsAndIsConsumedGenerically() async throws {
        let graph = try await Wire.bootstrap()
        #expect(labels(of: graph) == ["alpha", "beta"])
    }

    /// Generic over a composable whose key has no contributors — only compiles if the
    /// plugin emitted a valid `extension _WireGraph: EmptyComposable` with an empty-
    /// collection accessor.
    private func emptyCount<Graph: EmptyComposable>(of graph: Graph) -> Int {
        graph.emptyThings.count
    }

    @Test func generatedGraphConformsWithEmptyCollectionWhenNoContributors() async throws {
        let graph = try await Wire.bootstrap()
        #expect(emptyCount(of: graph) == 0)
    }
}
