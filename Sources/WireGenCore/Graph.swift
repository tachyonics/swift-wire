// MARK: - Graph result

/// The outcome of running graph construction over a set of discovered
/// bindings. Models the success/failure split as an enum so consumers
/// can't accidentally read a topological order from a graph that had
/// validation errors, or check `hasErrors` and forget to handle the
/// success path.
///
/// `genericTemplates` lives at the top level alongside `outcome` because
/// it's informational (the generic templates aren't graph nodes
/// themselves — Wire builds a concrete binding per requested
/// instantiation) and reported the same way regardless of whether the
/// rest of the graph validated cleanly.
package struct GraphResult: Sendable {
    package let outcome: Outcome
    package let genericTemplates: [DiscoveredBinding]
    /// The resolved producer adjacency — each binding's identity to the identities of the bindings that
    /// satisfy its init-time dependencies (as `resolveDependencies` computed for the topological sort).
    /// Surfaced so per-root reachability (a seed scope constructed per routed controller — M5.4.6) can BFS
    /// from a root over the real resolution rather than re-deriving edges. Empty for a failed graph.
    package let edges: [BindingIdentity: [BindingIdentity]]

    package init(
        outcome: Outcome,
        genericTemplates: [DiscoveredBinding],
        edges: [BindingIdentity: [BindingIdentity]] = [:]
    ) {
        self.outcome = outcome
        self.genericTemplates = genericTemplates
        self.edges = edges
    }

    /// Either a valid topological order (the graph constructs cleanly)
    /// or a bundle of validation errors that prevented sorting.
    package enum Outcome: Sendable {
        case success(topologicalOrder: [DiscoveredBinding])
        case validationFailed(ValidationErrors)
    }

    /// Bundles the validation errors found during graph construction.
    /// Cycles and missing bindings may both be non-empty simultaneously
    /// — a graph can have both — and we report all of them so the user
    /// fixes the whole shape in one pass. Duplicate bindings are
    /// reported alone: when a type has two bindings, the graph is
    /// fundamentally ambiguous and the rest of the validation isn't
    /// meaningful until the duplicates are resolved.
    package struct ValidationErrors: Sendable {
        package let cycles: [[DiscoveredBinding]]
        package let missingBindings: [MissingBinding]
        package let duplicateBindings: [DuplicateBinding]
        package let identifierCollisions: [IdentifierCollision]
        package let invalidGenericSingletons: [InvalidGenericSingleton]

        package init(
            cycles: [[DiscoveredBinding]],
            missingBindings: [MissingBinding],
            duplicateBindings: [DuplicateBinding],
            identifierCollisions: [IdentifierCollision] = [],
            invalidGenericSingletons: [InvalidGenericSingleton] = []
        ) {
            self.cycles = cycles
            self.missingBindings = missingBindings
            self.duplicateBindings = duplicateBindings
            self.identifierCollisions = identifierCollisions
            self.invalidGenericSingletons = invalidGenericSingletons
        }
    }
}

extension GraphResult.Outcome {
    /// The topological order, if this outcome is `.success`. `nil`
    /// otherwise — using `nil` rather than an empty array makes the
    /// either/or shape of the outcome explicit at the type level. Tests
    /// can `try #require(outcome.topologicalOrder)` to extract cleanly.
    package var topologicalOrder: [DiscoveredBinding]? {
        if case .success(let order) = self { return order }
        return nil
    }

    /// The validation errors, if this outcome is `.validationFailed`.
    /// `nil` otherwise.
    package var validationErrors: GraphResult.ValidationErrors? {
        if case .validationFailed(let errors) = self { return errors }
        return nil
    }
}

