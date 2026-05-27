import Foundation
import WireGenCore

/// `WireGen` — code-generation executable invoked by the Wire build plugin.
///
/// Thin CLI wrapper over `WireGenCore`. Discovers `@Singleton` and
/// `@Provides` bindings in the input source files, builds a dependency
/// graph, runs topological sort with cycle / missing-binding /
/// duplicate-binding detection, and on success emits two files:
///   - `_WireGraph.swift` — the bootstrap struct + free function
///   - `_WireKeyChecks.swift` — compile-time type assertions for
///     every keyed `@Inject` / `@Provides` annotation
///
/// On validation failure, writes the errors to stderr, exits non-zero,
/// and writes no output files — the build plugin treats a missing
/// output as a failed generation step.
///
/// `import` declarations are propagated verbatim from input source
/// files into both generated files so any types referenced by
/// bindings remain in scope.
///
/// CLI shape:
///
///     WireGen <graph-output-path> <key-checks-output-path> [source-files...]
@main
struct WireGen {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { printUsageAndExit() }
        let graphOutputPath = arguments[1]
        let keyChecksOutputPath = arguments[2]
        let sourcePaths = Array(arguments.dropFirst(3))

        let aggregate = discoverAllSources(at: sourcePaths)
        print(renderDiscoveryReport(perFile: aggregate.perFile))

        // One graph per scope — default, per-`@Container`, and per-seed.
        let graphs = buildAllGraphs(in: aggregate)
        let defaultGraph = graphs.defaultGraph
        let containerGraphs = graphs.containerGraphs
        let seedScopeOrchestrations = graphs.seedScopeOrchestrations

        printSkippedReport(
            default: defaultGraph,
            containers: containerGraphs,
            seedScopes: seedScopeOrchestrations
        )
        let crossFileWarnings = collectCrossFileWarnings(
            in: aggregate,
            containerNames: Set(containerGraphs.map { $0.name })
        )
        printWarnings(aggregate.warnings + crossFileWarnings)
        failIfAnyGraphInvalid(
            default: defaultGraph,
            containers: containerGraphs,
            seedScopes: seedScopeOrchestrations
        )

        let defaultOrder = defaultGraph.outcome.topologicalOrder ?? []
        let containerOrders = printAndCollectTopologicalOrders(
            defaultOrder: defaultOrder,
            containers: containerGraphs,
            seedScopes: seedScopeOrchestrations
        )

        let seedScopeOrders = collectSeedScopeOrders(seedScopeOrchestrations)
        let generated = renderWireGraph(
            imports: aggregate.imports,
            topologicalOrder: defaultOrder,
            containerTopologicalOrders: containerOrders,
            seedScopeOrders: seedScopeOrders
        )
        try generated.write(toFile: graphOutputPath, atomically: true, encoding: .utf8)
        print("wrote \(graphOutputPath)")

