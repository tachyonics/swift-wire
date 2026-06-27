import Foundation
import PackagePlugin

/// `WireBuildPlugin` — SPM build-tool plugin that runs the `WireGen`
/// executable over every Swift source file in a target and emits
/// `_WireGraph.swift` into the plugin work directory. The generated file
/// is automatically picked up and compiled into the consumer target.
///
/// Consumers opt in per-target:
///
///     .target(
///         name: "App",
///         dependencies: [.product(name: "Wire", package: "swift-wire")],
///         plugins: [.plugin(name: "WireBuildPlugin", package: "swift-wire")]
///     )
///
/// The plugin uses `.buildCommand`, not `.prebuildCommand`: declaring
/// every `.swift` file as an input lets SPM skip the codegen step
/// entirely when nothing has changed, and re-run only when an input
/// changes. The trade-off is that editing a file with no `@Singleton`
/// still triggers a re-run — cheap (parse + walk + emit, milliseconds)
/// and avoids the chicken-and-egg of "only re-run when annotated files
/// change", which would require parsing to know.
@main
struct WireBuildPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        // Source-module targets only — system libraries and binary
        // targets have no `.swift` files for the plugin to scan.
        guard let sourceModule = target.sourceModule else {
            return []
        }

        let swiftSources = sourceModule.sourceFiles(withSuffix: "swift").map { $0.url }

        // No sources → nothing to scan, no command to run. Returning an
        // empty list is the documented way to say "this target doesn't
        // need codegen this build".
        guard !swiftSources.isEmpty else {
            return []
        }

        let graphURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireGraph.swift")
        // Compile-time type assertions for keyed @Inject / @Provides
        // annotations live in a separate file so the bootstrap stays
        // focused on wiring. SPM compiles both into the consumer
        // target automatically.
        let keyChecksURL = context.pluginWorkDirectoryURL.appendingPathComponent(
            "_WireKeyChecks.swift"
        )
        let wireGen = try context.tool(named: "WireGen")

        // Cross-module composition (7d): activation is the dependency.
        // Re-parse the sources of every Wire-aware library this target
        // *directly* depends on so their bindings compose into this
        // target's graph. A library opts in with a `_WireExports.swift`
        // marker. The rule is uniform — same-package siblings (`.target`)
        // and external-package products (`.product`) both activate by
        // direct dependency; transitive dependencies are not
        // auto-activated. See `Documentation/Notes/MultiModuleComposition.md`.
        var dependencyGroups: [(module: String, sources: [URL])] = []
        var seenModules: Set<String> = []
        for dependency in target.dependencies {
            let dependencyTargets: [Target]
            switch dependency {
            case .target(let dependencyTarget):
                dependencyTargets = [dependencyTarget]
            case .product(let dependencyProduct):
                dependencyTargets = dependencyProduct.targets
            @unknown default:
                dependencyTargets = []
            }
            for dependencyTarget in dependencyTargets {
                guard let dependencyModule = dependencyTarget.sourceModule,
                    !seenModules.contains(dependencyModule.moduleName)
                else { continue }
                let dependencySources = dependencyModule.sourceFiles(withSuffix: "swift").map(\.url)
                let isWireAware = dependencySources.contains {
                    $0.lastPathComponent == "_WireExports.swift"
                }
                guard isWireAware else { continue }
                seenModules.insert(dependencyModule.moduleName)
                dependencyGroups.append((dependencyModule.moduleName, dependencySources))
            }
        }

        let allInputFiles = swiftSources + dependencyGroups.flatMap(\.sources)

        // Soft warning for very large targets. SPM passes these as argv
        // to WireGen; macOS/Linux `ARG_MAX` is ~1MB combined args+env,
        // so paths × ~200 chars start to bite around 5,000+ files.
        // Realistic Wire consumers won't hit this, but if they do the
        // failure (`E2BIG` from exec) is opaque without context — the
        // fix is to teach WireGen a `@filelist.txt` response-file form
        // and have the plugin write that instead of stuffing argv.
        if allInputFiles.count > 5000 {
            Diagnostics.warning(
                "WireBuildPlugin: \(allInputFiles.count) Swift sources (target + Wire-aware dependencies), approaching argv limits. If WireGen exec fails with E2BIG, file an issue."
            )
        }

        // Sources are grouped by `--module`: the consumer first, then each
        // Wire-aware dependency. WireGen stamps every binding with its
        // group's module (origin module — load-bearing for cross-module
        // composition; see MultiModuleComposition.md).
        var arguments =
            [graphURL.path, keyChecksURL.path, "--module", sourceModule.moduleName]
            + swiftSources.map(\.path)
        for group in dependencyGroups {
            arguments += ["--module", group.module] + group.sources.map(\.path)
        }

        return [
            .buildCommand(
                displayName: "WireGen \(target.name)",
                executable: wireGen.url,
                arguments: arguments,
                inputFiles: allInputFiles,
                outputFiles: [graphURL, keyChecksURL]
            )
        ]
    }
}