// MARK: - Graph construction
//
/// Drive the specialisation phase: walk each binding's deps, attempt
/// to specialise a generic binding for any unresolved concrete
/// instantiation, and add the resulting specialised binding to
/// `uniqueByIdentity`. Iterates until no further specialisations
/// happen — a specialised binding's deps may themselves be unresolved
/// concrete instantiations that need another round.
///
/// Scope of substitution: a dep whose type *exactly equals* one of
/// the generic binding's type-parameter names is substituted with the
/// matching concrete type. Nested forms (`Box<T>`, `[T]`, `T?`) are
/// passed through unchanged — the specialised binding inherits them
/// verbatim, and the normal missing-binding detection in the caller
/// reports an error if the resulting type isn't bound. Wider
/// substitution is deferred until a real use case justifies the
/// type-expression-rewriting machinery.
///
/// Concrete-vs-generic ambiguity: when a dep's `(type, key)` is
/// satisfied by both an existing concrete binding *and* a generic
/// candidate that could specialise to the same identity, the result
/// is a duplicate-binding error. The user disambiguates with explicit
/// keys (standard fix-it) or by removing one of the two bindings.
///
/// Iteration safety: the worklist only grows when a *new* specialised
/// binding is added (one not already in `uniqueByIdentity`), which
/// can happen at most once per `(base, param-list)` combination. The
/// number of distinct generic types in the graph is finite, so the
/// loop terminates.
private func specialiseGenericBindings(
    uniqueByIdentity: inout [BindingIdentity: DiscoveredBinding],
    genericBindings: [DiscoveredBinding]
) -> [DuplicateBinding] {
    guard !genericBindings.isEmpty else { return [] }

    var ambiguities: [DuplicateBinding] = []
    var ambiguitiesReported: Set<BindingIdentity> = []

    // Snapshot the identities the user originally wrote (concrete
    // bindings discovered in source). The specialisation loop adds
    // newly specialised bindings to `uniqueByIdentity` as it goes —
    // those are *artifacts of specialisation*, not concrete bindings
    // shadowing the generic. The ambiguity check below must only fire
    // when an entry was in the user's original set, otherwise a
    // second consumer requesting the same instantiation would falsely
    // flag the just-specialised binding as conflicting with the
    // generic it came from.
    let originallyConcrete = Set(uniqueByIdentity.keys)
    let genericSignatures = precomputedGenericSignatures(genericBindings)

    typealias WorkItem = (dep: DependencyParameter, base: String, params: [String])
    var worklist: [WorkItem] = []
    func addToWorklist(_ deps: [DependencyParameter]) {
        worklist.append(
            contentsOf: deps.map { dep in
                let parsed = parseGenericType(canonicalTypeName(dep.type))
                return (dep, parsed.base, parsed.params)
            }
        )
    }
    addToWorklist(uniqueByIdentity.values.flatMap { $0.dependencies })

    while !worklist.isEmpty {
        let (dep, base, params) = worklist.removeFirst()
        let genericCandidates = matchingGenericCandidates(
            base: base,
            paramCount: params.count,
            key: dep.keyIdentifier,
            in: genericSignatures
        )

        if let concrete = uniqueByIdentity[dep.identity] {
            // Concrete already satisfies. If a generic could also
            // satisfy the same `(type, key)` slot — *and* the
            // existing entry came from the user's original input,
            // not from an earlier specialisation in this loop — flag
            // ambiguity. Multi-consumer cases where two deps both
            // request the same specialisation share the single
            // specialised binding and skip the ambiguity check.
            if !genericCandidates.isEmpty,
                originallyConcrete.contains(dep.identity),
                !ambiguitiesReported.contains(dep.identity)
            {
                ambiguities.append(
                    DuplicateBinding(
                        boundType: dep.identity.displayType,
                        keyIdentifier: dep.identity.key,
                        bindings: [concrete] + genericCandidates
                    )
                )
                ambiguitiesReported.insert(dep.identity)
            }
            continue
        }
        guard !genericCandidates.isEmpty else { continue }
        guard genericCandidates.count == 1 else {
            // 2+ generic candidates could specialise to the same
            // `(type, key)` slot. Emit a duplicate-binding error
            // listing the candidates so the user picks one (typically
            // by adding distinct keys via the standard fix-it note).
            if !ambiguitiesReported.contains(dep.identity) {
                ambiguities.append(
                    DuplicateBinding(
                        boundType: dep.identity.displayType,
                        keyIdentifier: dep.identity.key,
                        bindings: genericCandidates
                    )
                )
                ambiguitiesReported.insert(dep.identity)
            }
            continue
        }
        let specialised = specialiseBinding(genericCandidates[0], with: params)
        if uniqueByIdentity[specialised.identity] == nil {
            uniqueByIdentity[specialised.identity] = specialised
            addToWorklist(specialised.dependencies)
        }
    }

    return ambiguities
}

