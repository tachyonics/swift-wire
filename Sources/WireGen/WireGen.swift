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
///     WireGen <graph-output-path> <key-checks-output-path> <module> [source-files...]
///
/// Sources are grouped by module via repeated `--module <name> <files…>`
/// segments. The **first** group is the consumer target being built; any
/// further groups are Wire-aware dependencies whose sources the plugin
/// read for cross-module composition (7c). Every binding is stamped with
/// its group's module (load-bearing for cross-module composition; see
/// `MultiModuleComposition.md`).
///
///     WireGen <graph> <keychecks> --module App a.swift b.swift --module LibA c.swift
@main
struct WireGen {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { printUsageAndExit() }
        let graphOutputPath = arguments[1]
        let keyChecksOutputPath = arguments[2]
        let groups = parseModuleGroups(Array(arguments.dropFirst(3)))
        guard let consumerModule = groups.first?.module else { printUsageAndExit() }

        let aggregate = discoverAllSources(groups: groups, consumerModule: consumerModule)
        print(renderDiscoveryReport(perFile: aggregate.perFile))

        // One graph per scope — default, per-`@Container`, and per-seed.
        let graphs = buildAllGraphs(in: aggregate)
        let defaultGraph = graphs.defaultGraph
        let containerGraphs = graphs.containerGraphs
        let seedScopeOrchestrations = graphs.seedScopeOrchestrations

        printGenericTemplatesReport(
            default: defaultGraph,
            containers: containerGraphs,
            seedScopes: seedScopeOrchestrations
        )
        let crossFileDiagnostics = collectCrossFileDiagnostics(
            in: aggregate,
            containerNames: Set(containerGraphs.map { $0.name }),
            resolvedBindingsByContainer: graphs.resolvedBindingsByContainer
        )
        let allDiagnostics = aggregate.warnings + crossFileDiagnostics
        printDiagnostics(allDiagnostics)
        failIfAnyDiagnosticIsError(allDiagnostics)
        failIfAnyGraphInvalid(
            default: defaultGraph,
            containers: containerGraphs,
            seedScopes: seedScopeOrchestrations
        )

        let defaultOrder = defaultGraph.outcome.topologicalOrder ?? []

        // Adapter registrations resolve against the *valid* default graph, so
        // this runs after `failIfAnyGraphInvalid`. Their errors (missing
        // dependency, duplicate definition) get their own fail step rather than
        // riding the cross-file pass, which fires before the graph is known good.
        let (adapterRegistrations, adapterDiagnostics) = resolveAdapterRegistrations(
            useSites: aggregate.adapterUseSites,
            definitions: aggregate.adapterAnnotations,
            producers: defaultOrder
        )
        printDiagnostics(adapterDiagnostics)
        failIfAnyDiagnosticIsError(adapterDiagnostics)

        let containerOrders = printAndCollectTopologicalOrders(
            defaultOrder: defaultOrder,
            containers: containerGraphs,
            seedScopes: seedScopeOrchestrations
        )

        // Bindings composed from a dependency module are referenced by
        // the generated file, which lives in the consumer module — so it
        // needs an `import <dependency>` for each foreign origin module.
        let allBindingsFlat = aggregate.allBindings.values.flatMap { $0 }
        let imports =
            aggregate.imports
            + foreignImports(in: allBindingsFlat, consumerModule: consumerModule)

        let seedScopeOrders = collectSeedScopeOrders(seedScopeOrchestrations)
        let generated = renderWireGraph(
            imports: imports,
            topologicalOrder: defaultOrder,
            containerTopologicalOrders: containerOrders,
            seedScopeOrders: seedScopeOrders,
            adapterRegistrations: adapterRegistrations,
            graphConformances: aggregate.graphConformances
        )
        try generated.write(toFile: graphOutputPath, atomically: true, encoding: .utf8)
        print("wrote \(graphOutputPath)")

        // Key checks: every binding across every partition is fair game
        // for a keyed annotation, and the emitted file is independent
        // of the graph's topological ordering — it's pure type
        // assertion scaffolding the Swift compiler runs through when
        // building the consumer.
        let keyChecks = renderWireKeyChecks(
            imports: imports,
            allBindings: allBindingsFlat,
            multibindingKeyReferences: Set(aggregate.multibindingKeys.map(\.keyReference))
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
        /// The consumer module these sources belong to — carried so the
        /// graph-building pass can stamp synthetic seed bindings with it.
        var module: String
        /// Modules composed from external packages (the `--external-module`
        /// groups). Drives the cross-module visibility threshold: a binding
        /// from one of these needs `public`, not just `package`.
        var externalModules: Set<String> = []
        var perFile: [(path: String, items: [DiscoveredBinding])] = []
        var allBindings: [Partition: [DiscoveredBinding]] = [:]
        var imports: [String] = []
        var warnings: [Diagnostic] = []
        var unannotatedExtensionProvides: [UnannotatedExtensionProvides] = []
        var typealiases: [DiscoveredTypealias] = []
        var declaredTypeNames: Set<String> = []
        var nonInjectExtensionInits: [NonInjectExtensionInit] = []
        var multibindingKeys: [DiscoveredMultibindingKey] = []
        var bindingKeys: [DiscoveredBindingKey] = []
        var adapterAnnotations: [DiscoveredAdapterAnnotation] = []
        var adapterUseSites: [AdapterUseSite] = []
        var resultBuilders: [DiscoveredResultBuilder] = []
        var graphConformances: [DiscoveredGraphConformance] = []
    }

