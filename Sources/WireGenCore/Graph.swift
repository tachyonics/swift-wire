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

/// Two or more bindings claim to produce the same type, leaving the
/// graph fundamentally ambiguous about which one to use at injection
/// sites. Iteration 3's explicit-key disambiguation will let users
/// resolve this; until then it's a hard error.
package struct DuplicateBinding: Sendable {
    package let boundType: String
    package let bindings: [DiscoveredBinding]

    package init(boundType: String, bindings: [DiscoveredBinding]) {
        self.boundType = boundType
        self.bindings = bindings
    }
}

// MARK: - Graph construction

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
/// Duplicate bindings (two bindings producing the same type) cause an
/// early-exit failure: without unique bindings, downstream validation
/// (cycles, missing bindings) can't be interpreted meaningfully.
package func buildDependencyGraph(
    from bindings: [DiscoveredBinding]
) -> GraphResult {
    // Index non-generic bindings by their bound type, capturing
    // duplicates as we go. Generic bindings are deferred to `skipped`.
    var groupedByType: [String: [DiscoveredBinding]] = [:]
    var skipped: [DiscoveredBinding] = []
    for binding in bindings {
        if binding.genericParameterNames.isEmpty {
            groupedByType[binding.boundType, default: []].append(binding)
        } else {
            skipped.append(binding)
        }
    }

    // Split into uniquely-bound types vs duplicates.
    var uniqueByType: [String: DiscoveredBinding] = [:]
    var duplicates: [DuplicateBinding] = []
    for boundType in groupedByType.keys.sorted() {
        let group = groupedByType[boundType] ?? []
        if group.count == 1 {
            uniqueByType[boundType] = group[0]
        } else {
            duplicates.append(DuplicateBinding(boundType: boundType, bindings: group))
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

    // Resolve each binding's dependencies to bound types. Anything that
    // doesn't resolve is captured as a missing binding.
    var dependencyEdges: [String: [String]] = [:]
    var missingBindings: [MissingBinding] = []

    // Iterate in deterministic (sorted) order so the output is stable
    // across runs.
    for boundType in uniqueByType.keys.sorted() {
        guard let binding = uniqueByType[boundType] else { continue }
        var resolved: [String] = []
        for dependency in binding.dependencies {
            if uniqueByType[dependency.type] != nil {
                resolved.append(dependency.type)
            } else {
                missingBindings.append(
                    MissingBinding(consumer: binding, dependency: dependency)
                )
            }
        }
        dependencyEdges[boundType] = resolved
    }

    let sortResult = topologicalSort(
        nodes: uniqueByType,
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
    nodes: [String: DiscoveredBinding],
    edges: [String: [String]]
) -> (order: [DiscoveredBinding], cycles: [[DiscoveredBinding]]) {
    var state: [String: VisitState] = [:]
    for name in nodes.keys {
        state[name] = .unvisited
    }
    var order: [DiscoveredBinding] = []
    var cycles: [[DiscoveredBinding]] = []
    var seenCycleNodeSets: Set<Set<String>> = []
    var path: [String] = []

    func visit(_ node: String) {
        switch state[node] ?? .unvisited {
        case .visited:
            return
        case .visiting:
            // Found a cycle. The path from where `node` first appears in
            // the current traversal back to here is the cycle. Append
            // `node` again so the rendered path reads `A → B → A`.
            if let start = path.firstIndex(of: node) {
                let cycleNames = Array(path[start...]) + [node]
                let cycleNodeSet = Set(cycleNames)
                // Dedupe — the same cycle reached from different entry
                // points produces the same node set.
                if !seenCycleNodeSets.contains(cycleNodeSet) {
                    seenCycleNodeSets.insert(cycleNodeSet)
                    cycles.append(cycleNames.compactMap { nodes[$0] })
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

    for name in nodes.keys.sorted() {
        visit(name)
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

/// Render validation errors as a multi-line message suitable for stderr.
/// Duplicate bindings come first (they short-circuit the rest of
/// validation), then cycles, then missing bindings.
package func renderValidationErrors(_ errors: GraphResult.ValidationErrors) -> String {
    var lines: [String] = []

    if !errors.duplicateBindings.isEmpty {
        lines.append("error: duplicate binding(s):")
        for duplicate in errors.duplicateBindings {
            lines.append("  \(duplicate.boundType) is bound by \(duplicate.bindings.count) declarations:")
            for binding in duplicate.bindings {
                lines.append("    - \(displayName(binding))   (\(binding.sourcePath))")
            }
        }
    }

    if !errors.cycles.isEmpty {
        if !lines.isEmpty { lines.append("") }
        lines.append("error: dependency cycle(s) detected:")
        for cycle in errors.cycles {
            let path = cycle.map { displayName($0) }.joined(separator: " → ")
            lines.append("  \(path)")
        }
    }

    if !errors.missingBindings.isEmpty {
        if !lines.isEmpty { lines.append("") }
        lines.append("error: missing binding(s):")
        for missing in errors.missingBindings {
            // Wildcard-label dependencies (`@Inject init(_ x: Foo)`)
            // carry a nil name; render as `_` for the diagnostic so it
            // matches the source-level form and Swift's compiler doesn't
            // generate a "debug description of optional" warning.
            let depName = missing.dependency.name ?? "_"
            lines.append(
                "  \(displayName(missing.consumer)) needs \(depName): \(missing.dependency.type) — no binding produces '\(missing.dependency.type)'"
            )
        }
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
