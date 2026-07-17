// Factory synthesis — the consumer-driven half of the factory model, riding the
// `.injectsFactoryOnArgument` capability.
//
// A `@Factory(key)` template defines a factory; it synthesises nothing on its own.
// The consumers are `@X(key)` use-sites of an annotation declaring
// `.injectsFactoryOnArgument` (WireMVC's `@Middleware`). This pass collates those
// use-sites, dedupes by key, and for each consumed key that matches a template:
//
//   1. synthesises ONE concrete factory struct (`_WireFactory_<key>`) holding the
//      template's `@Inject` deps and exposing a generic `create` whose assisted
//      parameters are the template's generic parameters (as metatypes);
//   2. registers it as an ordinary binding, so its deps resolve like any binding's
//      and it is constructed once per graph that uses it (deduped across consumers);
//   3. appends an input edge onto each consuming binding — a dependency on the
//      synthesised factory type, delivered through the adapter macro's wrapping init.
//
// Everything here is domain-free: Wire injects a synthesised binding onto a
// decorated binding and never learns "middleware".

/// The role mapping a `.mapsFactoryRoles` annotation supplies for a factory template (M5.3, 3.2).
/// `canonicalRoles` is the adapter's full ordered role vocabulary — the names `create`'s generic
/// parameters take, in the fixed order the consumer's macro calls with. `parameterRoles` maps each of
/// the template's assisted generic parameters to its role name (a subset/reorder of `canonicalRoles`);
/// a role not in its values is unused by this template (a phantom `create` parameter). `nil` on a
/// factory means no mapping was visible — `create` keeps the positional-declaration-order form.
package struct FactoryRoleMapping: Sendable, Equatable {
    package let canonicalRoles: [String]
    package let parameterRoles: [String: String]

    package init(canonicalRoles: [String], parameterRoles: [String: String]) {
        self.canonicalRoles = canonicalRoles
        self.parameterRoles = parameterRoles
    }
}

/// A factory the plugin synthesises for one consumed `FactoryKey`. Carries what
/// both the emitter (the struct declaration) and the binding registration
/// (construction of the template's deps) need.
package struct SynthesizedFactory: Sendable {
    /// The canonical key text the factory is derived from (`MyMiddleware.session`).
    package let keyReference: String
    /// The synthesised concrete type name (`_WireFactory_MyMiddleware_session`).
    package let factoryTypeName: String
    /// The middleware type the factory produces — the template's qualified name
    /// (`SessionMiddleware`).
    package let producedTypeName: String
    /// The produced type's generic parameters, in declaration order. Split into two axes: the *injected*
    /// parameters become the factory struct's own generics (resolved from the graph), the rest are
    /// *assisted* (box-role) parameters on `create`.
    package let parameterNames: [String]
    /// Per-parameter protocol constraint (the inheritance clause) for any parameter that declares one.
    package let parameterConstraints: [String: String]
    /// The parameters resolved from the graph — a parameter is injected iff it appears (bare or as a
    /// generic argument) in an `@Inject` member's type. These are the factory struct's own generics,
    /// threaded from the graph's lift parameter; the rest are assisted (a box role) and live on `create`.
    package let injectedParameterNames: [String]
    /// The template's `where`-clause requirements (associated-type / same-type /
    /// `~Copyable`), verbatim and without the `where` keyword, or `nil` — restated
    /// on `create` after the per-parameter constraints.
    package let whereClause: String?
    /// The injected dependencies — the template's `@Inject` members, resolved once
    /// when the factory is constructed. Carried verbatim (keys included) so the
    /// factory binding resolves them exactly as the template would have.
    package let dependencies: [DependencyParameter]
    /// The module the produced (template) middleware type lives in. The graph consumer imports it when
    /// foreign so the consumer-emitted factory type — whose `create` returns that middleware — resolves.
    package let producedTypeModule: String
    /// The template's declaration site, stamped onto the synthesised binding.
    package let location: SourceLocation
    /// The role mapping, when a `.mapsFactoryRoles` annotation was joined to the template. `nil` keeps
    /// `create` in positional-declaration-order form (3.1 / no mapping visible).
    package let roleMapping: FactoryRoleMapping?

    /// The assisted (box-role) parameters — every produced-type parameter that isn't injected, in
    /// declaration order. These are `create`'s generics.
    package var assistedParameterNames: [String] {
        parameterNames.filter { !injectedParameterNames.contains($0) }
    }
    /// The assisted parameters' constraints (restated on `create`).
    package var assistedParameterConstraints: [String: String] {
        parameterConstraints.filter { !injectedParameterNames.contains($0.key) }
    }
    /// The injected parameters' constraints (stated on the factory struct's own generics).
    package var injectedParameterConstraints: [String: String] {
        parameterConstraints.filter { injectedParameterNames.contains($0.key) }
    }

    package init(
        keyReference: String,
        factoryTypeName: String,
        producedTypeName: String,
        parameterNames: [String],
        parameterConstraints: [String: String],
        injectedParameterNames: [String] = [],
        whereClause: String? = nil,
        dependencies: [DependencyParameter],
        producedTypeModule: String,
        location: SourceLocation,
        roleMapping: FactoryRoleMapping? = nil
    ) {
        self.keyReference = keyReference
        self.factoryTypeName = factoryTypeName
        self.producedTypeName = producedTypeName
        self.parameterNames = parameterNames
        self.parameterConstraints = parameterConstraints
        self.injectedParameterNames = injectedParameterNames
        self.whereClause = whereClause
        self.dependencies = dependencies
        self.producedTypeModule = producedTypeModule
        self.location = location
        self.roleMapping = roleMapping
    }
}

