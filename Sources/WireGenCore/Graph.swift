// MARK: - Graph result

/// The outcome of running graph construction over a set of discovered
/// singletons. Captures the topological order (used by sitting 4's code
/// emission), any singletons skipped from analysis (generic types, which
/// require iteration 3's specialisation work), and any validation errors
/// found.
public struct GraphResult: Sendable {
    /// Singletons in dependency-first order — every singleton appears
    /// after all the singletons it depends on. When `cycles` is empty,
    /// this is a valid ordering for the sitting 4 bootstrap. When cycles
    /// exist, the ordering is best-effort (cycle members are still
    /// listed but their relative order isn't meaningful).
    public let topologicalOrder: [DiscoveredSingleton]

    /// Singletons skipped from graph construction. At sitting 3 this is
    /// limited to generic singletons — concrete-type substitution lives
    /// in iteration 3's strict-on-ambiguity work and isn't ready yet.
    /// Skipped singletons aren't validated against the rest of the graph.
    public let skipped: [DiscoveredSingleton]

    /// Cycles detected during topological sort. Each entry is the path
    /// `A → B → … → A`, with the repeating endpoint listed twice so the
    /// path reads naturally.
    public let cycles: [[DiscoveredSingleton]]

    /// Dependencies whose declared type doesn't match any discovered
    /// `@Singleton` in the graph. At sitting 3 this is the only way a
    /// dependency can be unresolved — `@Provides` (iteration 2) and
    /// adapter annotations (M3+) provide further resolution paths later.
    public let missingBindings: [MissingBinding]

    public var hasErrors: Bool {
        !cycles.isEmpty || !missingBindings.isEmpty
    }
}

/// One unresolved dependency — a `@Singleton`'s `@Inject` parameter or
/// property whose declared type isn't satisfied by any other discovered
/// `@Singleton`.
public struct MissingBinding: Sendable {
    public let consumer: DiscoveredSingleton
    public let dependency: DependencyParameter

    public init(consumer: DiscoveredSingleton, dependency: DependencyParameter) {
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
/// sitting 3 graph can't resolve cleanly. Concrete substitution arrives
/// in iteration 3.
public func buildDependencyGraph(
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

    return GraphResult(
        topologicalOrder: sortResult.order,
        skipped: skipped,
        cycles: sortResult.cycles,
        missingBindings: missingBindings
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
/// Callers should treat a non-empty `cycles` as a validation failure
/// regardless of what the order looks like.
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

/// Render the topological order as a numbered list — what sitting 4's
/// code generation will iterate over to emit the bootstrap.
public func renderTopologicalOrder(_ order: [DiscoveredSingleton]) -> String {
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

/// Render skipped singletons (generic types deferred to iteration 3) as
/// a short notice, suppressed entirely when none were skipped.
public func renderSkipped(_ skipped: [DiscoveredSingleton]) -> String {
    guard !skipped.isEmpty else { return "" }
    var lines: [String] = []
    lines.append("skipped (generic types — concrete substitution lands in iteration 3):")
    for singleton in skipped {
        let generics =
            "<\(singleton.genericParameterNames.joined(separator: ", "))>"
        lines.append("  \(singleton.typeName)\(generics)")
    }
    return lines.joined(separator: "\n")
}

/// Render any validation errors as a multi-line message suitable for
/// stderr. Cycles come first (graph-shape problems take precedence over
/// missing-binding problems), then missing bindings.
public func renderValidationErrors(_ result: GraphResult) -> String {
    var lines: [String] = []

    if !result.cycles.isEmpty {
        lines.append("error: dependency cycle(s) detected:")
        for cycle in result.cycles {
            let path = cycle.map { $0.typeName }.joined(separator: " → ")
            lines.append("  \(path)")
        }
    }

    if !result.missingBindings.isEmpty {
        if !lines.isEmpty { lines.append("") }
        lines.append("error: missing binding(s):")
        for missing in result.missingBindings {
            lines.append(
                "  \(missing.consumer.typeName) needs \(missing.dependency.name): \(missing.dependency.type) — no @Singleton matches '\(missing.dependency.type)'"
            )
        }
    }

    return lines.joined(separator: "\n")
}
