// MARK: - Graph result

/// The outcome of running graph construction over a set of discovered
/// singletons. Models the success/failure split as an enum so consumers
/// can't accidentally read a topological order from a graph that had
/// cycles, or check `hasErrors` and forget to handle the success path.
///
/// `skipped` lives at the top level alongside `outcome` because it's
/// informational (generic singletons are deferred until concrete
/// specialisation is implemented) and reported the same way regardless
/// of whether the rest of the graph validated cleanly.
package struct GraphResult: Sendable {
    package let outcome: Outcome
    package let skipped: [DiscoveredSingleton]

    package init(outcome: Outcome, skipped: [DiscoveredSingleton]) {
        self.outcome = outcome
        self.skipped = skipped
    }

    /// Either a valid topological order (the graph constructs cleanly)
    /// or a bundle of validation errors that prevented sorting.
    package enum Outcome: Sendable {
        case success(topologicalOrder: [DiscoveredSingleton])
        case validationFailed(ValidationErrors)
    }

    /// Bundles the validation errors found during graph construction.
    /// Both lists may be non-empty simultaneously — a graph can have
    /// both cycles and missing bindings — and we report all of them so
    /// the user fixes the whole shape in one pass rather than one
    /// problem per iteration.
    package struct ValidationErrors: Sendable {
        package let cycles: [[DiscoveredSingleton]]
        package let missingBindings: [MissingBinding]

        package init(
            cycles: [[DiscoveredSingleton]],
            missingBindings: [MissingBinding]
        ) {
            self.cycles = cycles
            self.missingBindings = missingBindings
        }
    }
}

extension GraphResult.Outcome {
    /// The topological order, if this outcome is `.success`. `nil`
    /// otherwise — using `nil` rather than an empty array makes the
    /// either/or shape of the outcome explicit at the type level. Tests
    /// can `try #require(outcome.topologicalOrder)` to extract cleanly.
    package var topologicalOrder: [DiscoveredSingleton]? {
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

/// One unresolved dependency — a `@Singleton`'s `@Inject` parameter or
/// property whose declared type isn't satisfied by any other discovered
/// `@Singleton`.
package struct MissingBinding: Sendable {
    package let consumer: DiscoveredSingleton
    package let dependency: DependencyParameter

    package init(consumer: DiscoveredSingleton, dependency: DependencyParameter) {
        self.consumer = consumer
        self.dependency = dependency
    }
}

// MARK: - Graph construction

/// Build the dependency graph from the discovered singletons, run a
/// topological sort, and surface any validation problems found along
/// the way.
///
/// Generic singletons (those with one or more generic parameters) are
/// excluded from the graph. Their dependencies typically reference
/// generic type parameters rather than concrete types, which the
/// type-name-keyed graph can't resolve cleanly. Concrete specialisation
/// is deferred until a separate substitution pass is implemented.
package func buildDependencyGraph(
    from singletons: [DiscoveredSingleton]
) -> GraphResult {
    // Index non-generic singletons by their type name for O(1) lookup.
    // Generic singletons are deferred via the `skipped` bucket.
    var indexedByName: [String: DiscoveredSingleton] = [:]
    var skipped: [DiscoveredSingleton] = []
    for singleton in singletons {
        if singleton.genericParameterNames.isEmpty {
            indexedByName[singleton.typeName] = singleton
        } else {
            skipped.append(singleton)
        }
    }

    // Resolve each singleton's dependencies to type names. Anything that
    // doesn't resolve is captured as a missing binding.
    var dependencyEdges: [String: [String]] = [:]
    var missingBindings: [MissingBinding] = []

    // Iterate in deterministic (sorted) order so the output is stable
    // across runs.
    for typeName in indexedByName.keys.sorted() {
        guard let singleton = indexedByName[typeName] else { continue }
        var resolved: [String] = []
        for dependency in singleton.dependencies {
            if indexedByName[dependency.type] != nil {
                resolved.append(dependency.type)
            } else {
                missingBindings.append(
                    MissingBinding(consumer: singleton, dependency: dependency)
                )
            }
        }
        dependencyEdges[typeName] = resolved
    }

    let sortResult = topologicalSort(
        nodes: indexedByName,
        edges: dependencyEdges
    )

    let outcome: GraphResult.Outcome
    if sortResult.cycles.isEmpty && missingBindings.isEmpty {
        outcome = .success(topologicalOrder: sortResult.order)
    } else {
        outcome = .validationFailed(
            GraphResult.ValidationErrors(
                cycles: sortResult.cycles,
                missingBindings: missingBindings
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
    nodes: [String: DiscoveredSingleton],
    edges: [String: [String]]
) -> (order: [DiscoveredSingleton], cycles: [[DiscoveredSingleton]]) {
    var state: [String: VisitState] = [:]
    for name in nodes.keys {
        state[name] = .unvisited
    }
    var order: [DiscoveredSingleton] = []
    var cycles: [[DiscoveredSingleton]] = []
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
        if let singleton = nodes[node] {
            order.append(singleton)
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
package func renderTopologicalOrder(_ order: [DiscoveredSingleton]) -> String {
    var lines: [String] = []
    lines.append("topological order (\(order.count) singleton(s)):")
    if order.isEmpty {
        lines.append("  (graph is empty)")
    } else {
        for (index, singleton) in order.enumerated() {
            lines.append("  \(index + 1). \(singleton.typeName)")
        }
    }
    return lines.joined(separator: "\n")
}

/// Render skipped singletons (generic types pending concrete
/// specialisation support) as a short notice, suppressed entirely when
/// none were skipped.
package func renderSkipped(_ skipped: [DiscoveredSingleton]) -> String {
    guard !skipped.isEmpty else { return "" }
    var lines: [String] = []
    lines.append("skipped (generic types — concrete specialisation not yet supported):")
    for singleton in skipped {
        let generics = "<\(singleton.genericParameterNames.joined(separator: ", "))>"
        lines.append("  \(singleton.typeName)\(generics)")
    }
    return lines.joined(separator: "\n")
}

/// Render validation errors as a multi-line message suitable for stderr.
/// Cycles come first (graph-shape problems take precedence over
/// missing-binding problems), then missing bindings.
package func renderValidationErrors(_ errors: GraphResult.ValidationErrors) -> String {
    var lines: [String] = []

    if !errors.cycles.isEmpty {
        lines.append("error: dependency cycle(s) detected:")
        for cycle in errors.cycles {
            let path = cycle.map { $0.typeName }.joined(separator: " → ")
            lines.append("  \(path)")
        }
    }

    if !errors.missingBindings.isEmpty {
        if !lines.isEmpty { lines.append("") }
        lines.append("error: missing binding(s):")
        for missing in errors.missingBindings {
            // Wildcard-label dependencies (`@Inject init(_ x: Foo)`) carry
            // a nil name; render as `_` for the diagnostic so it matches
            // the source-level form and Swift's compiler doesn't generate
            // a "debug description of optional" warning.
            let displayName = missing.dependency.name ?? "_"
            lines.append(
                "  \(missing.consumer.typeName) needs \(displayName): \(missing.dependency.type) — no @Singleton matches '\(missing.dependency.type)'"
            )
        }
    }

    return lines.joined(separator: "\n")
}