/// Build the `SynthesizedFactory` for one `@Factory` template — the single source of truth
/// both type emission (template-driven) and construction (consumer-driven) derive from. `roleMapping`
/// is the joined `.mapsFactoryRoles` mapping when one is visible, else `nil` (positional `create`).
func synthesizedFactory(
    from template: DiscoveredFactoryTemplate,
    roleMapping: FactoryRoleMapping? = nil
) -> SynthesizedFactory {
    let assisted = Set(assistedParameters(of: template))
    return SynthesizedFactory(
        keyReference: template.keyReference,
        factoryTypeName: factoryTypeName(forKey: template.keyReference),
        producedTypeName: template.qualifiedTypeName,
        parameterNames: template.genericParameterNames,
        parameterConstraints: template.genericParameterConstraints,
        injectedParameterNames: template.genericParameterNames.filter { !assisted.contains($0) },
        whereClause: template.genericWhereClause,
        dependencies: template.dependencies,
        producedTypeModule: template.originModule,
        location: template.location,
        roleMapping: roleMapping
    )
}

/// Render the factory-type declarations the graph consumer emits into its generated file — one per
/// *consumed* factory (the synthesised set), regardless of which module declared the `@Factory` template.
/// A factory type is consumer-local (constructed by this graph, stored on this graph's proxy), so it's
/// declared `internal` even for a template that lives in a shared library, and each consumer declares its
/// own copy (independent graphs; the duplication is harmless). Deterministic order by key.
package func renderConsumedFactoryTypes(_ factories: [SynthesizedFactory]) -> [String] {
    factories
        .sorted { $0.keyReference < $1.keyReference }
        .map(renderFactoryDeclaration)
}