/// Pre-compute `(binding, base, paramCount)` for every generic
/// binding so the per-iteration candidate filter doesn't redo the
/// signature extraction. `compactMap` drops bindings with no
/// signature (shouldn't happen — non-generic bindings don't reach
/// here — but defensive).
private func precomputedGenericSignatures(
    _ genericBindings: [DiscoveredBinding]
) -> [(binding: DiscoveredBinding, base: String, paramCount: Int)] {
    genericBindings.compactMap { binding in
        guard let signature = genericBindingSignature(binding) else { return nil }
        return (binding, signature.base, signature.paramCount)
    }
}

/// Return the generic bindings whose signature matches `(base,
/// paramCount, key)`. Keys partition the binding space — a keyed
/// `@Provides(key) func make<T>() ...` only satisfies keyed consumers
/// requesting the same key, and an unkeyed generic only satisfies
/// unkeyed consumers. Same partition rule as the regular `(type, key)`
/// identity match.
private func matchingGenericCandidates(
    base: String,
    paramCount: Int,
    key: String?,
    in signatures: [(binding: DiscoveredBinding, base: String, paramCount: Int)]
) -> [DiscoveredBinding] {
    guard paramCount > 0 else { return [] }
    return
        signatures
        .filter { entry in
            entry.base == base
                && entry.paramCount == paramCount
                && entry.binding.keyIdentifier == key
        }
        .map { $0.binding }
}

/// Extract the (base name, parameter count) signature of a generic
/// binding for specialisation matching. For `@Singleton` types the
/// base is the bare `typeName` and the params come from
/// `genericParameterNames`. For `@Provides` functions the base is
/// parsed out of the (parameter-bearing) `boundType` expression.
/// Returns `nil` for non-generic bindings.
private func genericBindingSignature(
    _ binding: DiscoveredBinding
) -> (base: String, paramCount: Int)? {
    guard !binding.genericParameterNames.isEmpty else { return nil }
    switch binding {
    case .scopeBound(let scopeBound):
        return (scopeBound.typeName, binding.genericParameterNames.count)
    case .provider(let provider):
        let parsed = parseGenericType(canonicalTypeName(provider.boundType))
        return (parsed.base, binding.genericParameterNames.count)
    case .aggregate:
        // Aggregates are never generic — the guard above already
        // returns nil for them; this case only satisfies exhaustiveness.
        return nil
    }
}

/// Substitute the generic binding's type parameters with the
/// `concreteArguments` and return a new binding ready for the graph.
/// `genericParameterNames` is cleared on the result so the binding
/// looks concrete to the rest of the pipeline (codegen, topological
/// sort, missing-binding detection).
///
/// Substitution rule: a dep whose `type` *exactly equals* one of the
/// generic parameter names becomes the matching concrete type.
/// Anything else passes through unchanged.
private func specialiseBinding(
    _ binding: DiscoveredBinding,
    with concreteArguments: [String]
) -> DiscoveredBinding {
    let parameterNames = binding.genericParameterNames
    let substitutions = Dictionary(
        uniqueKeysWithValues: zip(parameterNames, concreteArguments)
    )
    let substitutedDependencies = binding.dependencies.map { dep -> DependencyParameter in
        guard let replacement = substitutions[dep.type] else { return dep }
        return DependencyParameter(
            name: dep.name,
            type: replacement,
            kind: dep.kind,
            location: dep.location,
            keyIdentifier: dep.keyIdentifier
        )
    }
    switch binding {
    case .scopeBound:
        // Generic `@Singleton`s are lift nodes or errors (see
        // `partitionBindings`), never specialise templates, so they never reach
        // here — only generic `@Provides func` factories do.
        preconditionFailure(
            "generic @Singleton reached specialiseBinding; it should be a lift node or an error"
        )
    case .provider(let provider):
        // For functions, splice the concrete arguments at the call
        // site via `concreteGenericArguments` and update `boundType`
        // to the concrete instantiation so identity matching picks
        // up the specialised binding.
        let parsedReturn = parseGenericType(canonicalTypeName(provider.boundType))
        let concreteType = "\(parsedReturn.base)<\(concreteArguments.joined(separator: ", "))>"
        return .provider(
            DiscoveredProvider(
                boundType: concreteType,
                accessPath: provider.accessPath,
                form: provider.form,
                dependencies: substitutedDependencies,
                genericParameterNames: [],
                location: provider.location,
                keyIdentifier: provider.keyIdentifier,
                concreteGenericArguments: provider.form == .function
                    ? concreteArguments
                    : [],
                scopeKey: provider.scopeKey,
                teardown: provider.teardown,
                originModule: provider.originModule
            )
        )
    case .aggregate:
        // Aggregates are never generic, so never specialised; only
        // present for exhaustiveness.
        return binding
    }
}

