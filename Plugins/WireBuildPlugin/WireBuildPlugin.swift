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

        let outputURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireGraph.swift")
        let wireGen = try context.tool(named: "WireGen")

        // Soft warning for very large targets. SPM passes these as argv
        // to WireGen; macOS/Linux `ARG_MAX` is ~1MB combined args+env,
        // so paths × ~200 chars start to bite around 5,000+ files.
        // Realistic Wire consumers won't hit this, but if they do the
        // failure (`E2BIG` from exec) is opaque without context — the
        // fix is to teach WireGen a `@filelist.txt` response-file form
        // and have the plugin write that instead of stuffing argv.
        if swiftSources.count > 5000 {
            Diagnostics.warning(
                "WireBuildPlugin: target has \(swiftSources.count) Swift sources, approaching argv limits. If WireGen exec fails with E2BIG, file an issue."
            )
        }

        // Pass the SPM target name as the module name. WireGen uses it
        // to module-qualify every reference to a user-supplied symbol
        // in the generated bootstrap. Iteration 7 will extend this to
        // per-binding origin modules; for now there's a single qualifier.
        return [
            .buildCommand(
                displayName: "WireGen \(target.name)",
                executable: wireGen.url,
                arguments: [outputURL.path, target.name] + swiftSources.map { $0.path },
                inputFiles: swiftSources,
                outputFiles: [outputURL]
            )
        ]
    }
}