/// Sanitise a key reference into an identifier fragment — every character outside
/// `[A-Za-z0-9_]` becomes `_`. `MyMiddleware.session` → `MyMiddleware_session`.
/// Deterministic and collision-free across distinct keys, so the same key always
/// derives the same factory type on both the synthesis side and the adapter
/// macro's call side.
func sanitizedKeyFragment(_ keyReference: String) -> String {
    String(keyReference.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
}

/// The synthesised factory type name for a key: `_WireFactory_<sanitized key>`.
func factoryTypeName(forKey keyReference: String) -> String {
    "_WireFactory_" + sanitizedKeyFragment(keyReference)
}

/// The init-parameter label the factory is injected under on a consuming binding:
/// `_wireFactory_<sanitized key>`. The adapter macro's wrapping init names the
/// matching parameter, so the label is a contract shared by both sides.
func factoryDependencyName(forKey keyReference: String) -> String {
    "_wireFactory_" + sanitizedKeyFragment(keyReference)
}

/// The type the factory dependency is spelled with when lifted onto a consuming binding (the proxy). A
/// factory with no injected axis is the bare `_WireFactory_<key>`. One generic over an injected axis is
/// spelled with the *consumer's* generic parameters that share the injected parameters' constraints —
/// `_WireFactory_<key><Repository>` on a proxy generic over `Repository: TodoRepository`. Parameterising
/// the field this way makes it thread the graph's lift parameter transitively, exactly as the subject
/// dependency (`Controller<Repository>`) does, so the middleware and the controller share one backend.
func factoryDependencyType(
    forKey keyReference: String,
    factory: SynthesizedFactory?,
    liftedOnto binding: DiscoveredBinding
) -> String {
    let bare = factoryTypeName(forKey: keyReference)
    guard let factory, !factory.injectedParameterNames.isEmpty,
        case .scopeBound(let consumer) = binding
    else { return bare }
    let arguments = factory.injectedParameterNames.map { injected -> String in
        let constraint = factory.injectedParameterConstraints[injected].map(canonicalTypeName)
        let match = consumer.genericParameterNames.first { parameter in
            consumer.genericParameterConstraints[parameter].map(canonicalTypeName) == constraint
        }
        return match ?? factory.injectedParameterConstraints[injected].map { "some \($0)" } ?? injected
    }
    return "\(bare)<\(arguments.joined(separator: ", "))>"
}

/// Collate the `@X(key)`-driven factory demands and synthesise one factory per
/// consumed key that matches a template. Deduped by key; deterministic order (by
/// key reference) for stable emission. A use-site whose argument is `Type.self`
/// (the concrete case) or whose key has no matching template is skipped.
package func synthesizeFactories(
    templates: [DiscoveredFactoryTemplate],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite]
) -> [SynthesizedFactory] {
    let factoryAnnotations = Set(
        annotations.filter { $0.capability == .injectsFactoryOnArgument }.map(\.annotationName)
    )
    guard !factoryAnnotations.isEmpty else { return [] }

    var templatesByKey: [String: DiscoveredFactoryTemplate] = [:]
    for template in templates {
        templatesByKey[template.keyReference] = template
    }

    var consumedKeys: Set<String> = []
    for site in useSites where factoryAnnotations.contains(site.annotationName) {
        guard let key = factoryKeyArgument(site.argument) else { continue }
        guard templatesByKey[key] != nil else { continue }
        consumedKeys.insert(key)
    }

    let mappings = factoryRoleMappings(templates: templates, annotations: annotations, useSites: useSites)
    return consumedKeys.sorted().compactMap { key in
        templatesByKey[key].map { synthesizedFactory(from: $0, roleMapping: mappings[key]) }
    }
}

/// The factory key an `@X(argument)` use-site references, or `nil` when the
/// argument is absent or the concrete `Type.self` case (which references an
/// existing binding, not a template). A key is any argument without a trailing
/// `.self`.
func factoryKeyArgument(_ argument: String?) -> String? {
    guard let argument, !argument.hasSuffix(".self") else { return nil }
    return argument
}

