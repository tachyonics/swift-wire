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
        let graph = try await _Wire.bootstrap()
        #expect(graph.libraryService.name == "library")
    }

    /// Iteration 7f — same-package visibility threshold. `PackageVisibleService`
    /// is `package`, not `public`. `WireTestLibrary` is a `.target` dependency
    /// (same package), so `package` is reachable across the module boundary and
    /// clears the threshold without `public`: this only compiles because the
    /// generated `_WireGraph` references the `package` type. An `internal`
    /// binding would be rejected; a `package` binding across a *package* boundary
    /// (the external harness) would need `public`.
    @Test func samePackagePackageVisibleBindingIsComposed() async throws {
        let graph = try await _Wire.bootstrap()
        #expect(graph.packageVisibleService.label == "package-visible")
    }
}
