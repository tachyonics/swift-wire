// Origin-module metadata on the DiscoveredBinding enum (iteration 7b).
// The per-struct `originModule` fields live on the binding/key models
// themselves. Load-bearing for SE-0491 cross-module qualification and
// the context-dependent visibility threshold under composition (7f) —
// see `MultiModuleComposition.md`.

extension DiscoveredBinding {
    /// The module the binding was discovered in. Discovered bindings are
    /// stamped at construction with the consumer target name (or a
    /// dependency's name under composition); synthetic bindings (borrow,
    /// seed, aggregate) inherit it from the source they're derived from.
    package var originModule: String {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.originModule
        case .provider(let provider): return provider.originModule
        case .aggregate(let aggregate): return aggregate.originModule
        }
    }
}

/// `import <module>` lines for every distinct origin module among
/// `bindings` other than the consumer's own. A binding composed from a
/// dependency is referenced by the generated file (which lives in the
/// consumer module), so the file needs an import to reach the
/// dependency's public types. Sorted for deterministic output.
package func foreignImports(in bindings: [DiscoveredBinding], consumerModule: String) -> [String] {
    Set(bindings.map(\.originModule))
        .subtracting([consumerModule])
        .sorted()
        .map { "import \($0)" }
}