/// Register the synthesised factories as bindings and append the factory input
/// edge onto each consuming binding — the factory analogue of
/// `applyAdapterDependencies`. Runs before graphs build. Returns the updated
/// bindings and the synthesised factories (for the emitter).
///
/// A factory *type* is declared once at module scope (the emitter), but its
/// *binding* is registered in every partition that consumes it, so a
/// container-scoped controller finds the factory in its own graph.
package func applyFactorySynthesis(
    to allBindings: [Partition: [DiscoveredBinding]],
    templates: [DiscoveredFactoryTemplate],
    annotations: [DiscoveredAdapterAnnotation],
    useSites: [ContributionAliasUseSite],
    consumerModule: String
) -> (bindings: [Partition: [DiscoveredBinding]], factories: [SynthesizedFactory]) {
    let factories = synthesizeFactories(templates: templates, annotations: annotations, useSites: useSites)
    guard !factories.isEmpty else { return (allBindings, []) }

    let factoriesByKey = Dictionary(uniqueKeysWithValues: factories.map { ($0.keyReference, $0) })
    let factoryAnnotations = Set(
        annotations.filter { $0.capability == .injectsFactoryOnArgument }.map(\.annotationName)
    )

    // Each consuming binding identity → the demanded keys that have a factory, deduped by key: a key
    // referenced at both controller and route scope is one lifted factory (one input edge), matching
    // the adapter macro's per-key dedup in the wrapping init. First occurrence wins (source order).
    var demandsByIdentity: [String: [(key: String, location: SourceLocation)]] = [:]
    var seenKeysByIdentity: [String: Set<String>] = [:]
    for site in useSites where factoryAnnotations.contains(site.annotationName) {
        guard let key = factoryKeyArgument(site.argument), factoriesByKey[key] != nil else { continue }
        guard seenKeysByIdentity[site.targetIdentity, default: []].insert(key).inserted else { continue }
        demandsByIdentity[site.targetIdentity, default: []].append((key, site.location))
    }
    guard !demandsByIdentity.isEmpty else { return (allBindings, factories) }

    var result = allBindings
    for (partition, bindings) in allBindings {
        var updated = bindings.map { binding -> DiscoveredBinding in
            guard let identity = binding.aliasTargetIdentity,
                let demands = demandsByIdentity[identity], !demands.isEmpty
            else { return binding }
            let deps = demands.map { demand in
                DependencyParameter(
                    name: factoryDependencyName(forKey: demand.key),
                    type: factoryDependencyType(
                        forKey: demand.key, factory: factoriesByKey[demand.key], liftedOnto: binding),
                    kind: .injectInitParameter,
                    location: demand.location
                )
            }
            return binding.appendingDependencies(deps)
        }

        // Register a factory binding for each key consumed by a binding in this
        // partition, once per key.
        let keysConsumedHere = Set(
            bindings.compactMap(\.aliasTargetIdentity)
                .flatMap { demandsByIdentity[$0]?.map(\.key) ?? [] }
        )
        for key in keysConsumedHere.sorted() {
            guard let factory = factoriesByKey[key] else { continue }
            updated.append(.scopeBound(factoryBinding(factory, module: consumerModule)))
        }
        result[partition] = updated
    }

    return (result, factories)
}

/// The binding that constructs a synthesised factory — a struct whose dependencies are the template's,
/// resolved and constructed like any `@Singleton`. Generic over the injected axis (`_WireFactory_<key>
/// <Repository>`): each injected `@Inject` dependency is a bare-parameter dependency on a determining
/// constraint, so the binding is a *lift node* — the transitive-lift machinery threads the graph-resolved
/// backend through it exactly as it does the controller. A factory with no injected axis stays a plain
/// non-generic binding (the 3.1/3.2 case).
func factoryBinding(_ factory: SynthesizedFactory, module: String) -> DiscoveredScopeBoundType {
    DiscoveredScopeBoundType(
        typeName: factory.factoryTypeName,
        typeKind: "struct",
        genericParameterNames: factory.injectedParameterNames,
        genericParameterConstraints: factory.injectedParameterConstraints,
        dependencies: factory.dependencies,
        location: factory.location,
        originModule: module
    )
}

// MARK: - Emission

