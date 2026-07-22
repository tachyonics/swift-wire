// Cross-module visibility threshold (iteration 7f). A binding composed
// from another module is referenced by the consumer's generated graph,
// which lives in the consumer module — so its access level must clear a
// higher bar than the in-module `internal` floor (5α): `package` for a
// same-package sibling, `public` for a library in an external package
// (`package` doesn't reach across packages).
//
// `private`/`fileprivate` are already caught by 5α's declaration-too-
// private error (they fail even in-module), so this check covers only the
// cross-module-specific cases — an `internal` foreign binding, and a
// `package` binding from an external package — with messaging tailored to
// whether the origin is a sibling or an external-package module
// (Option Y: Wire gives the precise message rather than letting the Swift
// compiler reject the generated reference). The `externalModules` set is a
// consumer-build property the plugin supplies (it knows `.product` deps
// from `.target` siblings), not a per-binding fact, so it doesn't enter
// the binding model or a future M7a manifest.

package func crossModuleVisibilityDiagnostics(
    bindings: [DiscoveredBinding],
    consumerModule: String,
    externalModules: Set<String>
) -> [Diagnostic] {
    var diagnostics: [Diagnostic] = []
    for binding in bindings {
        // Synthesised aggregates have no source declaration to gate.
        if case .aggregate = binding { continue }
        let origin = binding.originModule
        // Own-module bindings keep the in-module `internal` floor (5α).
        guard origin != consumerModule else { continue }

        let access = binding.accessLevel
        let typeName = binding.boundType
        if externalModules.contains(origin) {
            // External package: needs `public`; `internal`/`package` fail.
            guard access == .internal || access == .package else { continue }
            diagnostics.append(
                Diagnostic(
                    location: binding.location,
                    message:
                        "'\(typeName)' is '\(access.keyword)' but is composed into module '\(consumerModule)' from external-package module '\(origin)' — '\(access.keyword)' isn't visible across packages. Make it 'public'.",
                    severity: .error
                )
            )
        } else {
            // Same-package sibling: needs at least `package`; `internal` fails.
            guard access == .internal else { continue }
            diagnostics.append(
                Diagnostic(
                    location: binding.location,
                    message:
                        "'\(typeName)' is 'internal' but is composed into module '\(consumerModule)' from sibling module '\(origin)' — cross-module references need at least 'package'. Make it 'package' or 'public'.",
                    severity: .error
                )
            )
        }
    }
    return diagnostics.sorted { $0.location < $1.location }
}