/// Decompose a type expression into its base name and generic-argument
/// list. Used by generic-specialisation matching to identify candidate
/// generic bindings for a given concrete instantiation.
///
///     "Repository"                 → ("Repository", [])
///     "Repository<DynamoDBTable>"  → ("Repository", ["DynamoDBTable"])
///     "Pair<A, B>"                 → ("Pair", ["A", "B"])
///     "Box<Pair<X, Y>>"            → ("Box", ["Pair<X,Y>"])
///
/// Bracket depth counted so nested generics in a parameter slot are
/// kept intact. Commas at depth 0 split the parameter list. Whitespace
/// is canonicalised away as a side effect — the inputs `Pair<A, B>`
/// and `Pair<A,B>` parse to the same `(base, params)` pair.
///
/// Malformed input (unbalanced brackets, etc.) returns whatever was
/// accumulated so far. The build plugin trusts its inputs to be parsed
/// Swift type expressions and doesn't need to validate.
private func parseGenericType(_ expression: String) -> (base: String, params: [String]) {
    let canonical = canonicalTypeName(expression)
    guard let openIndex = canonical.firstIndex(of: "<") else {
        return (canonical, [])
    }
    let base = String(canonical[..<openIndex])
    let innerStart = canonical.index(after: openIndex)
    var params: [String] = []
    var current = ""
    var depth = 0
    for char in canonical[innerStart...] {
        switch char {
        case "<":
            depth += 1
            current.append(char)
        case ">" where depth == 0:
            // Matching close — finalise the current param (if any)
            // and return. Any trailing characters after this `>` are
            // ignored; well-formed type expressions don't have them.
            if !current.isEmpty { params.append(current) }
            return (base, params)
        case ">":
            depth -= 1
            current.append(char)
        case "," where depth == 0:
            params.append(current)
            current = ""
        default:
            current.append(char)
        }
    }
    // Unbalanced brackets — return what we have.
    if !current.isEmpty { params.append(current) }
    return (base, params)
}

/// Build the dependency graph from the discovered bindings, run a
/// topological sort, and surface any validation problems found along
/// the way.
///
/// Generic bindings — `@Singleton` types with type parameters or
/// `@Provides` functions with type parameters — are excluded from the
/// graph. Their dependencies typically reference generic type
/// parameters rather than concrete types, which the type-name-keyed
/// graph can't resolve cleanly. Concrete specialisation is deferred
/// until a separate substitution pass is implemented.
///
/// Duplicate bindings (two bindings producing the same `(type, key)`
/// identity) cause an early-exit failure: without unique bindings, the
/// rest of validation isn't trustworthy.
/// A pre-resolution validation failure (duplicate bindings,
/// specialisation ambiguities, or identifier collisions) — each aborts
/// before dependency resolution, so cycles/missing-bindings are empty.
private func earlyValidationFailure(
    duplicateBindings: [DuplicateBinding] = [],
    identifierCollisions: [IdentifierCollision] = [],
    invalidGenericSingletons: [InvalidGenericSingleton] = [],
    genericTemplates: [DiscoveredBinding]
) -> GraphResult {
    GraphResult(
        outcome: .validationFailed(
            GraphResult.ValidationErrors(
                cycles: [],
                missingBindings: [],
                duplicateBindings: duplicateBindings,
                identifierCollisions: identifierCollisions,
                invalidGenericSingletons: invalidGenericSingletons
            )
        ),
        genericTemplates: genericTemplates
    )
}

