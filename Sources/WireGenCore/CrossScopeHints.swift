/// Walk a `GraphResult`'s missing-binding errors and attach a
/// `CrossScopeHint` to each one whose dependency type is bound in
/// another partition. Returns the same `GraphResult` shape with the
/// enriched missing-binding list; non-validation-failed outcomes
/// pass through unchanged.
///
/// `consumerPartition` is the partition the graph is validating
/// against: `Partition.default` for the default graph,
/// `Partition(container: name)` for a `@Container`'s graph,
/// `Partition(container:, scope:)` for a seeded scope. Bindings
/// inside a seeded scope's combined graph (which mixes the scope's
/// own bindings with synthetic borrows + seed) all attribute to
/// the scope's partition for cross-scope-check purposes.
package func enrichMissingBindingsWithCrossScopeHints(
    _ result: GraphResult,
    consumerPartition: Partition,
    allBindings: [Partition: [DiscoveredBinding]]
) -> GraphResult {
    guard case .validationFailed(let errors) = result.outcome else { return result }
    guard !errors.missingBindings.isEmpty else { return result }
    let enriched = errors.missingBindings.map { missing -> MissingBinding in
        guard missing.crossScopeHint == nil,
            let hint = crossScopeHintFor(
                missing: missing,
                consumerPartition: consumerPartition,
                allBindings: allBindings
            )
        else { return missing }
        return MissingBinding(
            consumer: missing.consumer,
            dependency: missing.dependency,
            typealiasHint: missing.typealiasHint,
            crossScopeHint: hint
        )
    }
    return GraphResult(
        outcome: .validationFailed(
            GraphResult.ValidationErrors(
                cycles: errors.cycles,
                missingBindings: enriched,
                duplicateBindings: errors.duplicateBindings,
                identifierCollisions: errors.identifierCollisions
            )
        ),
        skipped: result.skipped
    )
}

/// Compute a `CrossScopeHint` for a missing-binding diagnostic when
/// the dependency's `(type, key)` is bound somewhere in the graph
/// but in a different scope partition than the consumer's. Returns
/// `nil` when no other partition contains a matching binding (i.e.
/// the missing-binding is genuinely missing, not a scope mismatch).
///
/// The check uses the same whitespace-canonicalised type matching
/// the graph builder uses for binding identity, so a dep written
/// `Logger` matches a binding declared `Logger` regardless of
/// cosmetic formatting differences. Keyed dependencies match only
/// against same-keyed bindings.
///
/// Called from the build orchestration layer (WireGen.swift's
/// graph-build flow) once per missing-binding across the full
/// partition map — the lookup is per-call linear in the binding
/// count, which is acceptable for the diagnostic path.
package func crossScopeHintFor(
    missing: MissingBinding,
    consumerPartition: Partition,
    allBindings: [Partition: [DiscoveredBinding]]
) -> CrossScopeHint? {
    let needle = canonicalTypeName(missing.dependency.type)
    let needleKey = missing.dependency.keyIdentifier
    // Iterate partitions in deterministic order so the diagnostic
    // is stable across runs. Collect ALL matches — when the binding
    // exists in multiple partitions, every one gets a `note:` line
    // and the fix-it shifts to a multiplicity-aware message.
    let sortedPartitions = allBindings.keys.sorted(by: partitionOrder)
    var matches: [CrossScopeHint.Match] = []
    var matchPartitions: [Partition] = []
    for partition in sortedPartitions {
        guard partition != consumerPartition,
            let bindings = allBindings[partition]
        else { continue }
        for binding in bindings {
            // Match against both `boundType` (the simple name used
            // for in-graph identity) and `boundTypeReference` (the
            // qualified form needed when crossing graph boundaries
            // — e.g., a `@Singleton` nested in `@Container Foo`
            // has `boundType == "Service"` but is referenced from
            // outside as `Foo.Service`). The cross-scope diagnostic
            // fires when the consumer wrote either form and the
            // binding matches the other.
            let typesMatch =
                canonicalTypeName(binding.boundType) == needle
                || canonicalTypeName(binding.boundTypeReference) == needle
            guard typesMatch, binding.keyIdentifier == needleKey else { continue }
            matches.append(
                CrossScopeHint.Match(
                    scopeDescription: describe(partition: partition),
                    location: binding.location
                )
            )
            matchPartitions.append(partition)
            // One match per partition is enough for the diagnostic —
            // intra-partition duplicate-binding errors are a separate
            // graph-validation concern handled elsewhere.
            break
        }
    }
    guard !matches.isEmpty else { return nil }
    return CrossScopeHint(
        matches: matches,
        consumerScopeDescription: describe(partition: consumerPartition),
        fixItSuggestion: fixItSuggestion(
            consumerPartition: consumerPartition,
            bindingPartitions: matchPartitions,
            consumerTypeName: consumerTypeName(missing.consumer)
        )
    )
}

