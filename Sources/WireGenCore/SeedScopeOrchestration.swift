/// One per-seed scope graph after orchestration: the seed's
/// canonical type expression, the identifier suffix used in the
/// generated `_<suffix>WireScope` struct name and bootstrap function
/// name, and the `GraphResult` from validating the combined
/// (scope bindings + synthetic seed binding + singleton borrows)
/// dependency graph.
///
/// `borrowedBindingPropertyNames` carries the property-name identities
/// of bindings the scope "borrows" rather than constructs — the seed
/// parameter alias and any singleton dependency reached via the
/// `wireGraph:` bootstrap parameter. Code emission uses this to
/// filter the scope struct's stored-property list (borrowed bindings
/// appear in the bootstrap body as locals but not as stored properties
/// on the scope struct).
package struct SeedScopeOrchestration: Sendable {
    package let seedTypeExpression: String
    package let identifierSuffix: String
    package let result: GraphResult
    package let borrowedBindingPropertyNames: Set<String>

    package init(
        seedTypeExpression: String,
        identifierSuffix: String,
        result: GraphResult,
        borrowedBindingPropertyNames: Set<String>
    ) {
        self.seedTypeExpression = seedTypeExpression
        self.identifierSuffix = identifierSuffix
        self.result = result
        self.borrowedBindingPropertyNames = borrowedBindingPropertyNames
    }
}

/// Build one per-seed scope graph by combining the scope's own
/// bindings with a synthetic binding for the seed type and synthetic
/// "borrow" bindings for every singleton in the default graph. The
/// borrow bindings let the scope's `@Inject`-driven dependencies
/// resolve against singleton bindings constructed elsewhere
/// (`_WireGraph`) rather than re-construct them inside the scope.
///
/// The borrowed bindings appear in the resulting graph's topological
/// order; emission classifies them via
/// `SeedScopeOrchestration.borrowedBindingPropertyNames` and emits
/// them as `let x = <wireGraphLocal>.x` aliases rather than as
/// constructor calls — `<wireGraphLocal>` is the bootstrap's
/// wire-graph parameter internal name. The seed binding's `accessPath`
/// is the seed type's canonical property-name form, matching the
/// bootstrap's internal seed parameter name; emission then skips the
/// redundant `let X = X` shadow so the parameter is referenced
/// directly.
///
/// `defaultGraphSingletons` is the set of singleton bindings the
/// scope can borrow — every binding in the default partition,
/// scope-bound or provider, qualifies. Container-graph singletons are
/// not borrow-eligible (a `@Container`-selected graph is atomic and
/// the cross-scope borrowing mechanism doesn't span containers).
///
/// Returns the orchestration descriptor — caller integrates the
/// embedded `GraphResult` into the validation pipeline alongside the
/// default and per-container graphs.
package func orchestrateSeedScope(
    seedKey: ScopeKey,
    scopeBindings: [DiscoveredBinding],
    defaultGraphSingletons: [DiscoveredBinding],
    typealiases: [DiscoveredTypealias]
) -> SeedScopeOrchestration {
    let identifierSuffix = sanitizeIdentifier(seedKey.seed)

    let seedBinding = syntheticSeedBinding(seedTypeExpression: seedKey.seed)
    let borrowBindings = defaultGraphSingletons.map(syntheticBorrowBinding(for:))

    let combined = scopeBindings + [seedBinding] + borrowBindings.map(DiscoveredBinding.provider)
    let result = buildDependencyGraph(from: combined, typealiases: typealiases)

    var borrowedNames: Set<String> = []
    borrowedNames.reserveCapacity(borrowBindings.count)
    for borrow in borrowBindings {
        borrowedNames.insert(identifierName(forType: borrow.boundType, key: borrow.keyIdentifier))
    }

    return SeedScopeOrchestration(
        seedTypeExpression: seedKey.seed,
        identifierSuffix: identifierSuffix,
        result: result,
        borrowedBindingPropertyNames: borrowedNames
    )
}

/// Synthetic seed binding: a property-form provider whose
/// `accessPath` is the seed type's canonical property-name form
/// (`identifierName(forType:key:)`) — matching the private bootstrap
/// function's internal seed parameter name. Aligning the two means
/// the parameter itself is the synthetic's source, so a user binding
/// whose property name happens to be `seed` can coexist with the
/// scope's `seed:` parameter label without colliding on the literal
/// token. Emission renders this as `let <name> = <name>`, a shadow
/// bind from the parameter to a same-named local that the rest of
/// the body consumes uniformly.
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
/// `accessPath` is `"<wireGraphLocal>.<property>"` — where
/// `<wireGraphLocal>` is the bootstrap's wire-graph parameter
/// internal name derived from the parameter's type (`_WireGraph`) via
/// the standard property-name rule. Code emission renders the borrow
/// as `let <property> = <wireGraphLocal>.<property>`. The borrow has
/// no dependencies — the underlying singleton was constructed in the
/// default graph and is already initialised by the time the scope's
/// bootstrap runs.
///
/// Keyed singletons carry their `keyIdentifier` through so keyed
/// dependency resolution still matches; the borrow's access path
/// references the keyed property name on the singletons struct.
private func syntheticBorrowBinding(for singleton: DiscoveredBinding) -> DiscoveredProvider {
    let propertyName = identifierName(
        forType: singleton.boundType,
        key: singleton.keyIdentifier
    )
    return DiscoveredProvider(
        boundType: singleton.boundType,
        accessPath: "\(wireGraphParameterInternalName).\(propertyName)",
        form: .property,
        dependencies: [],
        genericParameterNames: [],
        location: SourceLocation(file: "<synthetic>", line: 0, column: 0),
        keyIdentifier: singleton.keyIdentifier
    )
}

/// Internal name of the per-seed bootstrap's `wireGraph:` parameter,
/// derived from the parameter's type (`_WireGraph`) via the same
/// property-name rule used everywhere else in emission. Both external
/// and internal labels are type-anchored: the external label
/// (`wireGraph:`) doesn't pre-commit to a hierarchical-scope model
/// where the parameter type might vary by scope depth, and the
/// internal label avoids collision with any user binding whose
/// property name resolves to `wireGraph`. Future hierarchical scopes
/// that thread more parent-graph parameters can apply the same rule
/// per parameter type.
package let wireGraphParameterInternalName: String = identifierName(
    forType: "_WireGraph",
    key: nil
)
