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
}
