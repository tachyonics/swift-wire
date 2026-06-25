// Origin-module metadata on the DiscoveredBinding enum (iteration 7b).
// The per-struct `originModule` fields live on the binding/key models
// themselves; the enum-level accessor and stamping helper live here to
// keep Discovery.swift under the length cap. Load-bearing for SE-0491
// cross-module qualification and the context-dependent visibility
// threshold under composition (7f) — see `MultiModuleComposition.md`.

extension DiscoveredBinding {
    /// The module the binding was discovered in, or `nil` when unknown
    /// (the single-module default, or a binding constructed without a
    /// module). Stamped during discovery.
    package var originModule: String? {
        switch self {
        case .scopeBound(let scopeBound): return scopeBound.originModule
        case .provider(let provider): return provider.originModule
        case .aggregate(let aggregate): return aggregate.originModule
        }
    }

    /// Return a copy of the binding with its `originModule` set — used by
    /// discovery to stamp every binding with the module its source file
    /// belongs to.
    package func settingOriginModule(_ module: String?) -> DiscoveredBinding {
        switch self {
        case .scopeBound(var scopeBound):
            scopeBound.originModule = module
            return .scopeBound(scopeBound)
        case .provider(var provider):
            provider.originModule = module
            return .provider(provider)
        case .aggregate(var aggregate):
            aggregate.originModule = module
            return .aggregate(aggregate)
        }
    }
}