    private static func discoverAllSources(
        groups: [(module: String, sources: [String], isExternal: Bool)],
        consumerModule: String
    ) -> DiscoveryAggregate {
        var aggregate = DiscoveryAggregate(module: consumerModule)
        aggregate.externalModules = Set(groups.filter(\.isExternal).map(\.module))
        let modulePaths = groups.flatMap { group in group.sources.map { (group.module, $0) } }
        for (module, path) in modulePaths {
            let source = readSource(at: path)
            let result = discover(in: source, sourcePath: path, module: module)

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
            aggregate.multibindingKeys.append(contentsOf: result.multibindingKeys)
            aggregate.bindingKeys.append(contentsOf: result.bindingKeys)
            aggregate.adapterAnnotations.append(contentsOf: result.adapterAnnotations)
            aggregate.adapterUseSites.append(contentsOf: result.adapterUseSites)
            aggregate.resultBuilders.append(contentsOf: result.resultBuilders)
            aggregate.graphConformances.append(contentsOf: result.graphConformances)
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
        // Resolved-graph bindings per container (post-specialisation),
        // merged across the container's singleton graph and its seed
        // scopes. Feeds the dead-binding detector so a concrete producer
        // consumed only through a specialised generic dependency counts
        // as live.
        var resolvedBindingsByContainer: [String?: [DiscoveredBinding]]
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
        var defaultGraph = GraphResult(outcome: .success(topologicalOrder: []), genericTemplates: [])
        var containerGraphs: [(name: String, result: GraphResult)] = []
        var seedScopeOrchestrations: [SeedScopeOrchestration] = []
        var resolvedBindingsByContainer: [String?: [DiscoveredBinding]] = [:]
        for containerKey in partitions.keys.sorted(by: containerKeyOrder) {
            let scopes = partitions[containerKey] ?? [:]
            let singletons = scopes[nil] ?? []
            let parentGraphType = containerKey.map { "_\($0)WireGraph" } ?? "_WireGraph"
            // Multibindings fan in per partition: each graph aggregates
            // its own contributors atomically (synthesizeAggregates only
            // builds keys used in this partition's bindings).
            let rawGraph = buildDependencyGraph(
                from: singletons,
                typealiases: aggregate.typealiases,
                multibindingKeys: aggregate.multibindingKeys,
                resultBuilders: aggregate.resultBuilders
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
            resolvedBindingsByContainer[containerKey, default: []] += graph.outcome.topologicalOrder ?? []
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
                    typealiases: aggregate.typealiases,
                    multibindingKeys: aggregate.multibindingKeys,
                    resultBuilders: aggregate.resultBuilders,
                    module: aggregate.module
                )
                let enrichedResult = enrichMissingBindingsWithCrossScopeHints(
                    orchestration.result,
                    consumerPartition: Partition(container: containerKey, scope: seedKey),
                    allBindings: aggregate.allBindings
                )
                seedScopeOrchestrations.append(orchestration.withResult(enrichedResult))
                resolvedBindingsByContainer[containerKey, default: []] += enrichedResult.outcome.topologicalOrder ?? []
            }
        }
        return GraphBuilds(
            defaultGraph: defaultGraph,
            containerGraphs: containerGraphs,
            seedScopeOrchestrations: seedScopeOrchestrations,
            resolvedBindingsByContainer: resolvedBindingsByContainer
        )
    }