package func buildDependencyGraph(
    from bindings: [DiscoveredBinding],
    typealiases: [DiscoveredTypealias] = [],
    multibindingKeys: [DiscoveredMultibindingKey] = [],
    resultBuilders: [DiscoveredResultBuilder] = []
) -> GraphResult {
    // Fan-in: turn each declared multibinding key into a synthesised
    // aggregate binding (deps = its contributors). Aggregates then flow
    // through the rest of the pipeline as ordinary bindings.
    let allBindings =
        bindings
        + synthesizeAggregates(
            keys: multibindingKeys,
            bindings: bindings,
            resultBuilders: resultBuilders
        )
    let partition = partitionBindings(allBindings)
    let genericTemplates = partition.genericTemplates

    if !partition.invalidGenericSingletons.isEmpty {
        return earlyValidationFailure(
            invalidGenericSingletons: partition.invalidGenericSingletons,
            genericTemplates: genericTemplates
        )
    }

    let (uniqueByIdentity, duplicates) = splitUniqueFromDuplicates(
        partition.groupedByIdentity
    )
    if !duplicates.isEmpty {
        return earlyValidationFailure(duplicateBindings: duplicates, genericTemplates: genericTemplates)
    }

    // Generic specialisation: walk every binding's deps; for each
    // unresolved concrete-instantiation dep (a dep whose type is
    // something like `Repository<DynamoDBTable>`), look for a generic
    // binding whose (base, param count) matches. Exactly one match →
    // specialise (substitute the type parameters through the
    // binding's deps) and add the specialised binding to the graph.
    // When the same `(type, key)` is satisfied by both an existing
    // concrete binding and a generic-specialisation candidate, the
    // result is a duplicate-binding error; the standard fix-it
    // (declare named keys) handles disambiguation.
    var resolvedBindings = uniqueByIdentity
    let specialisationAmbiguities = specialiseGenericBindings(
        uniqueByIdentity: &resolvedBindings,
        genericBindings: genericTemplates
    )
    if !specialisationAmbiguities.isEmpty {
        return earlyValidationFailure(
            duplicateBindings: specialisationAmbiguities,
            genericTemplates: genericTemplates
        )
    }

    let identifierCollisions = detectIdentifierCollisions(in: resolvedBindings)
    if !identifierCollisions.isEmpty {
        return earlyValidationFailure(
            identifierCollisions: identifierCollisions,
            genericTemplates: genericTemplates
        )
    }

    let (dependencyEdges, missingBindings) = resolveDependencies(
        in: resolvedBindings,
        typealiases: typealiases
    )

    let sortResult = topologicalSort(
        nodes: resolvedBindings,
        edges: dependencyEdges
    )

    let outcome: GraphResult.Outcome
    if sortResult.cycles.isEmpty && missingBindings.isEmpty {
        outcome = .success(topologicalOrder: sortResult.order)
    } else {
        outcome = .validationFailed(
            GraphResult.ValidationErrors(
                cycles: sortResult.cycles,
                missingBindings: missingBindings,
                duplicateBindings: []
            )
        )
    }

    return GraphResult(outcome: outcome, genericTemplates: genericTemplates, edges: dependencyEdges)
}

/// Bucket every discovered binding by what role it plays in graph
/// construction: concrete bindings go into `groupedByIdentity` keyed
/// by their `(type, key)` identity (duplicates within the same key
/// land in the same group for later detection); generic bindings go
/// into `genericTemplates`, which both seeds specialisation and is
/// reported as informational.
private func partitionBindings(
    _ bindings: [DiscoveredBinding]
) -> (
    groupedByIdentity: [BindingIdentity: [DiscoveredBinding]],
    genericTemplates: [DiscoveredBinding],
    invalidGenericSingletons: [InvalidGenericSingleton]
) {
    var groupedByIdentity: [BindingIdentity: [DiscoveredBinding]] = [:]
    var genericTemplates: [DiscoveredBinding] = []
    var invalidGenericSingletons: [InvalidGenericSingleton] = []
    for binding in bindings {
        // A lift node — `@Singleton(as:)` or a determined generic `@Singleton` —
        // is a real graph node even when generic, keyed by its opaque/structural
        // identity, so it joins the resolved set rather than the template pool.
        if binding.genericParameterNames.isEmpty || binding.isLiftNode {
            groupedByIdentity[binding.identity, default: []].append(binding)
        } else if case .scopeBound = binding {
            // A generic `@Singleton` that isn't a lift node can't be a single
            // instance (an undetermined parameter would vary per use) — an error,
            // not a specialise template.
            invalidGenericSingletons.append(
                InvalidGenericSingleton(
                    binding: binding,
                    undeterminedParameters: binding.undeterminedGenericParameters
                )
            )
        } else {
            // Generic `@Provides func` — the parameterised factory; specialised.
            genericTemplates.append(binding)
        }
    }
    return (groupedByIdentity, genericTemplates, invalidGenericSingletons)
}

