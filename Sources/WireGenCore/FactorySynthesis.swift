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

/// A factory the plugin synthesises for one consumed `FactoryKey`. Carries what
/// both the emitter (the struct declaration) and the binding registration
/// (construction of the template's deps) need.
package struct SynthesizedFactory: Sendable {
    /// The canonical key text the factory is derived from (`MyMiddleware.session`).
    package let keyReference: String
    /// The synthesised concrete type name (`_WireFactory_MyMiddleware_session`).
    package let factoryTypeName: String
    /// The middleware type the factory produces — the template's qualified name
    /// (`SessionMiddleware`), specialised at the assisted parameters in `create`.
    package let producedTypeName: String
    /// The assisted parameters — the template's generic parameter names, taken as
    /// metatype arguments to `create`.
    package let assistedParameterNames: [String]
    /// Per-assisted-parameter protocol constraints, restated on `create`'s `where`.
    package let assistedParameterConstraints: [String: String]
    /// The template's `where`-clause requirements (associated-type / same-type /
    /// `~Copyable`), verbatim and without the `where` keyword, or `nil` — restated
    /// on `create` after the per-parameter constraints.
    package let whereClause: String?
    /// The injected dependencies — the template's `@Inject` members, resolved once
    /// when the factory is constructed. Carried verbatim (keys included) so the
    /// factory binding resolves them exactly as the template would have.
    package let dependencies: [DependencyParameter]
    /// The module the produced (template) type lives in — and, in the split model, the
    /// module that *owns* (emits) the factory type. The graph consumer imports it when
    /// foreign; only this module renders the type.
    package let producedTypeModule: String
    /// The factory type's access — mirrors the `@Factory` template's. A `public`/`package`
    /// template's factory is referenceable across modules; an `internal` one only in its
    /// own module.
    package let accessLevel: AccessLevel
    /// The template's declaration site, stamped onto the synthesised binding.
    package let location: SourceLocation

    package init(
        keyReference: String,
        factoryTypeName: String,
        producedTypeName: String,
        assistedParameterNames: [String],
        assistedParameterConstraints: [String: String],
        whereClause: String? = nil,
        dependencies: [DependencyParameter],
        producedTypeModule: String,
        accessLevel: AccessLevel = .internal,
        location: SourceLocation
    ) {
        self.keyReference = keyReference
        self.factoryTypeName = factoryTypeName
        self.producedTypeName = producedTypeName
        self.assistedParameterNames = assistedParameterNames
        self.assistedParameterConstraints = assistedParameterConstraints
        self.whereClause = whereClause
        self.dependencies = dependencies
        self.producedTypeModule = producedTypeModule
        self.accessLevel = accessLevel
        self.location = location
    }
}

/// Build the `SynthesizedFactory` for one `@Factory` template — the single source of truth
/// both type emission (template-driven) and construction (consumer-driven) derive from.
func synthesizedFactory(from template: DiscoveredFactoryTemplate) -> SynthesizedFactory {
    SynthesizedFactory(
        keyReference: template.keyReference,
        factoryTypeName: factoryTypeName(forKey: template.keyReference),
        producedTypeName: template.qualifiedTypeName,
        assistedParameterNames: template.genericParameterNames,
        assistedParameterConstraints: template.genericParameterConstraints,
        whereClause: template.genericWhereClause,
        dependencies: template.dependencies,
        producedTypeModule: template.originModule,
        accessLevel: template.accessLevel,
        location: template.location
    )
}

/// Render the factory-type declarations a module *owns* — one per `@Factory` template
/// declared in `module`, at the template's own visibility. Template-driven (independent of
/// consumers): the type belongs to the factory, so every consumer, in any package, references
/// this one declaration. Deterministic order by key.
package func renderOwnedFactoryTypes(
    templates: [DiscoveredFactoryTemplate],
    module: String
) -> [String] {
    templates
        .filter { $0.originModule == module }
        .map(synthesizedFactory(from:))
        .sorted { $0.keyReference < $1.keyReference }
        .map(renderFactoryDeclaration)
}

