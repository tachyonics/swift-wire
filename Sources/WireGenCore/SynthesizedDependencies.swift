// Synthesising an INPUT edge onto a binding — the symmetric complement of `appendingContributions`
// (which appends synthetic OUTPUTS / `@Contributes`). An adapter annotation that reads a type argument
// can declare "the annotated binding depends on this type," and the plugin appends that dependency here,
// exactly as the contribution-alias pass appends an output. Domain-free: a binding, a dependency type,
// an input edge.

extension DiscoveredBinding {
    /// Return a copy of this binding with `extra` appended to its init-time dependencies. Only scope-bound
    /// bindings (`@Singleton`/`@Scoped` types) can receive a synthesized dependency; providers and
    /// synthesized aggregates are returned unchanged.
    func appendingDependencies(_ extra: [DependencyParameter]) -> DiscoveredBinding {
        switch self {
        case .scopeBound(let type): return .scopeBound(type.appendingDependencies(extra))
        case .provider, .aggregate: return self
        }
    }
}

extension DiscoveredScopeBoundType {
    func appendingDependencies(_ extra: [DependencyParameter]) -> DiscoveredScopeBoundType {
        DiscoveredScopeBoundType(
            typeName: typeName,
            qualifiedTypeName: qualifiedTypeName,
            typeKind: typeKind,
            genericParameterNames: genericParameterNames,
            genericParameterConstraints: genericParameterConstraints,
            explicitIdentity: explicitIdentity,
            dependencies: dependencies + extra,
            location: location,
            scopeKey: scopeKey,
            initIsAsync: initIsAsync,
            initIsThrowing: initIsThrowing,
            memberInjections: memberInjections,
            accessLevel: accessLevel,
            contributions: contributions,
            allowUnused: allowUnused,
            teardown: teardown,
            originModule: originModule
        )
    }
}

/// Inject a synthetic dependency for each use-site whose attribute matches a declared
/// adapter-dependency (`WireAdapterDependencyV1`). `@X(T.self)` on a binding appends a
/// dependency on `T` — delivered at construction through a wrapping init the adapter's
/// macro generates. Mirror of `applyAliasContributions`; runs before graphs build.
package func applyAdapterDependencies(
    to allBindings: [Partition: [DiscoveredBinding]],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [Partition: [DiscoveredBinding]] {
    allBindings.mapValues { injectAdapterDependencies(into: $0, annotations: annotations, useSites: useSites) }
}

func injectAdapterDependencies(
    into bindings: [DiscoveredBinding],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [DiscoveredBinding] {
    let dependencyAnnotations = Set(
        annotations.filter { $0.capability == .injectsDependencyOnArgument }.map(\.annotationName)
    )
    guard !dependencyAnnotations.isEmpty else { return bindings }

    var depsByIdentity: [String: [DependencyParameter]] = [:]
    for site in useSites where dependencyAnnotations.contains(site.annotationName) {
        guard let argument = site.argument else { continue }
        let referencedType = adapterDependencyType(from: argument)
        depsByIdentity[site.targetIdentity, default: []].append(
            DependencyParameter(
                name: syntheticDependencyName(forType: referencedType),
                type: referencedType,
                kind: .injectInitParameter,
                location: site.location
            )
        )
    }
    guard !depsByIdentity.isEmpty else { return bindings }

    return bindings.map { binding in
        guard let identity = binding.aliasTargetIdentity,
            let deps = depsByIdentity[identity], !deps.isEmpty
        else { return binding }
        return binding.appendingDependencies(deps)
    }
}

/// The referenced type in an adapter-dependency attribute argument: strip a trailing
/// `.self` (`"SomeFactory.self"` → `"SomeFactory"`).
func adapterDependencyType(from argument: String) -> String {
    argument.hasSuffix(".self") ? String(argument.dropLast(".self".count)) : argument
}

/// The init-parameter label for a synthesized adapter dependency — deterministic so the
/// adapter's macro-generated wrapping init can name the matching parameter. `_wire`-
/// prefixed lowerCamelCase of the type, so it can't collide with a user `@Inject`.
func syntheticDependencyName(forType type: String) -> String {
    let withoutGenerics = type.prefix { $0 != "<" }  // "Mod.Foo<A>" -> "Mod.Foo"
    let simple = withoutGenerics.split(separator: ".").last.map(String.init) ?? String(withoutGenerics)
    return "_wire" + simple.prefix(1).uppercased() + simple.dropFirst()  // e.g. _wireSomeFactory
}
