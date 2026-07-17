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
            genericWhereClause: genericWhereClause,
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

/// Inject a synthetic dependency for each `.injectsFromGraph` use-site whose argument names an existing
/// binding — the *non-factory* half of the capability's dispatch. `@X(T.self)` appends an unkeyed
/// dependency on `T`; `@X(K)` where `K` is a `BindingKey<T>` appends a dependency on `T` keyed `K`. A
/// factory-key argument is skipped here (the factory-synthesis pass lifts it); an argument that is
/// neither `.self`, a known binding key, nor a factory key is left alone. Mirror of `applyAliasContributions`;
/// runs before graphs build.
package func applyAdapterDependencies(
    to allBindings: [Partition: [DiscoveredBinding]],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite],
    bindingKeys: [DiscoveredBindingKey]
) -> [Partition: [DiscoveredBinding]] {
    allBindings.mapValues {
        injectAdapterDependencies(into: $0, annotations: annotations, useSites: useSites, bindingKeys: bindingKeys)
    }
}

func injectAdapterDependencies(
    into bindings: [DiscoveredBinding],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite],
    bindingKeys: [DiscoveredBindingKey]
) -> [DiscoveredBinding] {
    let graphAnnotations = Set(
        annotations.filter { $0.capability == .injectsFromGraph }.map(\.annotationName)
    )
    guard !graphAnnotations.isEmpty else { return bindings }
    let bindingKeysByReference = Dictionary(bindingKeys.map { ($0.keyReference, $0) }, uniquingKeysWith: { first, _ in first })

    var depsByIdentity: [String: [DependencyParameter]] = [:]
    for site in useSites where graphAnnotations.contains(site.annotationName) {
        guard let argument = site.argument, let dep = adapterBindingDependency(argument, at: site.location, bindingKeysByReference: bindingKeysByReference) else { continue }
        depsByIdentity[site.targetIdentity, default: []].append(dep)
    }
    guard !depsByIdentity.isEmpty else { return bindings }

    return bindings.map { binding in
        guard let identity = binding.aliasTargetIdentity,
            let deps = depsByIdentity[identity], !deps.isEmpty
        else { return binding }
        return binding.appendingDependencies(deps)
    }
}

/// The binding dependency an `.injectsFromGraph` argument selects, or `nil` when the argument is a
/// factory key (lifted by factory synthesis) or an unknown reference. `T.self` → an unkeyed dependency
/// on `T`; a `BindingKey<T>` reference → a dependency on `T` keyed by the reference.
private func adapterBindingDependency(
    _ argument: String,
    at location: SourceLocation,
    bindingKeysByReference: [String: DiscoveredBindingKey]
) -> DependencyParameter? {
    if argument.hasSuffix(".self") {
        let type = adapterDependencyType(from: argument)
        return DependencyParameter(
            name: syntheticDependencyName(forType: type), type: type,
            kind: .injectInitParameter, location: location)
    }
    if let bindingKey = bindingKeysByReference[argument], let type = bindingKey.typeArgument {
        return DependencyParameter(
            name: syntheticDependencyName(forKey: argument), type: type,
            kind: .injectInitParameter, location: location, keyIdentifier: argument)
    }
    return nil
}

/// The referenced type in an adapter-dependency `.self` argument: strip a trailing
/// `.self` (`"SomeType.self"` → `"SomeType"`).
func adapterDependencyType(from argument: String) -> String {
    argument.hasSuffix(".self") ? String(argument.dropLast(".self".count)) : argument
}

/// The init-parameter label for a by-type adapter dependency — deterministic so the proxy field and the
/// adapter's witness agree. `_wire`-prefixed upper-cameled simple type name, so it can't collide with a
/// user `@Inject`.
func syntheticDependencyName(forType type: String) -> String {
    let withoutGenerics = type.prefix { $0 != "<" }  // "Mod.Foo<A>" -> "Mod.Foo"
    let simple = withoutGenerics.split(separator: ".").last.map(String.init) ?? String(withoutGenerics)
    return "_wire" + simple.prefix(1).uppercased() + simple.dropFirst()  // e.g. _wireSomeType
}

/// The init-parameter label for a keyed adapter dependency — `_wire` + the sanitised key
/// (`Database.primary` → `_wireDatabase_primary`), distinct across keys so two keyed bindings of the same
/// type don't collide.
func syntheticDependencyName(forKey keyReference: String) -> String {
    "_wire" + sanitizedKeyFragment(keyReference)
}
