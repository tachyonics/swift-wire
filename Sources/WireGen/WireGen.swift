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

        // One graph per scope — default plus one per `@Container`.
        // Each is validated independently (atomic; no cross-graph
        // leakage).
        let defaultGraph = buildDependencyGraph(
            from: defaultBindings(in: aggregate),
            typealiases: aggregate.typealiases
        )
        let containerSingletonBindings = containerSingletonBindings(in: aggregate)
        let containerGraphs =
            containerSingletonBindings
            .sorted(by: { $0.key < $1.key })
            .map { name, bindings in
                (
                    name: name,
                    result: buildDependencyGraph(
                        from: bindings,
                        typealiases: aggregate.typealiases
                    )
                )
            }

        printSkippedReport(default: defaultGraph, containers: containerGraphs)
        let containerNames = Set(containerSingletonBindings.keys)
        let singletonTypeNames = singletonTypeNames(in: aggregate)
        let unannotatedExtensionContainerWarnings = unannotatedExtensionContainerWarnings(
            candidates: aggregate.unannotatedExtensionProvides,
            containerNames: containerNames
        )
        let crossModuleExtensionWarnings = crossModuleExtensionWarnings(
            candidates: aggregate.unannotatedExtensionProvides,
            containerNames: containerNames,
            declaredTypeNames: aggregate.declaredTypeNames
        )
        let extensionInitConflictWarnings = extensionInitConflictWarnings(
            candidates: aggregate.nonInjectExtensionInits,
            singletonTypeNames: singletonTypeNames
        )
        let crossFileWarnings =
            unannotatedExtensionContainerWarnings
            + crossModuleExtensionWarnings
            + extensionInitConflictWarnings
        printWarnings(aggregate.warnings + crossFileWarnings)
        failIfAnyGraphInvalid(default: defaultGraph, containers: containerGraphs)

        let defaultOrder = defaultGraph.outcome.topologicalOrder ?? []
        let containerOrders = printAndCollectTopologicalOrders(
            defaultOrder: defaultOrder,
            containers: containerGraphs
        )

        let generated = renderWireGraph(
            imports: aggregate.imports,
            topologicalOrder: defaultOrder,
            containerTopologicalOrders: containerOrders
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

    /// Default-graph singleton bindings.
    /// `partition.container == nil && partition.scope == nil`.
    private static func defaultBindings(
        in aggregate: DiscoveryAggregate
    ) -> [DiscoveredBinding] {
        aggregate.allBindings[.default] ?? []
    }

    /// Singleton bindings inside each named container, grouped by
    /// container name. Today every entry has `scope == nil`; when
    /// `@Scoped` recognition lands, per-container scoped bindings
    /// will live in their own partitions and be derived separately.
    private static func containerSingletonBindings(
        in aggregate: DiscoveryAggregate
    ) -> [String: [DiscoveredBinding]] {
        var result: [String: [DiscoveredBinding]] = [:]
        for (partition, bindings) in aggregate.allBindings {
            guard let container = partition.container, partition.scope == nil else { continue }
            result[container, default: []].append(contentsOf: bindings)
        }
        return result
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
        containers containerGraphs: [(name: String, result: GraphResult)]
    ) {
        let allSkipped =
            defaultGraph.skipped + containerGraphs.flatMap { $0.result.skipped }
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
        containers containerGraphs: [(name: String, result: GraphResult)]
    ) {
        let allNamedGraphs: [(name: String, result: GraphResult)] =
            [(name: "default", result: defaultGraph)] + containerGraphs
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
    /// holds it).
    private static func printAndCollectTopologicalOrders(
        defaultOrder: [DiscoveredBinding],
        containers containerGraphs: [(name: String, result: GraphResult)]
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
