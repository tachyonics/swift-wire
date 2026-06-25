// Origin-module metadata on the DiscoveredBinding enum (iteration 7b).
// The per-struct `originModule` fields live on the binding/key models
// themselves; the enum-level accessor and stamping helper live here to
// keep Discovery.swift under the length cap. Load-bearing for SE-0491
// cross-module qualification and the context-dependent visibility
// threshold under composition (7f) — see `MultiModuleComposition.md`.

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
