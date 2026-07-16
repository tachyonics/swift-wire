import Foundation
import PackagePlugin

/// `WireContributorPlugin` — SPM build-tool plugin for a Wire **contributor** module: a library that
/// declares bindings and `@Factory` templates for a graph consumer to compose, but builds no graph of
/// its own. It runs `WireGen` in library mode over the module's sources and emits the module's
/// *owned* factory types (`_WireFactory.swift`) — so the module's own controllers' macro-generated
/// wrapping inits resolve against a type declared here rather than in the far-away graph consumer.
/// No graph. (A module's published export interface — and retiring the hand-declared `_WireExports.swift`
/// Wire-awareness marker in favour of manifest-derived detection — is M6; see MultiModuleComposition.md.)
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
/// only when a source changes. It emits only this module's *own* factory types, but composes its
/// Wire-aware dependencies for their **adapter annotations** — a middleware's `.mapsFactoryRoles`
/// vocabulary is declared in the adapter package, and ordering the synthesised `create` needs it. No
/// graph, no binding composition — just the annotation vocabulary.
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

        // Re-parse every Wire-aware library this target directly depends on (same rule as
        // `WireBuildPlugin`) so library mode can read their adapter annotations. Same-package siblings
        // (`.target`) and external products (`.product`) both activate by direct dependency.
        var dependencyGroups: [(module: String, sources: [URL], isExternal: Bool)] = []
        var seenModules: Set<String> = []
        for dependency in target.dependencies {
            let dependencyTargets: [Target]
            let isExternal: Bool
            switch dependency {
            case .target(let dependencyTarget):
                dependencyTargets = [dependencyTarget]
                isExternal = false
            case .product(let dependencyProduct):
                dependencyTargets = dependencyProduct.targets
                isExternal = true
            @unknown default:
                dependencyTargets = []
                isExternal = false
            }
            for dependencyTarget in dependencyTargets {
                guard let dependencyModule = dependencyTarget.sourceModule,
                    !seenModules.contains(dependencyModule.moduleName)
                else { continue }
                let dependencySources = dependencyModule.sourceFiles(withSuffix: "swift").map(\.url)
                let isWireAware = dependencySources.contains { $0.lastPathComponent == "_WireExports.swift" }
                guard isWireAware else { continue }
                seenModules.insert(dependencyModule.moduleName)
                dependencyGroups.append((dependencyModule.moduleName, dependencySources, isExternal))
            }
        }

        let wireGen = try context.tool(named: "WireGen")
        let factoryURL = context.pluginWorkDirectoryURL.appendingPathComponent("_WireFactory.swift")
        var arguments =
            ["--library", factoryURL.path, "--module", sourceModule.moduleName]
            + swiftSources.map(\.path)
        for group in dependencyGroups {
            let flag = group.isExternal ? "--external-module" : "--module"
            arguments += [flag, group.module] + group.sources.map(\.path)
        }

        return [
            .buildCommand(
                displayName: "WireGen \(target.name) (contributor)",
                executable: wireGen.url,
                arguments: arguments,
                inputFiles: swiftSources + dependencyGroups.flatMap(\.sources),
                outputFiles: [factoryURL]
            )
        ]
    }
}
