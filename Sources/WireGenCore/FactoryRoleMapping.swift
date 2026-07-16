// Factory role-mapping computation — the join of a `.mapsFactoryRoles` annotation (the adapter's
// ordered role vocabulary) to a `@Factory` template, producing the per-parameter role assignment the
// emitter uses to order the synthesised `create` (M5.3, 3.2). Domain-free: roles are opaque ordered
// identifiers supplied by the adapter.

/// A generic parameter is *injected* iff it appears in an `@Inject` dependency's type (bare, or as a
/// generic argument — the 3.3 injected axis); every other generic parameter is *assisted* (a box role).
/// In 3.2 the deps are concrete, so this is the full generic-parameter list — but computing it now keeps
/// the validation correct and readies 3.3.
func assistedParameters(of template: DiscoveredFactoryTemplate) -> [String] {
    let dependencyTypes = template.dependencies.map { canonicalTypeName($0.type) }
    return template.genericParameterNames.filter { parameter in
        !dependencyTypes.contains { type in
            type == parameter || parameterAppearsAsGenericArgument(parameter, in: type)
        }
    }
}

/// The use-site reference for a canonical role — `.` + the role name lower-cameled
/// (`RequestContext` → `.requestContext`). The `@X(.role, …)` custom form references roles this way.
func roleReference(_ roleName: String) -> String {
    guard let first = roleName.first else { return "." }
    return "." + first.lowercased() + roleName.dropFirst()
}

/// Assign each assisted parameter a role. A **bare** use-site (no arguments) maps by order —
/// `assisted[i] → canonicalRoles[i]` (the positional default). A **custom** use-site maps by the listed
/// roles, positional over the assisted parameters — `assisted[i] → the role whose reference is
/// `useSiteArguments[i]``. Best-effort: a parameter with no corresponding role (too few arguments, or an
/// unrecognised reference) is simply left unmapped, which `factoryRoleMappingDiagnostics` reports.
func factoryRoleMapping(
    assistedParameters: [String],
    useSiteArguments: [String],
    canonicalRoles: [String]
) -> FactoryRoleMapping {
    var parameterRoles: [String: String] = [:]
    if useSiteArguments.isEmpty {
        for (index, parameter) in assistedParameters.enumerated() where index < canonicalRoles.count {
            parameterRoles[parameter] = canonicalRoles[index]
        }
    } else {
        for (index, parameter) in assistedParameters.enumerated() where index < useSiteArguments.count {
            if let role = canonicalRoles.first(where: { roleReference($0) == useSiteArguments[index] }) {
                parameterRoles[parameter] = role
            }
        }
    }
    return FactoryRoleMapping(canonicalRoles: canonicalRoles, parameterRoles: parameterRoles)
}

/// Join each `@Factory` template to its role-mapping use-site (a `.mapsFactoryRoles` annotation's
/// attribute sitting on the same type — matched by `targetIdentity == qualifiedTypeName`) → a mapping
/// per factory key. Empty when no role-mapping annotation is visible (e.g. a build that doesn't compose
/// the adapter): those factories keep the positional `create`.
func factoryRoleMappings(
    templates: [DiscoveredFactoryTemplate],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [String: FactoryRoleMapping] {
    var rolesByAnnotation: [String: [String]] = [:]
    for annotation in annotations {
        if case .mapsFactoryRoles(let roles) = annotation.capability {
            rolesByAnnotation[annotation.annotationName] = roles
        }
    }
    guard !rolesByAnnotation.isEmpty else { return [:] }

    var mappings: [String: FactoryRoleMapping] = [:]
    for template in templates {
        guard
            let site = useSites.first(where: {
                rolesByAnnotation[$0.annotationName] != nil && $0.targetIdentity == template.qualifiedTypeName
            }),
            let roles = rolesByAnnotation[site.annotationName]
        else { continue }
        mappings[template.keyReference] = factoryRoleMapping(
            assistedParameters: assistedParameters(of: template),
            useSiteArguments: site.arguments,
            canonicalRoles: roles
        )
    }
    return mappings
}

/// Validate the role mappings of templates owned by `owningModule`: every assisted parameter must be
/// assigned a role (the custom list too short, or an unrecognised role reference, leaves one unmapped).
/// Errors, so the build fails before the mis-ordered `create` reaches the compiler. Only fires where the
/// `.mapsFactoryRoles` annotation is visible (a build that composes the adapter); a template with no
/// mapping keeps the positional `create` and isn't validated here.
package func factoryRoleMappingDiagnostics(
    templates: [DiscoveredFactoryTemplate],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite],
    owningModule: String
) -> [Diagnostic] {
    let mappings = factoryRoleMappings(templates: templates, annotations: annotations, useSites: useSites)
    var diagnostics: [Diagnostic] = []
    for template in templates where template.originModule == owningModule {
        guard let mapping = mappings[template.keyReference] else { continue }
        for parameter in assistedParameters(of: template) where mapping.parameterRoles[parameter] == nil {
            diagnostics.append(
                Diagnostic(
                    location: template.location,
                    message:
                        "@Factory '\(template.typeName)': assisted generic parameter '\(parameter)' has no role. The role mapping must assign one role per assisted parameter (a bare mapping assigns them in order; the custom form lists a role per parameter).",
                    severity: .error
                )
            )
        }
    }
    return diagnostics.sorted { $0.location < $1.location }
}
