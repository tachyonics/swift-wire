import Testing
import WireTestLibrary

/// Iteration 7c — same-package cross-module composition. `WireTestLibrary`
/// is a Wire-aware sibling target (it ships a `_WireExports.swift` marker
/// and a `public @Singleton LibraryService`). The IntegrationTests build
/// plugin re-parses the library's sources, stamps its bindings with
/// `originModule: "WireTestLibrary"`, composes them into this target's
/// `_WireGraph`, and emits `import WireTestLibrary` into the generated
/// file so the library's public type is reachable.
@Suite("CrossModuleComposition")
struct CrossModuleCompositionTests {
    @Test func samePackageLibraryBindingIsComposedAndConstructed() async throws {
        let graph = try await _WireGraph.bootstrap()
        #expect(graph.libraryService.name == "library")
    }
}
