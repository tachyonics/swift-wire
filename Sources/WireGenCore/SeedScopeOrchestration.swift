/// One per-seed scope graph after orchestration: the seed's
/// canonical type expression, the identifier suffix used in the
/// generated `_<suffix>WireScope` struct name and bootstrap function
/// name, the parent graph type the scope borrows singletons from,
/// and the `GraphResult` from validating the combined (scope
/// bindings + synthetic seed binding + singleton borrows)
/// dependency graph.
///
/// `borrowedBindingPropertyNames` carries the property-name identities
/// of bindings the scope "borrows" rather than constructs — any
/// singleton dependency reached via the `wireGraph:` bootstrap
/// parameter. Code emission uses this to skip borrow let-lines and
/// inline the borrow's access path at consumer call sites.
///
/// `parentGraphType` is the parent graph's type expression
/// (`_WireGraph` for default-graph seeded scopes; `_<Container>WireGraph`
/// for scopes inside a `@Container`). Drives the bootstrap parameter
/// type and — via `identifierName(forType:key:)` — its internal name.
package struct SeedScopeOrchestration: Sendable {
    package let seedTypeExpression: String
    package let identifierSuffix: String
    package let parentGraphType: String
    package let result: GraphResult
    package let borrowedBindingPropertyNames: Set<String>

    package init(
        seedTypeExpression: String,
        identifierSuffix: String,
        parentGraphType: String,
        result: GraphResult,
        borrowedBindingPropertyNames: Set<String>
    ) {
        self.seedTypeExpression = seedTypeExpression
        self.identifierSuffix = identifierSuffix
        self.parentGraphType = parentGraphType
        self.result = result
        self.borrowedBindingPropertyNames = borrowedBindingPropertyNames
    }

    /// Return a copy of this orchestration with a different `result`.
    /// Used by the diagnostic-enrichment pipeline to attach cross-
    /// scope hints to missing-binding errors without breaking the
    /// `let`-only field convention.
    package func withResult(_ newResult: GraphResult) -> SeedScopeOrchestration {
        SeedScopeOrchestration(
            seedTypeExpression: seedTypeExpression,
            identifierSuffix: identifierSuffix,
            parentGraphType: parentGraphType,
            result: newResult,
            borrowedBindingPropertyNames: borrowedBindingPropertyNames
        )
    }
}

/// Build one per-seed scope graph by combining the scope's own
/// bindings with a synthetic binding for the seed type and the
/// caller-supplied set of synthetic "borrow" bindings. The borrow
/// bindings let the scope's `@Inject`-driven dependencies resolve
/// against bindings constructed elsewhere (default-graph singletons
/// for module-scope seeded scopes; the enclosing container's
/// singletons for container-scope seeded scopes) rather than
/// re-construct them inside the scope.
///
/// The borrowed bindings appear in the resulting graph's topological
/// order; emission classifies them via
/// `SeedScopeOrchestration.borrowedBindingPropertyNames` and inlines
/// their `accessPath` at consumer call sites. The seed binding's
/// `accessPath` is the seed type's canonical property-name form,
/// matching the bootstrap's internal seed parameter name; emission
/// then skips the redundant `let X = X` shadow so the parameter is
/// referenced directly.
///
/// `containerName` is non-nil for container-scope seeded scopes;
/// the scope's identifier suffix composes as `<Container>_<Seed>` so
/// the emitted struct name (`_<Container>_<Seed>WireScope`) and
/// bootstrap function name disambiguate per container.
///
/// `parentGraphType` flows through to the emission descriptor
/// (`SeedScopeEmission.parentGraphType`) and drives the bootstrap
/// parameter type. Borrow bindings the caller passed in should
/// already reference this same parent graph in their access paths;
/// callers typically build them via `syntheticSingletonBorrowBindings`
/// with the matching parent graph type.
package func orchestrateSeedScope(
    seedKey: ScopeKey,
    containerName: String? = nil,
    scopeBindings: [DiscoveredBinding],
    borrowBindings: [DiscoveredBinding],
    parentGraphType: String = "_WireGraph",
    typealiases: [DiscoveredTypealias],
    multibindingKeys: [DiscoveredMultibindingKey] = [],
    resultBuilders: [DiscoveredResultBuilder] = []
) -> SeedScopeOrchestration {
    let seedSuffix = sanitizeIdentifier(seedKey.seed)
    let identifierSuffix: String
    if let containerName {
        identifierSuffix = "\(containerName)_\(seedSuffix)"
    } else {
        identifierSuffix = seedSuffix
    }

    let seedBinding = syntheticSeedBinding(seedTypeExpression: seedKey.seed)

    let combined = scopeBindings + [seedBinding] + borrowBindings
    // Multibindings aggregate from the scope's own contributors (a
    // borrowed singleton's contribution stays with the default graph, so
    // cross-scope contribution into a scope aggregate isn't supported).
    let result = buildDependencyGraph(
        from: combined,
        typealiases: typealiases,
        multibindingKeys: multibindingKeys,
        resultBuilders: resultBuilders
    )

    var borrowedNames: Set<String> = []
    borrowedNames.reserveCapacity(borrowBindings.count)
    for borrow in borrowBindings {
        borrowedNames.insert(identifierName(forType: borrow.boundType, key: borrow.keyIdentifier))
    }

    return SeedScopeOrchestration(
        seedTypeExpression: seedKey.seed,
        identifierSuffix: identifierSuffix,
        parentGraphType: parentGraphType,
        result: result,
        borrowedBindingPropertyNames: borrowedNames
    )
}

