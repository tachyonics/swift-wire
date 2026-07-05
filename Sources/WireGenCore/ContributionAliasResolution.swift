import SwiftSyntax

// Contribution-alias resolution — the M2.3 replacement for the `_wireRegister`
// side-effect. An adapter declares `WireAdapterAnnotationV1(annotation: "X",
// contributesTo: key)`, meaning the attribute `@X` on a binding is an alias for
// `@Contributes(to: key)`. Use-sites are captured name-agnostically (the defining
// module may differ from the use module), then classified against the declared
// aliases after aggregation, injecting a synthetic contribution onto each matched
// binding so it flows through the ordinary multibinding fan-in — no new emission.

/// A candidate contribution-alias use-site: an attribute on a type declaration,
/// captured before it's matched against a declared alias.
package struct ContributionAliasUseSite: Sendable, Equatable {
    package let annotationName: String
    package let qualifiedTypeName: String
    package let location: SourceLocation
    package let originModule: String

    package init(
        annotationName: String,
        qualifiedTypeName: String,
        location: SourceLocation,
        originModule: String
    ) {
        self.annotationName = annotationName
        self.qualifiedTypeName = qualifiedTypeName
        self.location = location
        self.originModule = originModule
    }
}

/// Capture every attribute on a type declaration as an alias candidate.
/// Classification against declared aliases (by name) happens after aggregation, so
/// non-alias attributes captured here are harmless — they simply never match.
func scanContributionAliasUseSites(
    qualifiedTypeName: String,
    attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter,
    module: String
) -> [ContributionAliasUseSite] {
    var sites: [ContributionAliasUseSite] = []
    for element in attributes {
        guard let attribute = element.as(AttributeSyntax.self) else { continue }
        sites.append(
            ContributionAliasUseSite(
                annotationName: attribute.attributeName.trimmedDescription,
                qualifiedTypeName: qualifiedTypeName,
                location: makeSourceLocation(of: attribute, sourcePath: sourcePath, converter: converter),
                originModule: module
            )
        )
    }
    return sites
}

/// Inject a synthetic `@Contributes` for each use-site whose attribute matches a
/// declared contribution alias, so aliased bindings flow through the multibinding
/// fan-in. Non-alias attributes never match and are ignored.
/// Apply `injectAliasContributions` across every partition's bindings.
package func applyAliasContributions(
    to allBindings: [Partition: [DiscoveredBinding]],
    aliases: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [Partition: [DiscoveredBinding]] {
    allBindings.mapValues { injectAliasContributions(into: $0, aliases: aliases, useSites: useSites) }
}

func injectAliasContributions(
    into bindings: [DiscoveredBinding],
    aliases: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [DiscoveredBinding] {
    var keyByAnnotation: [String: String] = [:]
    for alias in aliases {
        keyByAnnotation[alias.annotationName] = alias.contributesToKey
    }
    guard !keyByAnnotation.isEmpty else { return bindings }

    var keysByType: [String: [String]] = [:]
    for site in useSites {
        if let key = keyByAnnotation[site.annotationName] {
            keysByType[site.qualifiedTypeName, default: []].append(key)
        }
    }
    guard !keysByType.isEmpty else { return bindings }

    return bindings.map { binding in
        guard let typeName = binding.scopeBoundQualifiedTypeName,
            let keys = keysByType[typeName], !keys.isEmpty
        else { return binding }
        let extra = keys.map { Contribution(keyReference: $0, location: binding.location) }
        return binding.appendingContributions(extra)
    }
}

extension DiscoveredBinding {
    /// The qualified type name for a scope-bound (type) binding, else `nil` —
    /// contribution aliases attach to type declarations only.
    var scopeBoundQualifiedTypeName: String? {
        if case let .scopeBound(type) = self { return type.qualifiedTypeName }
        return nil
    }

    /// A copy with `extra` contributions appended (scope-bound and provider
    /// bindings carry contributions; aggregates are synthesised, unchanged).
    func appendingContributions(_ extra: [Contribution]) -> DiscoveredBinding {
        switch self {
        case .scopeBound(let type): return .scopeBound(type.appendingContributions(extra))
        case .provider(let provider): return .provider(provider.appendingContributions(extra))
        case .aggregate: return self
        }
    }
}

extension DiscoveredScopeBoundType {
    func appendingContributions(_ extra: [Contribution]) -> DiscoveredScopeBoundType {
        DiscoveredScopeBoundType(
            typeName: typeName,
            qualifiedTypeName: qualifiedTypeName,
            typeKind: typeKind,
            genericParameterNames: genericParameterNames,
            genericParameterConstraints: genericParameterConstraints,
            explicitIdentity: explicitIdentity,
            dependencies: dependencies,
            location: location,
            scopeKey: scopeKey,
            initIsAsync: initIsAsync,
            initIsThrowing: initIsThrowing,
            memberInjections: memberInjections,
            accessLevel: accessLevel,
            contributions: contributions + extra,
            allowUnused: allowUnused,
            teardown: teardown,
            originModule: originModule
        )
    }
}

extension DiscoveredProvider {
    func appendingContributions(_ extra: [Contribution]) -> DiscoveredProvider {
        DiscoveredProvider(
            boundType: boundType,
            accessPath: accessPath,
            form: form,
            dependencies: dependencies,
            genericParameterNames: genericParameterNames,
            location: location,
            keyIdentifier: keyIdentifier,
            concreteGenericArguments: concreteGenericArguments,
            isAsync: isAsync,
            isThrowing: isThrowing,
            accessLevel: accessLevel,
            scopeKey: scopeKey,
            contributions: contributions + extra,
            allowUnused: allowUnused,
            teardown: teardown,
            originModule: originModule
        )
    }
}
