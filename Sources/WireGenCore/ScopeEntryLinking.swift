// Scope-entry linking — what lets a *bridging* contributor proxy sort correctly.
//
// A `.singleton` proxy over a `@Scoped(seed:)` subject carries a `_wireEnterScope` thunk that
// constructs the subject from a seed, capturing (as bootstrap locals) the app singletons the subject's
// scope borrows. That thunk is emitted inline in the bootstrap body, so the proxy must be constructed
// *after* those singletons. The proxy has no ordinary dependency on them — they are consumed inside the
// thunk, not by the proxy's init — so this pass adds one `.scopeCapture` ordering dependency per
// borrowed singleton: resolved by the graph (driving the topological sort) but never emitted as a proxy
// field or construction argument.
//
// Runs in WireGen after seed-scope orchestration (which computes the borrow set) and before the app
// graph's topological sort. Domain-free: it matches a proxy to its scope by the seed the proxy's
// `_wireEnterScope` thunk names, and reads the scope's borrowed singletons as opaque `(type, key)` pairs.

/// Add `.scopeCapture` dependencies to every bridging contributor proxy in `singletons`, one per
/// singleton the proxy's seed scope actually borrows. Non-bridge bindings pass through unchanged.
/// `orchestrations` are the seed scopes over the *same* graph as `singletons` (so seeds are unique).
package func linkingScopeEntryCaptures(
    into singletons: [DiscoveredBinding],
    orchestrations: [SeedScopeOrchestration]
) -> [DiscoveredBinding] {
    // Per seed: one `.scopeCapture` dependency for each singleton the scope *genuinely uses* as a borrow.
    // The borrow set is over-generated (one synthetic borrow per app singleton, whether the scope reaches
    // it or not — and, since a bridge proxy is itself an app singleton, that includes the proxy). Capturing
    // an unused borrow would add a spurious edge (a proxy capturing itself → a cycle), so restrict to the
    // borrow types the scope's own (non-borrow) bindings actually depend on.
    var capturesBySeed: [String: [DependencyParameter]] = [:]
    for orchestration in orchestrations {
        let reached = orchestration.result.outcome.topologicalOrder ?? []
        let borrowNames = orchestration.borrowedBindingPropertyNames
        var usedTypes: Set<String> = []
        for binding in reached {
            let name = identifierName(forType: binding.boundType, key: binding.keyIdentifier)
            guard !borrowNames.contains(name) else { continue }  // a borrow itself uses nothing here
            for dependency in binding.dependencies { usedTypes.insert(dependency.type) }
        }
        capturesBySeed[orchestration.seedTypeExpression] = reached.compactMap { binding in
            let name = identifierName(forType: binding.boundType, key: binding.keyIdentifier)
            guard borrowNames.contains(name), usedTypes.contains(binding.boundType) else { return nil }
            return DependencyParameter(
                name: nil,
                type: binding.boundType,
                kind: .scopeCapture,
                location: binding.location,
                keyIdentifier: binding.keyIdentifier
            )
        }
    }
    guard capturesBySeed.values.contains(where: { !$0.isEmpty }) else { return singletons }

    return singletons.map { binding in
        guard case .scopeBound(let proxy) = binding,
            let thunk = proxy.dependencies.first(where: { $0.kind == .scopeEntryThunk }),
            let (seed, _) = parsedContributorScopeEntryThunkType(thunk.type),
            let captures = capturesBySeed[seed], !captures.isEmpty
        else { return binding }
        return binding.appendingDependencies(captures)
    }
}