/// Build synthetic borrow bindings for every singleton available to a
/// per-seed scope. Each borrow is a property-form provider whose
/// `accessPath` is `"<parentGraphLocal>.<property>"` — derived from
/// the parent graph's type via `identifierName(forType:key:)` — so
/// emission renders the borrow as
/// `let <property> = <parentGraphLocal>.<property>` (or, more often,
/// inlines that expression at the consumer's call site).
///
/// `parentGraphType` selects which parent graph the borrows point at:
/// `"_WireGraph"` for default-graph seeded scopes,
/// `"_<Container>WireGraph"` for container-scope seeded scopes. The
/// caller passes the matching singleton set (default-graph singletons
/// or the container's singletons, respectively).
///
/// Exposed at module level so callers can construct the borrow set
/// once per parent graph and reuse it across every per-seed
/// orchestration in that graph. Future hierarchical-scope work can
/// introduce parallel `syntheticParentScopeBorrowBindings(from:)`-style
/// helpers and `orchestrateSeedScope` will accept their union without
/// needing to change.
package func syntheticSingletonBorrowBindings(
    from singletons: [DiscoveredBinding],
    inWireGraphOfType parentGraphType: String = "_WireGraph"
) -> [DiscoveredBinding] {
    // Borrows reference the wire-graph parameter by its *internal*
    // name (in-scope inside the private bootstrap function body), not
    // its external label. The internal name carries a leading
    // underscore to keep it distinct from any user binding whose
    // property name might resolve to `wireGraph` or
    // `testContainerWireGraph`.
    let parentLocal = wireGraphParameterInternalName(forType: parentGraphType)
    return singletons.map { .provider(syntheticBorrowBinding(for: $0, parentGraphLocal: parentLocal)) }
}

/// The wire-graph parameter's *external* argument label — used at
/// `bootstrap` call sites. Derived from the parent graph's type via
/// the standard property-name rule, with leading underscores
/// stripped first (Wire's generated graph types are prefixed with
/// `_` but idiomatic Swift labels aren't). `_WireGraph` becomes
/// `wireGraph`; `_TestContainerWireGraph` becomes
/// `testContainerWireGraph`.
package func wireGraphParameterLabel(forType parentGraphType: String) -> String {
    let stripped = String(parentGraphType.drop(while: { $0 == "_" }))
    return identifierName(forType: stripped, key: nil)
}

/// The wire-graph parameter's *internal* binding name — used inside
/// the private bootstrap function body and embedded in synthetic
/// borrow access paths. Built by prefixing the external label with
/// `_` so the local is visually distinct from any user binding
/// whose property name might resolve to the same external label
/// (e.g. a user singleton named `WireGraph` whose property name is
/// `wireGraph`). `_WireGraph` becomes `_wireGraph`;
/// `_TestContainerWireGraph` becomes `_testContainerWireGraph`.
package func wireGraphParameterInternalName(forType parentGraphType: String) -> String {
    "_" + wireGraphParameterLabel(forType: parentGraphType)
}

/// Synthetic seed binding: a property-form provider whose
/// `accessPath` is the seed type's canonical property-name form
/// (`identifierName(forType:key:)`) — matching the private bootstrap
/// function's internal seed parameter name. Aligning the two means
/// the parameter itself is the synthetic's source, so a user binding
/// whose property name happens to be `seed` can coexist with the
/// scope's `seed:` parameter label without colliding on the literal
/// token. Emission renders this as `let <name> = <name>`, a shadow
/// bind from the parameter to a same-named local; the same-name
/// shadow short-circuits emission's `let X = X` skip so no line is
/// actually written, and bare references resolve to the parameter.
private func syntheticSeedBinding(seedTypeExpression: String) -> DiscoveredBinding {
    .provider(
        DiscoveredProvider(
            boundType: seedTypeExpression,
            accessPath: identifierName(forType: seedTypeExpression, key: nil),
            form: .property,
            dependencies: [],
            genericParameterNames: [],
            location: SourceLocation(file: "<synthetic>", line: 0, column: 0)
        )
    )
}

/// Synthetic borrow binding for one singleton available to the scope.
/// `accessPath` is `"<parentGraphLocal>.<property>"` — where
/// `<parentGraphLocal>` is the bootstrap's parent-graph parameter
/// label (derived from the parent graph's type via
/// `wireGraphParameterLabel(forType:)`). Code emission inlines this
/// access path at consumer call sites.
///
/// The borrow has no dependencies — the underlying singleton was
/// constructed in the parent graph and is already initialised by the
/// time the scope's bootstrap runs.
///
/// The borrow inherits the original singleton's source location so
/// any diagnostic referencing the borrow (topological-order print,
/// future borrow-related errors) lands on the user's declaration
/// rather than a synthetic placeholder.
///
/// Keyed singletons carry their `keyIdentifier` through so keyed
/// dependency resolution still matches; the borrow's access path
/// references the keyed property name on the parent graph's struct.
private func syntheticBorrowBinding(
    for singleton: DiscoveredBinding,
    parentGraphLocal: String
) -> DiscoveredProvider {
    let propertyName = identifierName(
        forType: singleton.boundType,
        key: singleton.keyIdentifier
    )
    return DiscoveredProvider(
        boundType: singleton.boundType,
        accessPath: "\(parentGraphLocal).\(propertyName)",
        form: .property,
        dependencies: [],
        genericParameterNames: [],
        location: singleton.location,
        keyIdentifier: singleton.keyIdentifier
    )
}