        // Key checks: every binding across every partition is fair game
        // for a keyed annotation, and the emitted file is independent
        // of the graph's topological ordering — it's pure type
        // assertion scaffolding the Swift compiler runs through when
        // building the consumer.
        let allBindingsFlat = aggregate.allBindings.values.flatMap { $0 }
        let keyChecks = renderWireKeyChecks(
            imports: aggregate.imports,
            allBindings: allBindingsFlat
        )
        try keyChecks.write(toFile: keyChecksOutputPath, atomically: true, encoding: .utf8)
        print("wrote \(keyChecksOutputPath)")
    }

    // MARK: - Helpers

    /// Aggregated per-file discovery: a flat per-file inventory for
    /// the discovery report plus the unified `(container, scope)`
    /// binding partition for graph orchestration. Per-graph slices
    /// (default, named container) are derived from `allBindings` at
    /// the point of use via the helpers below.
    private struct DiscoveryAggregate {
        var perFile: [(path: String, items: [DiscoveredBinding])] = []
        var allBindings: [Partition: [DiscoveredBinding]] = [:]
        var imports: [String] = []
        var warnings: [Warning] = []
        var unannotatedExtensionProvides: [UnannotatedExtensionProvides] = []
        var typealiases: [DiscoveredTypealias] = []
        var declaredTypeNames: Set<String> = []
        var nonInjectExtensionInits: [NonInjectExtensionInit] = []
    }

    private static func discoverAllSources(at sourcePaths: [String]) -> DiscoveryAggregate {
        var aggregate = DiscoveryAggregate()
        for path in sourcePaths {
            let source = readSource(at: path)
            let result = discover(in: source, sourcePath: path)

            // For the discovery report, show all of the file's bindings
            // together regardless of partition — the access path on
            // provider bindings already encodes the container name, so
            // a flat per-file view stays informative.
            let fileBindings = result.allBindings.values.flatMap { $0 }
            aggregate.perFile.append((path: path, items: fileBindings))

            for (partition, bindings) in result.allBindings {
                aggregate.allBindings[partition, default: []].append(contentsOf: bindings)
            }

            // Only collect imports from files that contribute bindings.
            // Files with no @Singleton/@Provides have nothing to add to
            // the generated file's type-visibility needs — including
            // their imports would just leak unrelated modules.
            if !result.allBindings.isEmpty {
                aggregate.imports.append(contentsOf: result.imports)
            }

            aggregate.warnings.append(contentsOf: result.warnings)
            aggregate.unannotatedExtensionProvides.append(
                contentsOf: result.unannotatedExtensionProvides
            )
            aggregate.typealiases.append(contentsOf: result.typealiases)
            aggregate.declaredTypeNames.formUnion(result.declaredTypeNames)
            aggregate.nonInjectExtensionInits.append(
                contentsOf: result.nonInjectExtensionInits
            )
        }
        return aggregate
    }

    /// Bundle of all per-graph build outputs. Held together so the
    /// main flow can pull each output through the validation / print
    /// / emit pipeline without recomputing slices.
    private struct GraphBuilds {
        var defaultGraph: GraphResult
        var containerGraphs: [(name: String, result: GraphResult)]
        var seedScopeOrchestrations: [SeedScopeOrchestration]
    }

    /// Partition `aggregate.allBindings` along both axes in a single
    /// pass. Outer key: container name (`nil` for the default graph).
    /// Inner key: scope (`nil` for the singleton scope). The default
    /// graph is just "the container with no name" — the data model
    /// treats `(container: nil)` and `(container: "Foo")` symmetrically
    /// and `buildAllGraphs` iterates uniformly across both.
    private static func partitionBindings(
        in aggregate: DiscoveryAggregate
    ) -> [String?: [ScopeKey?: [DiscoveredBinding]]] {
        var partitions: [String?: [ScopeKey?: [DiscoveredBinding]]] = [:]
        for (partition, bindings) in aggregate.allBindings {
            partitions[partition.container, default: [:]][
                partition.scope,
                default: []
            ].append(contentsOf: bindings)
        }
        return partitions
    }

    /// Build every graph the input describes: the default graph, one
    /// per `@Container`, and one per seeded scope (default-graph and
    /// container-scope alike). Iterates the partitioned bindings
    /// uniformly — for each container (including the default with
    /// `containerName == nil`), build the singleton graph from the
    /// scope=nil cell, synthesise the singleton borrow set, then
    /// orchestrate each seeded scope keyed off scope≠nil cells. The
    /// default and container singleton graphs are atomic; seeded
    /// scopes borrow from their parent container's singletons.
    private static func buildAllGraphs(in aggregate: DiscoveryAggregate) -> GraphBuilds {
        let partitions = partitionBindings(in: aggregate)
        var defaultGraph = GraphResult(outcome: .success(topologicalOrder: []), skipped: [])
        var containerGraphs: [(name: String, result: GraphResult)] = []
        var seedScopeOrchestrations: [SeedScopeOrchestration] = []
        for containerKey in partitions.keys.sorted(by: containerKeyOrder) {
            let scopes = partitions[containerKey] ?? [:]
            let singletons = scopes[nil] ?? []
            let parentGraphType = containerKey.map { "_\($0)WireGraph" } ?? "_WireGraph"
            let rawGraph = buildDependencyGraph(
                from: singletons,
                typealiases: aggregate.typealiases
            )
            let graph = enrichMissingBindingsWithCrossScopeHints(
                rawGraph,
                consumerPartition: Partition(container: containerKey, scope: nil),
                allBindings: aggregate.allBindings
            )
            if let containerName = containerKey {
                containerGraphs.append((name: containerName, result: graph))
            } else {
                defaultGraph = graph
            }
            let borrows = syntheticSingletonBorrowBindings(
                from: singletons,
                inWireGraphOfType: parentGraphType
            )
            let seedKeys =
                scopes.keys
                .compactMap { $0 }
                .sorted(by: { $0.seed < $1.seed })
            for seedKey in seedKeys {
                let scopeBindings = scopes[seedKey] ?? []
                let orchestration = orchestrateSeedScope(
                    seedKey: seedKey,
                    containerName: containerKey,
                    scopeBindings: scopeBindings,
                    borrowBindings: borrows,
                    parentGraphType: parentGraphType,
                    typealiases: aggregate.typealiases
                )
                let enrichedResult = enrichMissingBindingsWithCrossScopeHints(
                    orchestration.result,
                    consumerPartition: Partition(container: containerKey, scope: seedKey),
                    allBindings: aggregate.allBindings
                )
                seedScopeOrchestrations.append(orchestration.withResult(enrichedResult))
            }
        }
        return GraphBuilds(
            defaultGraph: defaultGraph,
            containerGraphs: containerGraphs,
            seedScopeOrchestrations: seedScopeOrchestrations
        )
    }

    /// Sort container keys with `nil` first (the default graph
    /// processes before any named container), then alphabetically by
    /// container name. Used to give the unified partition iteration
    /// a deterministic, predictable order.
    private static func containerKeyOrder(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (.some(let lhsName), .some(let rhsName)): return lhsName < rhsName
        }
    }

    /// Flatten the per-seed orchestrations into the emission-side
    /// shape `renderWireGraph` consumes — each entry carries the seed
    /// type expression, the identifier suffix, the parent graph type,
    /// the topological order, and the borrowed-binding property-name
    /// set the emitter uses to distinguish locally-constructed
    /// bindings from singleton borrows. Orchestrations whose graphs
    /// failed validation are excluded (the validation-failure pipeline
    /// has already exited by this point; the filter is defensive).
    private static func collectSeedScopeOrders(
        _ orchestrations: [SeedScopeOrchestration]
    ) -> [SeedScopeEmission] {
        orchestrations.compactMap { orchestration in
            guard let order = orchestration.result.outcome.topologicalOrder else { return nil }
            return SeedScopeEmission(
                seedTypeExpression: orchestration.seedTypeExpression,
                identifierSuffix: orchestration.identifierSuffix,
                parentGraphType: orchestration.parentGraphType,
                topologicalOrder: order,
                borrowedBindingPropertyNames: orchestration.borrowedBindingPropertyNames
            )
        }
    }

    /// WireGen-level warnings that need module-wide context to fire:
    /// unannotated `@Provides`-in-extension, cross-module-extension,
    /// extension-init conflicts on `@Singleton`/`@Scoped` types, and
    /// no-effect `Lazy<T>` consumers (mixed direct + Lazy consumers
    /// of the same T). Per-file warnings come straight from
    /// `aggregate.warnings`.
    private static func collectCrossFileWarnings(
        in aggregate: DiscoveryAggregate,
        containerNames: Set<String>
    ) -> [Warning] {
        unannotatedExtensionContainerWarnings(
            candidates: aggregate.unannotatedExtensionProvides,
            containerNames: containerNames
        )
            + crossModuleExtensionWarnings(
                candidates: aggregate.unannotatedExtensionProvides,
                containerNames: containerNames,
                declaredTypeNames: aggregate.declaredTypeNames
            )
            + extensionInitConflictWarnings(
                candidates: aggregate.nonInjectExtensionInits,
                singletonTypeNames: singletonTypeNames(in: aggregate)
            )
            + collectLazyNoEffectWarnings(in: aggregate)
    }

    /// Run `lazyNoEffectWarnings` over every partition independently
    /// — `Lazy<T>` is intra-scope only, so a partition's classification
    /// is local to its own bindings. Each per-partition call already
    /// sorts its output by source location; the concatenated list is
    /// resorted globally so the merged output is stable regardless of
    /// the partition-dict iteration order.
    private static func collectLazyNoEffectWarnings(
        in aggregate: DiscoveryAggregate
    ) -> [Warning] {
        aggregate.allBindings.values
            .flatMap { lazyNoEffectWarnings(in: $0) }
            .sorted { $0.location < $1.location }
    }

    /// Collect type names of `@Singleton` bindings across every graph
    /// (default + every container). Drives the extension-init-conflict
    /// warning — `@Singleton` is the only scope macro whose generated
    /// init the warning needs to be aware of; future scopes (`@Scoped`)
    /// will join the set here when they land.
    private static func singletonTypeNames(in aggregate: DiscoveryAggregate) -> Set<String> {
        Set(
            aggregate.allBindings.values
                .flatMap { $0 }
                .compactMap { binding -> String? in
                    if case .scopeBound(let scopeBound) = binding { return scopeBound.typeName }
                    return nil
                }
        )
    }

    /// Emit warnings to stderr in the `file:line:col: warning:` form.
    /// Warnings are informational — they don't fail the build — but
    /// they need to surface to the user. WireGen prints them before
    /// any validation-error block so a failing build's error message
    /// remains the last thing on stderr.
    private static func printWarnings(_ warnings: [Warning]) {
        guard !warnings.isEmpty else { return }
        FileHandle.standardError.write(Data(renderWarnings(warnings).utf8))
        FileHandle.standardError.write(Data("\n".utf8))
    }

    private static func readSource(at path: String) -> String {
        do {
            return try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        } catch {
            FileHandle.standardError.write(
                Data("error: failed to read \(path): \(error)\n".utf8)
            )
            exit(1)
        }
    }

    /// Print skipped (generic) bindings combined across all graphs.
    /// Informational; doesn't affect validation.
    private static func printSkippedReport(
        default defaultGraph: GraphResult,
        containers containerGraphs: [(name: String, result: GraphResult)],
        seedScopes seedScopeOrchestrations: [SeedScopeOrchestration]
    ) {
        let allSkipped =
            defaultGraph.skipped
            + containerGraphs.flatMap { $0.result.skipped }
            + seedScopeOrchestrations.flatMap { $0.result.skipped }
        let report = renderSkipped(allSkipped)
        guard !report.isEmpty else { return }
        print("")
        print(report)
    }

    /// Write validation failures (one block per failing graph) to
    /// stderr and `exit(1)` if any graph is invalid. The build plugin
    /// treats a missing output as a failed generation step.
    private static func failIfAnyGraphInvalid(
        default defaultGraph: GraphResult,
        containers containerGraphs: [(name: String, result: GraphResult)],
        seedScopes seedScopeOrchestrations: [SeedScopeOrchestration]
    ) {
        var allNamedGraphs: [(name: String, result: GraphResult)] =
            [(name: "default", result: defaultGraph)] + containerGraphs
        for orchestration in seedScopeOrchestrations {
            allNamedGraphs.append(
                (
                    name: "scope '\(orchestration.seedTypeExpression)'",
                    result: orchestration.result
                )
            )
        }
        let failures = allNamedGraphs.compactMap {
            named -> (name: String, errors: GraphResult.ValidationErrors)? in
            if let errors = named.result.outcome.validationErrors {
                return (named.name, errors)
            }
            return nil
        }
        guard !failures.isEmpty else { return }
        for failure in failures {
            FileHandle.standardError.write(Data("\nin graph '\(failure.name)':\n".utf8))
            FileHandle.standardError.write(
                Data(renderValidationErrors(failure.errors).utf8)
            )
            FileHandle.standardError.write(Data("\n".utf8))
        }
        exit(1)
    }

    /// Print the topological order for each successful graph and
    /// return the per-container orders keyed by name (the default
    /// order is the caller's responsibility since the caller already
    /// holds it). Seed-scope orchestrations carry their own orders
    /// inside their result; the caller reads them from there.
    private static func printAndCollectTopologicalOrders(
        defaultOrder: [DiscoveredBinding],
        containers containerGraphs: [(name: String, result: GraphResult)],
        seedScopes seedScopeOrchestrations: [SeedScopeOrchestration]
    ) -> [String: [DiscoveredBinding]] {
        print("")
        print("default graph:")
        print(renderTopologicalOrder(defaultOrder))
        var containerOrders: [String: [DiscoveredBinding]] = [:]
        for (name, result) in containerGraphs {
            let order = result.outcome.topologicalOrder ?? []
            containerOrders[name] = order
            print("")
            print("container '\(name)':")
            print(renderTopologicalOrder(order))
        }
        for orchestration in seedScopeOrchestrations {
            let order = orchestration.result.outcome.topologicalOrder ?? []
            print("")
            print("scope '\(orchestration.seedTypeExpression)':")
            print(renderTopologicalOrder(order))
        }
        return containerOrders
    }

    private static func printUsageAndExit() -> Never {
        FileHandle.standardError.write(
            Data(
                "error: WireGen requires two output path arguments (graph + key checks).\n"
                    .utf8
            )
        )
        FileHandle.standardError.write(
            Data(
                "usage: WireGen <graph-output-path> <key-checks-output-path> [source-files...]\n"
                    .utf8
            )
        )
        exit(1)
    }
}
