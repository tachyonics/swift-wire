// MARK: - Graph result

/// The outcome of running graph construction over a set of discovered
/// bindings. Models the success/failure split as an enum so consumers
/// can't accidentally read a topological order from a graph that had
/// validation errors, or check `hasErrors` and forget to handle the
/// success path.
///
/// `skipped` lives at the top level alongside `outcome` because it's
/// informational (generic bindings are deferred until concrete
/// specialisation is implemented) and reported the same way regardless
/// of whether the rest of the graph validated cleanly.
package struct GraphResult: Sendable {
    package let outcome: Outcome
    package let skipped: [DiscoveredBinding]

    package init(outcome: Outcome, skipped: [DiscoveredBinding]) {
        self.outcome = outcome
        self.skipped = skipped
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

        package init(
            cycles: [[DiscoveredBinding]],
            missingBindings: [MissingBinding],
            duplicateBindings: [DuplicateBinding],
            identifierCollisions: [IdentifierCollision] = []
        ) {
            self.cycles = cycles
            self.missingBindings = missingBindings
            self.duplicateBindings = duplicateBindings
            self.identifierCollisions = identifierCollisions
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

/// One unresolved dependency — an `@Inject` parameter/property or a
/// `@Provides func` parameter whose declared type isn't satisfied by
/// any other discovered binding.
package struct MissingBinding: Sendable {
    package let consumer: DiscoveredBinding
    package let dependency: DependencyParameter
    /// Optional hint surfaced when the dependency's type matches a
    /// module-scope `typealias` whose underlying type IS bound — the
    /// user likely expected the typealias to be unwrapped at lookup.
    /// Renders as a `note:` line beneath the primary missing-binding
    /// error.
    package let typealiasHint: TypealiasHint?
    /// Optional hint surfaced when the dependency's type IS bound,
    /// but in a different scope partition than the consumer's. The
    /// most common case: a `@Singleton` `@Inject`s a `@Scoped` type
    /// directly. Renders as `note:` lines beneath the primary
    /// missing-binding error, including a fix-it suggestion.
    package let crossScopeHint: CrossScopeHint?
    /// Optional hint surfaced when the dependency went unmatched because
    /// of an *optionality* mismatch — a non-optional dependency with only
    /// an optional producer (the asymmetry), or a missing optional that
    /// still needs an explicit producer. Renders as a `note:` line.
    package let optionalMismatchHint: OptionalMismatchHint?

    package init(
        consumer: DiscoveredBinding,
        dependency: DependencyParameter,
        typealiasHint: TypealiasHint? = nil,
        crossScopeHint: CrossScopeHint? = nil,
        optionalMismatchHint: OptionalMismatchHint? = nil
    ) {
        self.consumer = consumer
        self.dependency = dependency
        self.typealiasHint = typealiasHint
        self.crossScopeHint = crossScopeHint
        self.optionalMismatchHint = optionalMismatchHint
    }
}

/// Carries the data needed to render the typealias-aware
/// missing-binding note. The note explains *why* the lookup didn't
/// match — the dependency was written with the typealias, but
/// resolution is by canonical type name and typealiases aren't
/// unwrapped (preserving the discriminator pattern where two
/// typealiases of the same underlying type are distinct slots).
package struct TypealiasHint: Sendable {
    /// The typealias's source name, as written by the consumer.
    package let typealiasName: String
    /// The underlying type that IS bound in the graph.
    package let underlyingType: String
    /// Where the typealias was declared, for the note's prefix.
    package let typealiasLocation: SourceLocation

    package init(
        typealiasName: String,
        underlyingType: String,
        typealiasLocation: SourceLocation
    ) {
        self.typealiasName = typealiasName
        self.underlyingType = underlyingType
        self.typealiasLocation = typealiasLocation
    }
}

/// Carries the data needed to render the cross-scope missing-binding
/// note + fix-it. Surfaced when a missing dependency's `(type, key)`
/// is bound in one or more partitions — just not in the consumer's
/// scope partition. The most common case is a `@Singleton` directly
/// `@Inject`ing a `@Scoped(seed:)` binding: the binding exists, but
/// in a per-seed scope the consumer can't reach without scoping
/// itself or borrowing through an appropriate wrapper.
///
/// `matches` lists every partition where the binding lives, in
/// deterministic sorted order. When only one match exists, the
/// fix-it is tailored to that specific mismatch shape (wider-vs-
/// narrower scope, sibling seeded scopes, cross-container). When
/// multiple matches exist (the type is bound in several
/// partitions, none reachable from the consumer), the fix-it
/// shifts to a multiplicity-aware message.
///
/// `consumerScopeDescription` is the human-readable scope label
/// for the consumer (`"@Singleton"`, `"@Scoped(seed: X.self)"`,
/// `"@Container Foo"`, etc.).
package struct CrossScopeHint: Sendable {
    package let matches: [Match]
    package let consumerScopeDescription: String
    package let fixItSuggestion: String

    package init(
        matches: [Match],
        consumerScopeDescription: String,
        fixItSuggestion: String
    ) {
        self.matches = matches
        self.consumerScopeDescription = consumerScopeDescription
        self.fixItSuggestion = fixItSuggestion
    }

    /// One partition where the missing dependency's type is bound.
    /// Multiple matches render as multiple `note:` lines so the
    /// user sees every place the binding lives.
    package struct Match: Sendable {
        package let scopeDescription: String
        package let location: SourceLocation

        package init(scopeDescription: String, location: SourceLocation) {
            self.scopeDescription = scopeDescription
            self.location = location
        }
    }
}

/// Two or more bindings claim the same `(type, key)` identity, leaving
/// the graph fundamentally ambiguous about which one to use at
/// injection sites. With explicit-key disambiguation, two bindings of
/// the same type with *different* keys coexist — only same `(type, key)`
/// fires this error.
package struct DuplicateBinding: Sendable {
    package let boundType: String
    /// The key identifier shared by all of the duplicates, or `nil`
    /// when they're all unkeyed. Surfaced in the diagnostic so the user
    /// sees which slot is overloaded; also drives the fix-it text
    /// (suggest adding keys when none of the duplicates carry one).
    package let keyIdentifier: String?
    package let bindings: [DiscoveredBinding]

    package init(
        boundType: String,
        keyIdentifier: String? = nil,
        bindings: [DiscoveredBinding]
    ) {
        self.boundType = boundType
        self.keyIdentifier = keyIdentifier
        self.bindings = bindings
    }
}

/// One source-pattern diagnostic surfaced by discovery or graph
/// validation. Renders to stderr in the standard
/// `file:line:col: <severity>: ...` format so build tools surface
/// it inline.
///
/// Severity controls whether the build fails:
/// - `.warning` — informational. Build proceeds normally. Used for
///   patterns Wire can work around (`@Inject` on a non-scope type,
///   `@Provides` in an unannotated extension, etc.). The default.
/// - `.error` — blocks emission. WireGen exits non-zero before
///   writing the generated file. Used for source patterns whose
///   generated code wouldn't compile or would silently produce
///   wrong results (`@Inject mutating func` on a struct, etc.).
///
/// `notes` carry related-source pointers (e.g. "also bound here"
/// secondary locations), rendered as `file:line:col: note: ...`
/// lines immediately following the diagnostic. Both follow Swift
/// compiler convention.
package struct Diagnostic: Sendable {
    package let location: SourceLocation
    package let message: String
    package let notes: [Note]
    package let severity: Severity

    package init(
        location: SourceLocation,
        message: String,
        notes: [Note] = [],
        severity: Severity = .warning
    ) {
        self.location = location
        self.message = message
        self.notes = notes
        self.severity = severity
    }

    package enum Severity: Sendable, Equatable {
        case warning
        case error
    }

    package struct Note: Sendable {
        package let location: SourceLocation
        package let message: String

        package init(location: SourceLocation, message: String) {
            self.location = location
            self.message = message
        }
    }
}

/// Two or more bindings with distinct `(type, key)` identities produce
/// the same generated accessor name (the lowerCamelCased, sanitised
/// identifier used for stored properties on `_WireGraph` and locals in
/// the bootstrap). The graph itself is unambiguous — each binding has
/// a unique identity — but codegen can't emit two `let X: T` lines with
/// the same `X`. Distinct from `DuplicateBinding` because the colliding
/// bindings are otherwise valid; only their *derived* identifier
/// collides.
package struct IdentifierCollision: Sendable {
    /// The generated accessor name shared by the colliding bindings.
    package let identifier: String
    package let bindings: [DiscoveredBinding]

    package init(identifier: String, bindings: [DiscoveredBinding]) {
        self.identifier = identifier
        self.bindings = bindings
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
    case .scopeBound(let scopeBound):
        // The specialised concrete type expression replaces both
        // `typeName` and `qualifiedTypeName` so codegen renders the
        // construction call as `Repository<DynamoDBTable>(...)` and
        // the stored-property type annotation matches.
        let concreteType = "\(scopeBound.typeName)<\(concreteArguments.joined(separator: ", "))>"
        let enclosingPrefix =
            scopeBound.qualifiedTypeName.hasSuffix(scopeBound.typeName)
            ? String(
                scopeBound.qualifiedTypeName.dropLast(scopeBound.typeName.count)
            )
            : ""
        return .scopeBound(
            DiscoveredScopeBoundType(
                typeName: concreteType,
                qualifiedTypeName: enclosingPrefix + concreteType,
                typeKind: scopeBound.typeKind,
                genericParameterNames: [],
                dependencies: substitutedDependencies,
                location: scopeBound.location,
                teardown: scopeBound.teardown
            )
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
                teardown: provider.teardown
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
    skipped: [DiscoveredBinding]
) -> GraphResult {
    GraphResult(
        outcome: .validationFailed(
            GraphResult.ValidationErrors(
                cycles: [],
                missingBindings: [],
                duplicateBindings: duplicateBindings,
                identifierCollisions: identifierCollisions
            )
        ),
        skipped: skipped
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
    let skipped = partition.skipped

    let (uniqueByIdentity, duplicates) = splitUniqueFromDuplicates(
        partition.groupedByIdentity
    )
    if !duplicates.isEmpty {
        return earlyValidationFailure(duplicateBindings: duplicates, skipped: skipped)
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
        genericBindings: partition.genericBindings
    )
    if !specialisationAmbiguities.isEmpty {
        return earlyValidationFailure(duplicateBindings: specialisationAmbiguities, skipped: skipped)
    }

    let identifierCollisions = detectIdentifierCollisions(in: resolvedBindings)
    if !identifierCollisions.isEmpty {
        return earlyValidationFailure(identifierCollisions: identifierCollisions, skipped: skipped)
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

    return GraphResult(outcome: outcome, skipped: skipped)
}

/// Bucket every discovered binding by what role it plays in graph
/// construction: concrete bindings go into `groupedByIdentity` keyed
/// by their `(type, key)` identity (duplicates within the same key
/// land in the same group for later detection); generic bindings go
/// into both `skipped` (reported as informational) and
/// `genericBindings` (specialisation candidates).
private func partitionBindings(
    _ bindings: [DiscoveredBinding]
) -> (
    groupedByIdentity: [BindingIdentity: [DiscoveredBinding]],
    skipped: [DiscoveredBinding],
    genericBindings: [DiscoveredBinding]
) {
    var groupedByIdentity: [BindingIdentity: [DiscoveredBinding]] = [:]
    var skipped: [DiscoveredBinding] = []
    var genericBindings: [DiscoveredBinding] = []
    for binding in bindings {
        if binding.genericParameterNames.isEmpty {
            groupedByIdentity[binding.identity, default: []].append(binding)
        } else {
            skipped.append(binding)
            genericBindings.append(binding)
        }
    }
    return (groupedByIdentity, skipped, genericBindings)
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
            switch matchProducer(for: dependency.identity, in: resolvedBindings) {
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
                    for: parameter.identity,
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