/// Render a synthesised factory's Swift declaration for the generated graph file —
/// a concrete struct storing the template's deps, with a generic `create` whose
/// assisted parameters are metatypes and whose body constructs the middleware. The
/// struct's memberwise init is what the factory *binding* is constructed through.
///
///     struct _WireFactory_MyMiddleware_session {
///         let store: SessionStore
///         func create<Ctx, Reader, Sender>(_: Ctx.Type, _: Reader.Type, _: Sender.Type) -> SessionMiddleware<Ctx, Reader, Sender> {
///             SessionMiddleware(store: store)
///         }
///     }
package func renderFactoryDeclaration(_ factory: SynthesizedFactory) -> String {
    // The factory struct is generic over the *injected* axis (parameters resolved from the graph — the
    // 3.3 injected backend); those become the struct's own generics, threaded from the graph's lift
    // parameter, and store the `@Inject` dependencies typed by them.
    let injected = factory.injectedParameterNames
    let structGenerics = injected.map { name in
        factory.injectedParameterConstraints[name].map { "\(name): \($0)" } ?? name
    }
    let structGenericClause = structGenerics.isEmpty ? "" : "<\(structGenerics.joined(separator: ", "))>"

    // With a role mapping, `create` is generic over the adapter's canonical roles in their fixed order
    // (the order the consumer's macro calls with), each a metatype; the middleware's assisted parameters
    // are substituted → role names in the return type. Without one, `create` keeps the positional
    // declaration-order form. An assisted role the middleware doesn't use is a phantom generic parameter.
    let createGenerics = factory.roleMapping?.canonicalRoles ?? factory.assistedParameterNames
    let genericClause = createGenerics.isEmpty ? "" : "<\(createGenerics.joined(separator: ", "))>"
    let createParameters = createGenerics.map { "_: \($0).Type" }.joined(separator: ", ")
    // The produced type's arguments in declaration order: an injected parameter is the factory struct's
    // own generic (spelled as itself); an assisted parameter is spelled as its role (or itself, unmapped).
    let returnArguments = factory.parameterNames.map { name in
        injected.contains(name) ? name : (factory.roleMapping?.parameterRoles[name] ?? name)
    }
    let returnType =
        returnArguments.isEmpty
        ? factory.producedTypeName
        : "\(factory.producedTypeName)<\(returnArguments.joined(separator: ", "))>"
    let whereClause = renderAssistedConstraints(factory)
    let constructionArguments = factory.dependencies.map { dependency in
        let value = dependency.name ?? dependency.type
        return dependency.name.map { "\($0): \(value)" } ?? value
    }.joined(separator: ", ")

    // The factory type is emitted `internal` (no access keyword): it is consumer-local — declared in the
    // consumer module, constructed by that module's graph, stored only on the consumer's proxy — so it is
    // never public API. A `public` factory would fail under `InternalImportsByDefault` when its `create`
    // returns a produced (middleware) type from an internally-imported library; `internal` sidesteps that.
    // (This is the same reasoning as the contributor proxy — see `renderContributorProxyDeclaration`.)

    // `Sendable`: the factory holds graph bindings (all `Sendable` in Wire's model) and is stored on the
    // — typically `Sendable` — proxy it's lifted onto, so it must conform.
    let initParameters = factory.dependencies.map { "\($0.name ?? $0.type): \($0.type)" }
        .joined(separator: ", ")

    var lines: [String] = []
    lines.append("struct \(factory.factoryTypeName)\(structGenericClause): Sendable {")
    for dependency in factory.dependencies {
        lines.append("    let \(dependency.name ?? dependency.type): \(dependency.type)")
    }
    lines.append("    init(\(initParameters)) {")
    for dependency in factory.dependencies {
        let name = dependency.name ?? dependency.type
        lines.append("        self.\(name) = \(name)")
    }
    lines.append("    }")
    lines.append(
        "    func create\(genericClause)(\(createParameters)) -> \(returnType)\(whereClause) {"
    )
    lines.append("        \(factory.producedTypeName)(\(constructionArguments))")
    lines.append("    }")
    lines.append("}")
    return lines.joined(separator: "\n")
}

/// The `where` clause restating the template's generic requirements on `create` — the per-parameter
/// constraints in declared order (`Ctx: RequestContext`) followed by the template's own `where`-clause
/// requirements (associated-type / same-type / `~Copyable`). Both must be restated or a constrained
/// middleware won't construct. With a role mapping, each constraint is stated on the parameter's **role**
/// and every parameter reference in the constraint text / `where` clause is substituted → its role name;
/// an unmapped (phantom) role carries no constraint. Empty when the template has neither.
private func renderAssistedConstraints(_ factory: SynthesizedFactory) -> String {
    let roles = factory.roleMapping?.parameterRoles
    func substituted(_ text: String) -> String {
        roles.map { substitutingIdentifierTokens(text, $0) } ?? text
    }
    var requirements = factory.assistedParameterNames.compactMap { name -> String? in
        guard let constraint = factory.assistedParameterConstraints[name] else { return nil }
        return "\(roles?[name] ?? name): \(substituted(constraint))"
    }
    if let whereClause = factory.whereClause, !whereClause.isEmpty {
        requirements.append(substituted(whereClause))
    }
    return requirements.isEmpty ? "" : " where \(requirements.joined(separator: ", "))"
}
