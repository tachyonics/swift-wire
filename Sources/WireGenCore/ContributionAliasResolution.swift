import SwiftSyntax

// Contribution-alias resolution — the M2.3 replacement for the `_wireRegister`
// side-effect. An adapter declares `WireAdapterAnnotationV1(annotation: "X",
// contributesTo: key)`, meaning the attribute `@X` on a binding is an alias for
// `@Contributes(to: key)`. Use-sites are captured name-agnostically (the defining
// module may differ from the use module), then classified against the declared
// aliases after aggregation, injecting a synthetic contribution onto each matched
// binding so it flows through the ordinary multibinding fan-in — no new emission.

/// A candidate contribution-alias use-site: an attribute on a binding declaration —
/// a scope-bound type, or a `@Provides` function/property — captured before it's
/// matched against a declared alias.
package struct ContributionAliasUseSite: Sendable, Equatable {
    package let annotationName: String
    /// The identity of the binding the attribute sits on: a qualified type name for
    /// a scope-bound type, or the `@Provides` access path for a provider. Matched
    /// against `DiscoveredBinding.aliasTargetIdentity` after aggregation.
    package let targetIdentity: String
    package let location: SourceLocation
    package let originModule: String

    package init(
        annotationName: String,
        targetIdentity: String,
        location: SourceLocation,
        originModule: String
    ) {
        self.annotationName = annotationName
        self.targetIdentity = targetIdentity
        self.location = location
        self.originModule = originModule
    }
}

/// Capture every attribute on a binding declaration as an alias candidate, tagged
/// with the binding's identity (a type name, or a `@Provides` access path).
/// Classification against declared aliases (by name) happens after aggregation, so
/// non-alias attributes captured here are harmless — they simply never match.
func scanContributionAliasUseSites(
    targetIdentity: String,
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
                targetIdentity: targetIdentity,
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

    var keysByIdentity: [String: [String]] = [:]
    for site in useSites {
        if let key = keyByAnnotation[site.annotationName] {
            keysByIdentity[site.targetIdentity, default: []].append(key)
        }
    }
    guard !keysByIdentity.isEmpty else { return bindings }

    return bindings.map { binding in
        guard let identity = binding.aliasTargetIdentity,
            let keys = keysByIdentity[identity], !keys.isEmpty
        else { return binding }
        let extra = keys.map { Contribution(keyReference: $0, location: binding.location) }
        return binding.appendingContributions(extra)
    }
}

extension DiscoveredBinding {
    /// The identity a contribution-alias use-site matches against: a scope-bound
    /// type's qualified name, or a provider's `@Provides` access path. `nil` for a
    /// synthesised aggregate (nothing to alias).
    var aliasTargetIdentity: String? {
        switch self {
        case .scopeBound(let type): return type.qualifiedTypeName
        case .provider(let provider): return provider.accessPath
        case .aggregate: return nil
        }
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
