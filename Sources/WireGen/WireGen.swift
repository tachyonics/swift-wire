import Foundation
import WireGenCore

/// `WireGen` — code-generation executable invoked by the Wire build plugin.
///
/// Thin CLI wrapper over `WireGenCore`. Discovers `@Singleton` and
/// `@Provides` bindings in the input source files, builds a dependency
/// graph, runs topological sort with cycle / missing-binding /
/// duplicate-binding detection, and on success emits `_WireGraph.swift`
/// to the output path. On validation failure, writes the errors to
/// stderr, exits non-zero, and writes no output file — the build
/// plugin treats a missing output as a failed generation step.
///
/// `import` declarations are propagated verbatim from input source
/// files into the generated bootstrap so any types referenced by
/// bindings remain in scope.
///
/// CLI shape:
///
///     WireGen <output-path> [source-files...]
@main
struct WireGen {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else { printUsageAndExit() }
        let outputPath = arguments[1]
        let sourcePaths = Array(arguments.dropFirst(2))

        let aggregate = discoverAllSources(at: sourcePaths)
        print(renderDiscoveryReport(perFile: aggregate.perFile))

        // One graph per scope — default plus one per `@Container`.
        // Each is validated independently (atomic; no cross-graph
        // leakage).
        let defaultGraph = buildDependencyGraph(from: aggregate.defaultBindings)
        let containerGraphs = aggregate.containerBindings.keys.sorted().map {
            (name: $0, result: buildDependencyGraph(from: aggregate.containerBindings[$0] ?? []))
        }

        printSkippedReport(default: defaultGraph, containers: containerGraphs)
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
        try generated.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("wrote \(outputPath)")
    }

    // MARK: - Helpers

    /// Aggregated per-file discovery: bindings shown together in the
    /// discovery report (default + container), plus the two separate
    /// buckets the graph orchestration needs, plus the union of
    /// imports from binding-bearing files.
    private struct DiscoveryAggregate {
        var perFile: [(path: String, items: [DiscoveredBinding])] = []
        var defaultBindings: [DiscoveredBinding] = []
        var containerBindings: [String: [DiscoveredBinding]] = [:]
        var imports: [String] = []
    }

    private static func discoverAllSources(at sourcePaths: [String]) -> DiscoveryAggregate {
        var aggregate = DiscoveryAggregate()
        for path in sourcePaths {
            let source = readSource(at: path)
            let result = discover(in: source, sourcePath: path)

            // For the discovery report, show all of the file's bindings
            // (default and container) together — the access path on
            // provider bindings already encodes the container name, so
            // a flat per-file view stays informative.
            let containerBindingsList = result.containerBindings.values.flatMap { $0 }
            aggregate.perFile.append(
                (path: path, items: result.bindings + containerBindingsList)
            )

            aggregate.defaultBindings.append(contentsOf: result.bindings)
            for (name, bindings) in result.containerBindings {
                aggregate.containerBindings[name, default: []].append(contentsOf: bindings)
            }

            // Only collect imports from files that contribute bindings.
            // Files with no @Singleton/@Provides have nothing to add to
            // the generated file's type-visibility needs — including
            // their imports would just leak unrelated modules.
            if !result.bindings.isEmpty || !result.containerBindings.isEmpty {
                aggregate.imports.append(contentsOf: result.imports)
            }
        }
        return aggregate
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
            Data("error: WireGen requires at least an output path argument.\n".utf8)
        )
        FileHandle.standardError.write(
            Data("usage: WireGen <output-path> [source-files...]\n".utf8)
        )
        exit(1)
    }
}
