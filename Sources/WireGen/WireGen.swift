import Foundation
import WireGenCore

/// `WireGen` — code-generation executable invoked by the Wire build plugin.
///
/// Thin CLI wrapper over `WireGenCore`. Discovers `@Singleton` types in
/// the input source files, builds a dependency graph, runs topological
/// sort with cycle detection and missing-binding detection, and on
/// success emits `_WireGraph.swift` to the output path. On validation
/// failure, writes the errors to stderr, exits non-zero, and writes no
/// output file — the build plugin treats a missing output as a failed
/// generation step.
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
                Data(
                    "error: WireGen requires at least an output path argument.\n".utf8
                )
            )
            FileHandle.standardError.write(
                Data("usage: WireGen <output-path> [source-files...]\n".utf8)
            )
            exit(1)
        }

        let outputPath = arguments[1]
        let sourcePaths = Array(arguments.dropFirst(2))

        // 1. Discover @Singleton types across input sources.
        var perFileDiscovered: [(path: String, items: [DiscoveredSingleton])] = []
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
            let items = discoverSingletons(in: source, sourcePath: path)
            perFileDiscovered.append((path: path, items: items))
        }
        print(renderDiscoveryReport(perFile: perFileDiscovered))

        // 2. Build the dependency graph and run topo sort + validation.
        let allDiscovered = perFileDiscovered.flatMap { $0.items }
        let graphResult = buildDependencyGraph(from: allDiscovered)

        // 3. Print skipped (generic) singletons if any — informational.
        let skippedReport = renderSkipped(graphResult.skipped)
        if !skippedReport.isEmpty {
            print("")
            print(skippedReport)
        }

        // 4. Either-or: success prints topological order and emits the
        //    real `_WireGraph.swift`; failure writes validation errors
        //    to stderr, writes no output file, and exits non-zero.
        switch graphResult.outcome {
        case .success(let topologicalOrder):
            print("")
            print(renderTopologicalOrder(topologicalOrder))

            let generated = renderWireGraph(topologicalOrder: topologicalOrder)
            try generated.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("wrote \(outputPath)")
        case .validationFailed(let errors):
            FileHandle.standardError.write(Data("\n".utf8))
            FileHandle.standardError.write(Data(renderValidationErrors(errors).utf8))
            FileHandle.standardError.write(Data("\n".utf8))
            exit(1)
        }
    }
}
