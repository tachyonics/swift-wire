import Foundation
import PackagePlugin

/// `WireContributorPlugin` — SPM build-tool plugin for a Wire **contributor** module: a library that
/// declares bindings and `@Factory` templates for a graph consumer to compose, but builds no graph of
/// its own. It runs `WireGen` in library mode over the module's sources and emits the module's
/// *owned* factory types (`_WireFactory.swift`) — so the module's own controllers' macro-generated
/// wrapping inits resolve against a type declared here rather than in the far-away graph consumer —
/// plus an exports placeholder (the module's published export interface is M6). No graph.
///
/// Contributor vs graph consumer is an *architectural* choice — which module calls `Wire.bootstrap()`
/// — not a property of target kind, so it's explicit: a composition root applies `WireBuildPlugin`; a
/// contributor applies this. A module needs this plugin when it declares `@Factory` templates whose
/// factory types its (or a downstream package's) controllers reference.
///
///     .target(
///         name: "Controllers",
///         dependencies: [.product(name: "Wire", package: "swift-wire")],
///         plugins: [.plugin(name: "WireContributorPlugin", package: "swift-wire")]
///     )
///
/// Like `WireBuildPlugin` this is a `.buildCommand` keyed on the module's sources, so SPM re-runs it
/// only when a source changes. Own sources only — a contributor's factory types are template-driven
/// and need no dependency graph.
@main
struct WireContributorPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        // Source-module targets only — system/binary targets have no `.swift` files to scan.
        guard let sourceModule = target.sourceModule else {
            return []
        }

        let swiftSources = sourceModule.sourceFiles(withSuffix: "swift").map { $0.url }
        guard !swiftSources.isEmpty else {
            return []
        }

        let wireGen = try context.tool(named: "WireGen")
        let factoryURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireFactory.swift")
        // Empty for now — the export interface a module publishes to a consumer's graph is M6 (the
        // presence marker in the module's sources still drives Wire-awareness detection).
        let exportsURL = context.pluginWorkDirectoryURL.appendingPathComponent(
            "_WireGeneratedExports.swift"
        )
        let arguments =
            ["--library", factoryURL.path, exportsURL.path, "--module", sourceModule.moduleName]
            + swiftSources.map(\.path)

        return [
            .buildCommand(
                displayName: "WireGen \(target.name) (contributor)",
                executable: wireGen.url,
                arguments: arguments,
                inputFiles: swiftSources,
                outputFiles: [factoryURL, exportsURL]
            )
        ]
    }
}