/// Render a `Partition` as a human-readable scope label for the
/// cross-scope diagnostic. Lines up with how users write the
/// annotation in source — `@Singleton`, `@Scoped(seed: X.self)`,
/// `@Container Foo`, or the combined form for container-scope.
private func describe(partition: Partition) -> String {
    switch (partition.container, partition.scope) {
    case (nil, nil):
        return "@Singleton"
    case (let container?, nil):
        return "@Container \(container)"
    case (nil, let scope?):
        return "@Scoped(seed: \(scope.seed).self)"
    case (let container?, let scope?):
        return "@Container \(container) / @Scoped(seed: \(scope.seed).self)"
    }
}

/// The consumer's type name (or a synthetic placeholder for
/// provider-shaped consumers), used in the fix-it suggestion so the
/// user knows which declaration to change.
private func consumerTypeName(_ consumer: DiscoveredBinding) -> String {
    switch consumer {
    case .scopeBound(let scopeBound):
        return scopeBound.typeName
    case .provider(let provider):
        return provider.accessPath
    }
}

/// Build the fix-it suggestion text. When there's a single
/// binding partition, the message is tailored to the specific
/// mismatch shape:
///
/// - **Wider scope storing narrower** (e.g. `@Singleton` storing
///   `@Scoped(seed: X.self)`): scope the consumer to the same
///   seed, or extract the narrower-scope concern into a wrapper.
/// - **Different sibling seeded scopes** (e.g. `@Scoped(seed: A)`
///   storing `@Scoped(seed: B)`): the two scopes are isolated by
///   design; restructure or extract.
/// - **Cross-container mismatches**: container graphs are atomic;
///   move the binding or activate the right container.
///
/// When the binding exists in multiple partitions (none reachable
/// from the consumer), the message shifts to acknowledge the
/// multiplicity and ask the user to pick one to consolidate.
///
/// The fix-it message follows the Swift compiler's `note:` tone —
/// imperative, specific, actionable.
private func fixItSuggestion(
    consumerPartition: Partition,
    bindingPartitions: [Partition],
    consumerTypeName: String
) -> String {
    guard let bindingPartition = bindingPartitions.first else {
        // Defensive: caller doesn't invoke us with empty matches.
        return ""
    }
    // Multi-binding case: the type is bound in several partitions,
    // none reachable from the consumer. No single tailored fix-it
    // applies — the user has to pick one and consolidate.
    if bindingPartitions.count > 1 {
        return
            "'\(consumerTypeName)' can't reach any of the listed scopes; consolidate the binding into a single reachable scope or extract the cross-scope concern into a wrapper"
    }
    let bindingScopeDescription = describe(partition: bindingPartition)
    // Wider scope (singleton, container-singleton) storing a narrower
    // scoped binding from its own graph family.
    if consumerPartition.scope == nil, bindingPartition.scope != nil,
        consumerPartition.container == bindingPartition.container
    {
        return
            "scope '\(consumerTypeName)' to \(bindingScopeDescription) too, or extract the scope-bound concern into a wrapper bound at the wider scope"
    }
    // Two seeded scopes in the same container family.
    if consumerPartition.scope != nil, bindingPartition.scope != nil,
        consumerPartition.container == bindingPartition.container
    {
        return
            "sibling seeded scopes are isolated by design; restructure so '\(consumerTypeName)' lives in the same scope, or extract the cross-scope concern into a wrapper bound at the singleton level"
    }
    // Cross-container or container-vs-default mismatches: containers
    // are atomic alternates that can't compose.
    return
        "container graphs are atomic; '\(consumerTypeName)' can't reach bindings declared inside a different container — move the binding or activate the right graph"
}

/// Deterministic ordering for partitions. Sorts by `container`
/// first (nil before any named container, then alphabetical), then
/// by `scope.seed` (nil before any named seed, then alphabetical),
/// then by `scope.within` for forward compatibility with
/// hierarchical seeded scopes. Used to make the cross-scope hint
/// scan stable across runs when the binding lives in multiple
/// partitions.
private func partitionOrder(_ lhs: Partition, _ rhs: Partition) -> Bool {
    if lhs.container != rhs.container {
        return optionalStringLess(lhs.container, rhs.container)
    }
    if lhs.scope?.seed != rhs.scope?.seed {
        return optionalStringLess(lhs.scope?.seed, rhs.scope?.seed)
    }
    return optionalStringLess(lhs.scope?.within, rhs.scope?.within)
}

private func optionalStringLess(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return false
    case (nil, _): return true
    case (_, nil): return false
    case (.some(let lhsName), .some(let rhsName)): return lhsName < rhsName
    }
}