/// Render a Wire-aware library's `_WireFactory.swift`: its owned factory-type declarations plus the
/// `import`s its sources carry (so foreign dependency types the factories reference resolve). Just
/// the header when the module declares no `@Factory` templates.
package func renderFactoryModule(imports: [String], typeDeclarations: [String]) -> String {
    var lines = ["// Generated by WireGen — do not edit."]
    let sortedImports = Array(Set(imports)).sorted()
    if !sortedImports.isEmpty {
        lines.append("")
        lines.append(contentsOf: sortedImports)
    }
    for declaration in typeDeclarations {
        lines.append("")
        lines.append(declaration)
    }
    lines.append("")
    return lines.joined(separator: "\n")
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

    return consumedKeys.sorted().compactMap { key in
        templatesByKey[key].map(synthesizedFactory(from:))
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

    // Each consuming binding identity → the demanded keys that have a factory.
    var demandsByIdentity: [String: [(key: String, location: SourceLocation)]] = [:]
    for site in useSites where factoryAnnotations.contains(site.annotationName) {
        guard let key = factoryKeyArgument(site.argument), factoriesByKey[key] != nil else { continue }
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
                    type: factoryTypeName(forKey: demand.key),
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

/// The binding that constructs a synthesised factory — a concrete struct whose
/// dependencies are the template's, resolved and constructed like any `@Singleton`.
func factoryBinding(_ factory: SynthesizedFactory, module: String) -> DiscoveredScopeBoundType {
    DiscoveredScopeBoundType(
        typeName: factory.factoryTypeName,
        typeKind: "struct",
        genericParameterNames: [],
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
    let assisted = factory.assistedParameterNames
    let genericClause = assisted.isEmpty ? "" : "<\(assisted.joined(separator: ", "))>"
    let createParameters = assisted.map { "_: \($0).Type" }.joined(separator: ", ")
    let returnType =
        assisted.isEmpty
        ? factory.producedTypeName
        : "\(factory.producedTypeName)<\(assisted.joined(separator: ", "))>"
    let whereClause = renderAssistedConstraints(factory)
    let constructionArguments = factory.dependencies.map { dependency in
        let value = dependency.name ?? dependency.type
        return dependency.name.map { "\($0): \(value)" } ?? value
    }.joined(separator: ", ")

    // The type and its members carry the template's access so a public/package factory is
    // referenceable from the graph consumer's module (and any consuming package).
    let access = factory.accessLevel.factoryDeclarationPrefix

    // `Sendable`: the factory holds graph bindings (all `Sendable` in Wire's model) and is stored on
    // the — typically `Sendable` — controller it's lifted onto, so it must conform.
    var lines: [String] = []
    lines.append("\(access)struct \(factory.factoryTypeName): Sendable {")
    for dependency in factory.dependencies {
        lines.append("    \(access)let \(dependency.name ?? dependency.type): \(dependency.type)")
    }
    lines.append(
        "    \(access)func create\(genericClause)(\(createParameters)) -> \(returnType)\(whereClause) {"
    )
    lines.append("        \(factory.producedTypeName)(\(constructionArguments))")
    lines.append("    }")
    lines.append("}")
    return lines.joined(separator: "\n")
}

extension AccessLevel {
    /// The keyword prefix (`"public "` / `"package "` / `""`) for a synthesised factory type
    /// and its members. `open` narrows to `public` (a struct can't be `open`); `internal` and
    /// tighter emit no keyword (internal is the default, and a factory tighter than internal is
    /// only ever referenced within its own module).
    var factoryDeclarationPrefix: String {
        switch self {
        case .open, .public: return "public "
        case .package: return "package "
        case .internal, .fileprivate, .private: return ""
        }
    }
}

/// The `where` clause restating the template's generic requirements on `create` —
/// the per-parameter constraints in declared order (`Ctx: RequestContext`) followed
/// by the template's own `where`-clause requirements (associated-type / same-type /
/// `~Copyable`). Both must be restated or a constrained middleware won't construct.
/// Empty when the template has neither.
private func renderAssistedConstraints(_ factory: SynthesizedFactory) -> String {
    var requirements = factory.assistedParameterNames.compactMap { name in
        factory.assistedParameterConstraints[name].map { "\(name): \($0)" }
    }
    if let whereClause = factory.whereClause, !whereClause.isEmpty {
        requirements.append(whereClause)
    }
    return requirements.isEmpty ? "" : " where \(requirements.joined(separator: ", "))"
}
