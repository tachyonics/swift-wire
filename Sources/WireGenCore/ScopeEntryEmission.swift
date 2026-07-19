// Scope-entry thunk emission — the closure a bridging contributor proxy carries.
//
// A `.singleton` proxy over a `@Scoped(seed:)` subject takes a `_wireEnterScope` thunk. `appendStruct`
// emits it here, inside the bootstrap body, so the closure captures the singleton locals the subject's
// scope borrows. The construction reuses the ordinary per-binding emitter (`constructionExpression`),
// with the scope's borrows resolving to the captured locals (borrow property-name == singleton
// local-name) and the seed to the closure parameter. Its companion — the `.scopeCapture` ordering deps
// that make the proxy sort after those singletons — is `ScopeEntryLinking`.

/// Emit the scope-entry thunk for a bridging contributor proxy — a `@Sendable (Seed) async throws ->
/// Subject` closure that constructs the proxy's `@Scoped(seed:)` subject fresh from a seed and returns
/// it. Captures the singleton locals the scope borrows (they resolve to the same identity names the
/// enclosing bootstrap already bound). The proxy's `_wireEnterScope` argument resolves to this thunk's
/// local by identity naming, with no override. `scopes` maps seed-type expression → the seed scope's
/// emission for this graph; returns `nil` for a non-bridge proxy (no scope-entry dependency, or no
/// matching scope).
/// The scope-entry thunk lines for `binding` when it is a bridging contributor proxy (a scope-bound
/// type carrying a `_wireEnterScope` dependency), else `nil` — the entry point the bootstrap emitter
/// calls per binding.
func scopeEntryThunkLines(
    forBridgeProxy binding: DiscoveredBinding,
    scopes: [String: SeedScopeEmission]
) -> [String]? {
    guard case .scopeBound(let proxy) = binding,
        let scopeEntry = proxy.dependencies.first(where: { $0.name == contributorProxyScopeEntryFieldName })
    else { return nil }
    return scopeEntryThunkLines(for: scopeEntry, scopes: scopes)
}

private func scopeEntryThunkLines(
    for dependency: DependencyParameter,
    scopes: [String: SeedScopeEmission]
) -> [String]? {
    guard let (seed, subject) = parsedContributorScopeEntryThunkType(dependency.type),
        let scope = scopes[seed]
    else { return nil }
    let thunkLocal = identifierName(forType: dependency.type, key: nil)
    let seedLocal = identifierName(forType: seed, key: nil)
    let subjectLocal = identifierName(forType: subject, key: nil)

    var lines: [String] = ["    let \(thunkLocal): \(dependency.type) = { \(seedLocal) in"]
    for binding in scope.topologicalOrder {
        let name = propertyName(for: binding)
        // A borrowed singleton resolves to the captured bootstrap local of the same identity name, so
        // it is not re-constructed here; the seed's `let seed = seed` shadow is likewise redundant.
        if scope.borrowedBindingPropertyNames.contains(name) { continue }
        let construction = constructionExpression(for: binding)
        if name == construction { continue }
        lines.append("        let \(name) = \(construction)")
    }
    lines.append("        return \(subjectLocal)")
    lines.append("    }")
    return lines
}