    /// WireGen-level warnings that need module-wide context to fire:
    /// unannotated `@Provides`-in-extension, cross-module-extension,
    /// and extension-init conflicts on `@Singleton`/`@Scoped` types.
    /// Per-file warnings come straight from `aggregate.warnings`.
    private static func collectCrossFileDiagnostics(
        in aggregate: DiscoveryAggregate,
        containerNames: Set<String>,
        resolvedBindingsByContainer: [String?: [DiscoveredBinding]]
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        diagnostics += unannotatedExtensionContainerDiagnostics(
            candidates: aggregate.unannotatedExtensionProvides,
            containerNames: containerNames
        )
        diagnostics += crossModuleExtensionDiagnostics(
            candidates: aggregate.unannotatedExtensionProvides,
            containerNames: containerNames,
            declaredTypeNames: aggregate.declaredTypeNames
        )
        diagnostics += extensionInitConflictDiagnostics(
            candidates: aggregate.nonInjectExtensionInits,
            singletonTypeNames: singletonTypeNames(in: aggregate)
        )
        diagnostics += multibindingContributionDiagnostics(
            declaredKeyReferences: Set(aggregate.multibindingKeys.map(\.keyReference)),
            contributionsByPartition: aggregate.allBindings.mapValues { bindings in
                bindings.flatMap { $0.contributions }
            }
        )
        diagnostics += deadBindingDiagnostics(
            across: aggregate.allBindings,
            resolvedByContainer: resolvedBindingsByContainer,
            adapterUseSites: aggregate.adapterUseSites,
            adapterDefinitions: aggregate.adapterAnnotations
        )
        diagnostics += multibindingLivenessDiagnostics(
            multibindingKeys: aggregate.multibindingKeys,
            bindingsByPartition: aggregate.allBindings
        )
        diagnostics += unknownBindingKeyDiagnostics(
            bindingsByPartition: aggregate.allBindings,
            declaredKeyReferences: Set(aggregate.bindingKeys.map(\.keyReference))
                .union(aggregate.multibindingKeys.map(\.keyReference))
        )
        diagnostics += crossModuleVisibilityDiagnostics(
            bindings: aggregate.allBindings.values.flatMap { $0 },
            consumerModule: aggregate.module,
            externalModules: aggregate.externalModules
        )
        return diagnostics
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
    /// They need to be surfaced to the user, even when they don't fail
    /// the build. WireGen prints them before
    /// any validation-error block so a failing build's error message
    /// remains the last thing on stderr.
    private static func printDiagnostics(_ warnings: [Diagnostic]) {
        guard !warnings.isEmpty else { return }
        FileHandle.standardError.write(Data(renderDiagnostics(warnings).utf8))
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

    /// Print the generic templates combined across all graphs.
    /// Informational; doesn't affect validation.
    private static func printGenericTemplatesReport(
        default defaultGraph: GraphResult,
        containers containerGraphs: [(name: String, result: GraphResult)],
        seedScopes seedScopeOrchestrations: [SeedScopeOrchestration]
    ) {
        let allGenericTemplates =
            defaultGraph.genericTemplates
            + containerGraphs.flatMap { $0.result.genericTemplates }
            + seedScopeOrchestrations.flatMap { $0.result.genericTemplates }
        let report = renderGenericTemplates(allGenericTemplates)
        guard !report.isEmpty else { return }
        print("")
        print(report)
    }

    /// `exit(1)` if any of the source-pattern diagnostics carry
    /// `.error` severity. Called after `printDiagnostics` has
    /// already written them to stderr, so the user has the
    /// friendly message before the build fails. Used for patterns
    /// whose generated code wouldn't compile or would silently
    /// produce wrong results (`@Inject mutating func` on a struct,
    /// etc.) — failing here means the bad code never gets emitted
    /// at all.
    private static func failIfAnyDiagnosticIsError(_ diagnostics: [Diagnostic]) {
        guard diagnostics.contains(where: { $0.severity == .error }) else { return }
        exit(1)
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

}

/// Ordering helpers: deterministic container iteration order and the
/// seed-scope flattening that feeds the emitter.
extension WireGen {
    /// Sort container keys with `nil` first (the default graph
    /// processes before any named container), then alphabetically by
    /// container name. Used to give the unified partition iteration
    /// a deterministic, predictable order.
    fileprivate static func containerKeyOrder(_ lhs: String?, _ rhs: String?) -> Bool {
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
    fileprivate static func collectSeedScopeOrders(
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
}

/// CLI argument parsing and usage: module-group parsing and the usage
/// message printed on malformed invocation.
extension WireGen {
    /// Parse the module segments (everything after the two output paths)
    /// into ordered groups. Each group is `--module <name> <files…>` (the
    /// consumer or a same-package dependency) or `--external-module <name>
    /// <files…>` (a dependency from an external package). The first group
    /// is the consumer target. `isExternal` drives the cross-module
    /// visibility threshold (7f): `package` reaches across same-package
    /// modules but not across packages.
    static func parseModuleGroups(
        _ args: [String]
    ) -> [(module: String, sources: [String], isExternal: Bool)] {
        var groups: [(module: String, sources: [String], isExternal: Bool)] = []
        var index = 0
        while index < args.count {
            let flag = args[index]
            guard flag == "--module" || flag == "--external-module", index + 1 < args.count else {
                printUsageAndExit()
            }
            let isExternal = flag == "--external-module"
            let module = args[index + 1]
            index += 2
            var sources: [String] = []
            while index < args.count, args[index] != "--module", args[index] != "--external-module" {
                sources.append(args[index])
                index += 1
            }
            groups.append((module, sources, isExternal))
        }
        return groups
    }

    static func printUsageAndExit() -> Never {
        FileHandle.standardError.write(
            Data(
                "error: WireGen requires two output paths (graph + key checks) and at least one --module group.\n"
                    .utf8
            )
        )
        FileHandle.standardError.write(
            Data(
                "usage: WireGen <graph-output-path> <key-checks-output-path> --module <name> <source-files...> [--module <name> <source-files...>]\n"
                    .utf8
            )
        )
        exit(1)
    }
}
