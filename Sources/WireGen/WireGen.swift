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

        guard arguments.count >= 2 else {
            FileHandle.standardError.write(
                Data("error: WireGen requires at least an output path argument.\n".utf8)
            )
            FileHandle.standardError.write(
                Data("usage: WireGen <output-path> [source-files...]\n".utf8)
            )
            exit(1)
        }

        let outputPath = arguments[1]
        let sourcePaths = Array(arguments.dropFirst(2))

        // 1. Discover bindings, container partitions, and imports
        //    across input sources. Bindings inside `@Container`
        //    declarations go into per-container buckets keyed by
        //    container name; everything else feeds the default graph.
        var perFileDiscovered: [(path: String, items: [DiscoveredBinding])] = []
        var allImports: [String] = []
        var defaultBindings: [DiscoveredBinding] = []
        var containerBindings: [String: [DiscoveredBinding]] = [:]
        for path in sourcePaths {
            let url = URL(fileURLWithPath: path)
            let source: String
            do {
                source = try String(contentsOf: url, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(
                    Data("error: failed to read \(path): \(error)\n".utf8)
                )
                exit(1)
            }
            let result = discover(in: source, sourcePath: path)

            // For the discovery report, show all of the file's bindings
            // (default and container) together — the access path on
            // provider bindings already encodes the container name, so
            // a flat per-file view stays informative.
            let containerBindingsList = result.containerBindings.values.flatMap { $0 }
            perFileDiscovered.append(
                (path: path, items: result.bindings + containerBindingsList)
            )

            defaultBindings.append(contentsOf: result.bindings)
            for (name, bindings) in result.containerBindings {
                containerBindings[name, default: []].append(contentsOf: bindings)
            }

            // Only collect imports from files that contribute bindings.
            // Files with no @Singleton/@Provides have nothing to add to
            // the generated file's type-visibility needs — including
            // their imports would just leak unrelated modules into the
            // generated bootstrap.
            if !result.bindings.isEmpty || !result.containerBindings.isEmpty {
                allImports.append(contentsOf: result.imports)
            }
        }
        print(renderDiscoveryReport(perFile: perFileDiscovered))

        // 2. Build per-graph dependency graphs: one for the default
        //    graph and one for each named container. Each is validated
        //    independently (its bindings are atomic — no cross-graph
        //    leakage).
        let defaultGraph = buildDependencyGraph(from: defaultBindings)
        let containerGraphs = containerBindings.keys.sorted().map {
            (name: $0, result: buildDependencyGraph(from: containerBindings[$0] ?? []))
        }

        // 3. Print skipped (generic) bindings, combined across all
        //    graphs — informational. Keys are sorted in `renderSkipped`
        //    only by source path, which is fine here.
        let allSkipped = defaultGraph.skipped + containerGraphs.flatMap { $0.result.skipped }
        let skippedReport = renderSkipped(allSkipped)
        if !skippedReport.isEmpty {
            print("")
            print(skippedReport)
        }

        // 4. Validation: any graph failing → write errors per graph
        //    to stderr, exit non-zero, write no output file. The
        //    build plugin treats a missing output as a failed step.
        let allNamedGraphs: [(name: String, result: GraphResult)] =
            [(name: "default", result: defaultGraph)] + containerGraphs
        let failures = allNamedGraphs.compactMap {
            named -> (name: String, errors: GraphResult.ValidationErrors)? in
            if let errors = named.result.outcome.validationErrors {
                return (named.name, errors)
            }
            return nil
        }
        if !failures.isEmpty {
            for failure in failures {
                FileHandle.standardError.write(Data("\nin graph '\(failure.name)':\n".utf8))
                FileHandle.standardError.write(
                    Data(renderValidationErrors(failure.errors).utf8)
                )
                FileHandle.standardError.write(Data("\n".utf8))
            }
            exit(1)
        }

        // 5. Success — print topological orders for each graph,
        //    emit the multi-struct `_WireGraph.swift` containing the
        //    default `_WireGraph` plus one `_<Name>WireGraph` per
        //    container.
        let defaultOrder = defaultGraph.outcome.topologicalOrder ?? []
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

        let generated = renderWireGraph(
            imports: allImports,
            topologicalOrder: defaultOrder,
            containerTopologicalOrders: containerOrders
        )
        try generated.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("wrote \(outputPath)")
    }
}
