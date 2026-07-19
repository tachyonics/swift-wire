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
    // A *generic* bridge proxy is a lift node: the graph specialised its subject at the opaque backend
    // (`MeController<Repository>` → `MeController<some TodoRepository>`). Apply the same lift substitution
    // to the thunk's declared type — format-preserving, unlike the whitespace-canonicalised identity form,
    // which `async throws` needs — so the emitted thunk's type, local name, and return match the proxy's
    // specialised construction argument, not the raw generic form (whose bare `Repository` isn't in scope
    // in `_wireBootstrap`). A non-generic proxy is not a lift node, so its thunk type is unchanged.
    return scopeEntryThunkLines(thunkType: liftSpecialised(scopeEntry.type, in: binding), scopes: scopes)
}

/// Substitute a lift node's determined generic parameters with their `some Constraint` form in `type`,
/// preserving the type's spelling (mirrors `bridgedDependencyIdentity`'s Rule 2b, format-preserving).
private func liftSpecialised(_ type: String, in binding: DiscoveredBinding) -> String {
    guard binding.isLiftNode else { return type }
    let canonical = canonicalTypeName(type)
    var substitutions: [String: String] = [:]
    for (parameter, constraint) in binding.genericParameterConstraints
    where constraintIsDetermining(constraint) && parameterAppearsAsGenericArgument(parameter, in: canonical) {
        substitutions[parameter] = "some \(constraint)"
    }
    return substitutions.isEmpty ? type : substitutingIdentifierTokens(type, substitutions)
}

private func scopeEntryThunkLines(
    thunkType: String,
    scopes: [String: SeedScopeEmission]
) -> [String]? {
    guard let (seed, subject) = parsedContributorScopeEntryThunkType(thunkType),
        let scope = scopes[seed]
    else { return nil }
    let thunkLocal = identifierName(forType: thunkType, key: nil)
    let seedLocal = identifierName(forType: seed, key: nil)
    let subjectLocal = identifierName(forType: subject, key: nil)

    // Emit the closure with its parameter, effects, and `@Sendable` inline, letting Swift infer the return
    // type from the body — rather than annotating the `let` with the return type. A subject generic over
    // the opaque backend then resolves to the *concrete* backend the body constructs
    // (`MeController<CouchDBTodoRepository>`) instead of an unspellable `some P` closure-return type, and
    // the proxy's generic parameter is inferred from the passed closure. (`thunkType` still names the local
    // so the proxy's construction argument resolves to it by identity.)
    var lines: [String] = ["    let \(thunkLocal) = { @Sendable (\(seedLocal): \(seed)) async throws in"]
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