/// Split a grouped-by-identity map into uniquely-bound identities
/// vs identities with multiple bindings. Iterates in sorted key
/// order so the duplicates list is stable across runs.
private func splitUniqueFromDuplicates(
    _ groupedByIdentity: [BindingIdentity: [DiscoveredBinding]]
) -> (
    unique: [BindingIdentity: DiscoveredBinding],
    duplicates: [DuplicateBinding]
) {
    var unique: [BindingIdentity: DiscoveredBinding] = [:]
    var duplicates: [DuplicateBinding] = []
    for identity in groupedByIdentity.keys.sorted() {
        let group = groupedByIdentity[identity] ?? []
        if group.count == 1 {
            unique[identity] = group[0]
        } else {
            duplicates.append(
                DuplicateBinding(
                    boundType: identity.displayType,
                    keyIdentifier: identity.key,
                    bindings: group
                )
            )
        }
    }
    return (unique, duplicates)
}

/// Group the resolved bindings by their generated accessor name and
/// report any group with more than one entry as a collision. Catches
/// the residual case where two bindings with distinct `(type, key)`
/// identities happen to sanitise to the same identifier — `Keyed`
/// infix + type-derived naming makes this rare but not impossible
/// (e.g. an adversarial `struct DatabaseKeyedDatabasePrimary` next to
/// a `@Provides(Database.primary) Database` binding). Catching the
/// case at graph-validation time produces a Wire diagnostic at user
/// source rather than letting Swift's "invalid redeclaration" fire
/// on the generated file.
private func detectIdentifierCollisions(
    in bindings: [BindingIdentity: DiscoveredBinding]
) -> [IdentifierCollision] {
    var groupedByIdentifier: [String: [DiscoveredBinding]] = [:]
    for binding in bindings.values {
        let name = identifierName(forType: binding.boundType, key: binding.keyIdentifier)
        groupedByIdentifier[name, default: []].append(binding)
    }
    return
        groupedByIdentifier
        .filter { $0.value.count > 1 }
        .sorted { $0.key < $1.key }
        .map { identifier, group in
            IdentifierCollision(identifier: identifier, bindings: group)
        }
}

