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

        package init(
            cycles: [[DiscoveredBinding]],
            missingBindings: [MissingBinding],
            duplicateBindings: [DuplicateBinding]
        ) {
            self.cycles = cycles
            self.missingBindings = missingBindings
            self.duplicateBindings = duplicateBindings
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

    package init(consumer: DiscoveredBinding, dependency: DependencyParameter) {
        self.consumer = consumer
        self.dependency = dependency
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

// MARK: - Graph construction

/// Compound identity for a binding — `(boundType, keyIdentifier?)`.
/// Two bindings with the same `type` but different `key`s coexist; same
/// `type` and same `key` are duplicates. Unkeyed deps (`key == nil`)
/// match only unkeyed bindings; keyed deps match only same-key bindings
/// — keys partition the binding space (Dagger semantics).
private struct BindingIdentity: Hashable, Comparable {
    let type: String
    let key: String?

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.type != rhs.type { return lhs.type < rhs.type }
        // Unkeyed sorts before any keyed identity; among keyed, sort
        // by key text. `nil` and `""` would otherwise compare as
        // equivalent under a `?? ""` coalesce while being distinct
        // under the auto-synthesised `Hashable`, leading to undefined
        // sort order between them if both ever appeared in the same
        // collection.
        switch (lhs.key, rhs.key) {
        case (nil, nil): return false
        case (nil, _?): return true
        case (_?, nil): return false
        case let (l?, r?): return l < r
        }
    }
}

extension DiscoveredBinding {
    fileprivate var identity: BindingIdentity {
        BindingIdentity(type: boundType, key: keyIdentifier)
    }
}

extension DependencyParameter {
    fileprivate var identity: BindingIdentity {
        BindingIdentity(type: type, key: keyIdentifier)
    }
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
package func buildDependencyGraph(
    from bindings: [DiscoveredBinding]
) -> GraphResult {
    // Index non-generic bindings by their (type, key) identity,
    // capturing duplicates as we go. Generic bindings are deferred to
    // `skipped`.
    var groupedByIdentity: [BindingIdentity: [DiscoveredBinding]] = [:]
    var skipped: [DiscoveredBinding] = []
    for binding in bindings {
        if binding.genericParameterNames.isEmpty {
            groupedByIdentity[binding.identity, default: []].append(binding)
        } else {
            skipped.append(binding)
        }
    }

    // Split into uniquely-bound identities vs duplicates.
    var uniqueByIdentity: [BindingIdentity: DiscoveredBinding] = [:]
    var duplicates: [DuplicateBinding] = []
    for identity in groupedByIdentity.keys.sorted() {
        let group = groupedByIdentity[identity] ?? []
        if group.count == 1 {
            uniqueByIdentity[identity] = group[0]
        } else {
            duplicates.append(
                DuplicateBinding(
                    boundType: identity.type,
                    keyIdentifier: identity.key,
                    bindings: group
                )
            )
        }
    }

    // Duplicates short-circuit graph validation — without unique
    // bindings the rest of the diagnostics aren't trustworthy.
    if !duplicates.isEmpty {
        return GraphResult(
            outcome: .validationFailed(
                GraphResult.ValidationErrors(
                    cycles: [],
                    missingBindings: [],
                    duplicateBindings: duplicates
                )
            ),
            skipped: skipped
        )
    }

    // Resolve each binding's dependencies to a `(type, key)` identity.
    // Anything that doesn't resolve is captured as a missing binding.
    var dependencyEdges: [BindingIdentity: [BindingIdentity]] = [:]
    var missingBindings: [MissingBinding] = []

    // Iterate in deterministic (sorted) order so the output is stable
    // across runs.
    for identity in uniqueByIdentity.keys.sorted() {
        guard let binding = uniqueByIdentity[identity] else { continue }
        var resolved: [BindingIdentity] = []
        for dependency in binding.dependencies {
            let depIdentity = dependency.identity
            if uniqueByIdentity[depIdentity] != nil {
                resolved.append(depIdentity)
            } else {
                missingBindings.append(
                    MissingBinding(consumer: binding, dependency: dependency)
                )
            }
        }
        dependencyEdges[identity] = resolved
    }

    let sortResult = topologicalSort(
        nodes: uniqueByIdentity,
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

// MARK: - Rendering

/// Render the topological order as a numbered human-readable list,
/// suitable for diagnostics and the discovery report. The same order
/// is what code emission iterates over to construct each binding.
package func renderTopologicalOrder(_ order: [DiscoveredBinding]) -> String {
    var lines: [String] = []
    lines.append("topological order (\(order.count) binding(s)):")
    if order.isEmpty {
        lines.append("  (graph is empty)")
    } else {
        for (index, binding) in order.enumerated() {
            lines.append("  \(index + 1). \(displayName(binding))")
        }
    }
    return lines.joined(separator: "\n")
}

/// Render skipped bindings (generic types pending concrete
/// specialisation support) as a short notice, suppressed entirely when
/// none were skipped.
package func renderSkipped(_ skipped: [DiscoveredBinding]) -> String {
    guard !skipped.isEmpty else { return "" }
    var lines: [String] = []
    lines.append("skipped (generic types — concrete specialisation not yet supported):")
    for binding in skipped {
        let generics = "<\(binding.genericParameterNames.joined(separator: ", "))>"
        lines.append("  \(displayName(binding))\(generics)")
    }
    return lines.joined(separator: "\n")
}

/// Render validation errors in the Swift-compiler `file:line:col: error:`
/// form — one diagnostic per line, no grouping headers. The format is
/// what Xcode and other build-log consumers expect; positions link back
/// to the originating source. Duplicate bindings come first (they
/// short-circuit the rest of validation), then cycles, then missing
/// bindings; within each category, entries are emitted in the order the
/// validator produced them.
package func renderValidationErrors(_ errors: GraphResult.ValidationErrors) -> String {
    var lines: [String] = []

    // Duplicate bindings: one error at the first binding's location,
    // notes at the remaining bindings. When the duplicates are all
    // unkeyed, append a fix-it note pointing at the key-disambiguation
    // pattern. Keyed duplicates already named their key, so the user
    // knows which slot is overloaded — no need to suggest keying.
    for duplicate in errors.duplicateBindings {
        guard let primary = duplicate.bindings.first else { continue }
        let typeSlot = describeTypeSlot(
            boundType: duplicate.boundType,
            key: duplicate.keyIdentifier
        )
        lines.append(
            "\(primary.location.formattedPrefix): error: type \(typeSlot) has multiple bindings; the dependency graph is ambiguous"
        )
        for binding in duplicate.bindings.dropFirst() {
            lines.append(
                "\(binding.location.formattedPrefix): note: also bound here"
            )
        }
        if duplicate.keyIdentifier == nil {
            lines.append(
                "\(primary.location.formattedPrefix): note: to disambiguate, declare named keys (e.g. `static let primary = BindingKey<\(duplicate.boundType)>()`) and tag each binding/consumer with `@Provides(\(duplicate.boundType).primary)` / `@Inject(\(duplicate.boundType).primary)`"
            )
        }
    }

    // Cycles: anchor at the first node in the cycle path. The arrow-
    // separated render reads as "A → B → A" so the user can see the
    // edges at a glance.
    for cycle in errors.cycles {
        guard let anchor = cycle.first else { continue }
        let path = cycle.map { displayName($0) }.joined(separator: " → ")
        lines.append(
            "\(anchor.location.formattedPrefix): error: dependency cycle: \(path)"
        )
    }

    // Missing bindings: anchor at the dependency site (the `@Inject`
    // property/parameter or the `@Provides func` parameter that asked
    // for the type), so the diagnostic lands where the user asked for
    // the missing thing. The consumer's identity is implied by the
    // position — we follow Swift compiler convention and keep the
    // message self-contained rather than restating "(required by 'X')".
    for missing in errors.missingBindings {
        let slot = describeTypeSlot(
            boundType: missing.dependency.type,
            key: missing.dependency.keyIdentifier
        )
        lines.append(
            "\(missing.dependency.location.formattedPrefix): error: no binding produces \(slot)"
        )
    }

    return lines.joined(separator: "\n")
}

/// The short identifier to show for a binding in human-facing output:
/// the type name for `@Singleton`, the access path for `@Provides`.
private func displayName(_ binding: DiscoveredBinding) -> String {
    switch binding {
    case .singleton(let singleton): return singleton.typeName
    case .provider(let provider): return provider.accessPath
    }
}

/// Human-facing description of a `(type, key)` slot in the graph. Used
/// in both missing-binding and duplicate-binding diagnostics so the
/// rendering is consistent and keyed slots are clearly named.
///
/// - Unkeyed: `'Database'`
/// - Keyed:   `'Database' keyed 'Database.primary'`
private func describeTypeSlot(boundType: String, key: String?) -> String {
    if let key {
        return "'\(boundType)' keyed '\(key)'"
    }
    return "'\(boundType)'"
}
