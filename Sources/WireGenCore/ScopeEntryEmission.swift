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
    guard let (seed, subject, doubles) = parsedContributorScopeEntryThunkType(thunkType),
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
    // Per-root reachability (M5.4.6): construct — and, below, tear down — only the bindings reachable from
    // the routed controller, so two controllers sharing a seed don't build each other's subgraphs. `nil`
    // means no pruning (the scope carried no edges, or the subject binding wasn't found): whole-scope, the
    // pre-M5.4.6 behaviour.
    let reachable = reachableBindings(from: subjectLocal, in: scope)

    // Rule 3 — existential aliases for the promotions this thunk actually constructs, so the pruned
    // set never binds an alias for a controller it doesn't serve. A promoted *borrowed* producer is
    // captured from the bootstrap body under its own name but its alias may not be (the bootstrap
    // binds one only if it promotes too), so that alias is bound up front here off the captured local.
    let aliases = scopeExistentialAliasPlan(
        scope,
        constructedHere: scope.topologicalOrder.filter { reachable?.contains($0.identity) ?? true }
    )

    // A test-graph variant threads a `doubles` value in alongside the seed; a `@BindType`d binding in the
    // scope resolves to a field on it (its construction line is `let <field> = doubles.<field>`, emitted by
    // the ordinary per-binding path since the binding is a `doubles.<field>` provider). The parameter's
    // local name is the fixed `doubles`, matching those providers' access paths. `nil` is the production
    // thunk (seed only). The `doubles` type rides the thunk type, so it survives the `liftSpecialised`.
    let parameterList = doubles.map { "\(seedLocal): \(seed), doubles: \($0)" } ?? "\(seedLocal): \(seed)"
    var lines: [String] = ["    let \(thunkLocal) = { @Sendable (\(parameterList)) async throws in"]
    for alias in aliases.upFront {
        lines.append(contentsOf: existentialAliasLines(alias, boundTo: alias.producerLocalName, indent: "        "))
    }
    for binding in scope.topologicalOrder {
        if let reachable, !reachable.contains(binding.identity) { continue }
        let name = propertyName(for: binding)
        // A borrowed singleton resolves to the captured bootstrap local of the same identity name, so
        // it is not re-constructed here; the seed's `let seed = seed` shadow is likewise redundant.
        if scope.borrowedBindingPropertyNames.contains(name) { continue }
        let construction = constructionExpression(for: binding)
        if name == construction { continue }
        lines.append("        let \(name) = \(construction)")
        lines.append(
            contentsOf: existentialAliasLines(
                aliases.afterConstruction[binding.identity],
                boundTo: name,
                indent: "        "
            )
        )
    }
    // The scope's teardown closure — the reverse-order `@Teardown` walk for the scope's own bindings (not
    // the borrowed singletons, which are torn down at app scope), pruned to the reachable set so a request
    // to one controller never tears down a sibling's binding. Captures the construction locals above, so it
    // runs against each binding's concrete instance. Returned alongside the subject; the witness runs it
    // after the response (M5.4.5). Consistent with the graph's captured `_wireTeardown`.
    lines.append(contentsOf: scopeTeardownClosureLines(scope, local: scopeTeardownLocalName, reachable: reachable))
    lines.append("        return (\(subjectLocal), \(scopeTeardownLocalName))")
    lines.append("    }")
    return lines
}

/// The binding identities reachable from the routed controller over the scope's resolved edges — a BFS
/// rooted at the subject binding (found by its construction-local name). Returns `nil` (no pruning) when
/// the scope carries no edges or the subject binding isn't found, preserving whole-scope construction.
private func reachableBindings(from subjectLocal: String, in scope: SeedScopeEmission) -> Set<BindingIdentity>? {
    guard !scope.edges.isEmpty,
        let subject = scope.topologicalOrder.first(where: { propertyName(for: $0) == subjectLocal })
    else { return nil }
    var reachable: Set<BindingIdentity> = []
    var queue = [subject.identity]
    while let identity = queue.popLast() {
        guard reachable.insert(identity).inserted else { continue }
        queue.append(contentsOf: scope.edges[identity] ?? [])
    }
    return reachable
}

/// The scope-entry thunk's teardown-closure local name. `wireMVC`-free (this is swift-wire), just a
/// bootstrap-local identifier the thunk returns.
private let scopeTeardownLocalName = "_wireScopeTeardown"

/// The lines for the scope's teardown closure, emitted inside the scope-entry thunk. Mirrors the graph's
/// captured `_wireTeardown` (reverse construction order, errors collected not thrown) but scoped to the
/// seed scope's own `@Teardown` bindings and indented for the thunk body. Always emitted (an empty scope
/// yields `{ … return errors }` with no calls) so the thunk's return type stays uniform.
private func scopeTeardownClosureLines(
    _ scope: SeedScopeEmission,
    local: String,
    reachable: Set<BindingIdentity>?
) -> [String] {
    let torn = scope.topologicalOrder.reversed().filter { binding in
        binding.teardown != nil
            && !scope.borrowedBindingPropertyNames.contains(propertyName(for: binding))
            && (reachable?.contains(binding.identity) ?? true)
    }
    let mutatesErrors = torn.contains { binding in
        switch binding.teardown?.kind {
        case .member(_, _, let isThrowing): return isThrowing
        case .action: return true
        case nil: return false
        }
    }
    var lines: [String] = [
        "        let \(local): \(scopeEntryTeardownType) = {",
        "            \(mutatesErrors ? "var" : "let") errors: [any Error] = []",
    ]
    for binding in torn {
        lines.append(contentsOf: teardownCallLines(for: binding).map { "    " + $0 })
    }
    lines.append("            return errors")
    lines.append("        }")
    return lines
}