/// Resolve each binding's dependencies to `(type, key)` identities
/// against the resolved binding set. Identities not present in the
/// set are captured as missing bindings. Iteration order is sorted
/// for deterministic output.
///
/// `typealiases` is the module-wide map of module-scope typealiases.
/// When a missing binding's type matches a typealias whose underlying
/// type IS in the resolved set, attach a `TypealiasHint` so the
/// diagnostic can point at the underlying type. Typealiases are not
/// unwrapped during resolution itself — only used to enrich the error.
private func resolveDependencies(
    in resolvedBindings: [BindingIdentity: DiscoveredBinding],
    typealiases: [DiscoveredTypealias]
) -> (
    edges: [BindingIdentity: [BindingIdentity]],
    missing: [MissingBinding]
) {
    let typealiasByName = Dictionary(
        typealiases.map { ($0.name, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    var edges: [BindingIdentity: [BindingIdentity]] = [:]
    var missing: [MissingBinding] = []
    for identity in resolvedBindings.keys.sorted() {
        guard let binding = resolvedBindings[identity] else { continue }
        var resolved: [BindingIdentity] = []
        // Init-time deps: form graph edges (drive topo sort and
        // cycle detection). Missing ones produce errors.
        for dependency in binding.dependencies {
            // A scope-entry thunk is synthesised inline (a closure), not produced by a binding — so it
            // forms no edge and is never "missing". Its ordering is carried by the proxy's `.scopeCapture`
            // deps instead. See `DependencyKind.scopeEntryThunk`.
            if dependency.kind == .scopeEntryThunk { continue }
            switch matchProducer(
                for: bridgedDependencyIdentity(dependency, in: binding),
                in: resolvedBindings
            ) {
            case .resolved(let producerIdentity):
                // May differ from the dependency's own identity under
                // promotion (a `T?` dep resolves to the `T` producer);
                // the edge must point at the actual producer node.
                resolved.append(producerIdentity)
            case .missing(let optionalHint):
                missing.append(
                    MissingBinding(
                        consumer: binding,
                        dependency: dependency,
                        typealiasHint: typealiasHintFor(
                            dependency: dependency,
                            typealiasByName: typealiasByName,
                            resolvedBindings: resolvedBindings
                        ),
                        optionalMismatchHint: optionalHint
                    )
                )
            }
        }
        // Member injection parameters (`@Inject weak var` sugar +
        // `@Inject func`): post-init delivery, so excluded from
        // graph edges. Cycle through these is legal (the canonical
        // use case for cycle-breaking). Missing-binding detection
        // still applies — an unbound member-injection target is
        // the same diagnostic a missing init-time dep would
        // produce. See Documentation/Notes/WeakInjectionSupport.md
        // for the design depth.
        for injection in binding.memberInjections {
            for parameter in injection.parameters {
                if case .missing(let optionalHint) = matchProducer(
                    for: bridgedDependencyIdentity(parameter, in: binding),
                    in: resolvedBindings
                ) {
                    missing.append(
                        MissingBinding(
                            consumer: binding,
                            dependency: parameter,
                            typealiasHint: typealiasHintFor(
                                dependency: parameter,
                                typealiasByName: typealiasByName,
                                resolvedBindings: resolvedBindings
                            ),
                            optionalMismatchHint: optionalHint
                        )
                    )
                }
            }
        }
        edges[identity] = resolved
    }
    return (edges, missing)
}

/// Build a `TypealiasHint` for a missing dependency when its type
/// matches a known typealias name AND the typealias's underlying
/// type IS bound under the same key. Returns `nil` otherwise.
private func typealiasHintFor(
    dependency: DependencyParameter,
    typealiasByName: [String: DiscoveredTypealias],
    resolvedBindings: [BindingIdentity: DiscoveredBinding]
) -> TypealiasHint? {
    guard let typealiasDecl = typealiasByName[dependency.type] else { return nil }
    let underlyingSplit = optionalityStripped(canonicalTypeName(typealiasDecl.underlyingType))
    let underlyingIdentity = BindingIdentity(
        base: underlyingSplit.base,
        isOptional: underlyingSplit.isOptional,
        key: dependency.keyIdentifier
    )
    guard resolvedBindings[underlyingIdentity] != nil else { return nil }
    return TypealiasHint(
        typealiasName: typealiasDecl.name,
        underlyingType: typealiasDecl.underlyingType,
        typealiasLocation: typealiasDecl.location
    )
}

// MARK: - Topological sort

/// Internal traversal state for the DFS-based topo sort.
private enum VisitState {
    case unvisited
    case visiting
    case visited
}

/// DFS-based topological sort with cycle detection. Returns:
/// - `order`: dependency-first ordering of the input nodes
/// - `cycles`: every distinct cycle found, each as a path `A → … → A`
///
/// When cycles are present, the order is best-effort — cycle members
/// still appear in it, but their relative order isn't meaningful.
/// `buildDependencyGraph` discards this best-effort order via the enum
/// outcome when validation errors exist; the order is only surfaced on
/// success.
private func topologicalSort(
    nodes: [BindingIdentity: DiscoveredBinding],
    edges: [BindingIdentity: [BindingIdentity]]
) -> (order: [DiscoveredBinding], cycles: [[DiscoveredBinding]]) {
    var state: [BindingIdentity: VisitState] = [:]
    for identity in nodes.keys {
        state[identity] = .unvisited
    }
    var order: [DiscoveredBinding] = []
    var cycles: [[DiscoveredBinding]] = []
    var seenCycleIdentitySets: Set<Set<BindingIdentity>> = []
    var path: [BindingIdentity] = []

    func visit(_ node: BindingIdentity) {
        switch state[node] ?? .unvisited {
        case .visited:
            return
        case .visiting:
            // Found a cycle. The path from where `node` first appears in
            // the current traversal back to here is the cycle. Append
            // `node` again so the rendered path reads `A → B → A`.
            if let start = path.firstIndex(of: node) {
                let cyclePath = Array(path[start...]) + [node]
                let cycleNodeSet = Set(cyclePath)
                // Dedupe — the same cycle reached from different entry
                // points produces the same node set.
                if !seenCycleIdentitySets.contains(cycleNodeSet) {
                    seenCycleIdentitySets.insert(cycleNodeSet)
                    cycles.append(cyclePath.compactMap { nodes[$0] })
                }
            }
            return
        case .unvisited:
            break
        }

        state[node] = .visiting
        path.append(node)
        for neighbour in edges[node] ?? [] {
            visit(neighbour)
        }
        path.removeLast()
        state[node] = .visited
        if let binding = nodes[node] {
            order.append(binding)
        }
    }

    for identity in nodes.keys.sorted() {
        visit(identity)
    }

    return (order: order, cycles: cycles)
}
