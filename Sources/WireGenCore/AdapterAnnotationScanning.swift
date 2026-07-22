import SwiftSyntax

// Recognition of adapter-annotation definitions — `WireAdapterAnnotationV1`
// declarations. An adapter package declares one per annotation it publishes (e.g.
// `@RoutedBy`, `@HummingbirdRoute`): the attribute `@annotation` on a binding is an
// alias for `@Contributes(to: key)`.
//
// Discovered anywhere in source, syntax-only — the same discipline as
// `BindingKeyScanning`. A consumer re-parses its Wire-aware dependencies' sources,
// so an adapter package's definitions reach WireGen without a manifest file. See
// `MultiModuleComposition.md`.

/// The source-read form of `WireProxyScope` — the scope a `.contributesProxy` proxy is emitted at.
/// swift-wire compares it against the subject's scope to pick hold vs bridge (see
/// `contributorProxyBinding`). `.singleton` is the only value today.
package enum DiscoveredProxyScope: Sendable, Equatable {
    case singleton
}

/// What a discovered adapter annotation does — the source-read form of `WireAdapterCapability`.
package enum DiscoveredAdapterCapability: Sendable, Equatable {
    /// `@X` aliases `@Contributes(to: key)` — the multibinding-key reference (an output edge).
    case contributes(key: String)
    /// `@X` contributes a generated proxy (`<proxyTypePrefix><Binding>`) into the multibinding
    /// key, not the binding itself — the plugin synthesises the proxy binding (depending on the
    /// binding + its demanded factories) and contributes that. Under Phase A the plugin also emits the
    /// proxy's **structural half** (the `struct` declaration — fields + init + `Sendable`, body hole),
    /// superseding the adapter macro's type emission; the domain witness body is filled by an adapter
    /// codegen tool via an `extension` in the same module. See `renderContributorProxyDeclaration`.
    case contributesProxy(key: String, proxyTypePrefix: String, proxyScope: DiscoveredProxyScope)
    /// `@X` synthesises a contributor proxy that lifts the declaration's `.injectsFromGraph` peers onto
    /// itself (like `.contributesProxy`) but contributes to no multibinding — a standalone, addressable
    /// proxy the adapter's codegen reads directly (WireMVC's `@WireMVCBootstrap` global-middleware proxy).
    case liftsPeersToProxy(proxyTypePrefix: String, proxyScope: DiscoveredProxyScope)
    /// `@X(argument)` makes the annotated binding depend on a graph value named by `argument`, lifted
    /// onto its contributor proxy — dispatched on the argument's kind: a `FactoryKey` (matches a
    /// `@Factory(key)` template) injects that factory; a `BindingKey<T>` injects that keyed binding;
    /// `T.self` injects the binding of type `T`.
    case injectsFromGraph
    /// `@X` / `@X(.role, …)` on a `@Factory` template supplies the role mapping for its assisted
    /// parameters; `roles` is the adapter's ordered vocabulary of canonical slot names (opaque to Wire).
    case mapsFactoryRoles(roles: [String])
    /// `@X(...)` rewrites a consumer's injection resolution. Reserved — no pass yet.
    case rewritesInjection
}

/// One adapter-annotation definition found in source — a `WireAdapterAnnotationV1`
/// declaration stating what an annotation the module publishes does to its use-sites.
package struct DiscoveredAdapterAnnotation: Sendable, Equatable {
    /// The attribute spelling without the leading `@` — `"RoutedBy"`. Matches
    /// use-sites to this definition.
    package let annotationName: String
    /// What the annotation does — read from the `capability:` argument.
    package let capability: DiscoveredAdapterCapability
    package let location: SourceLocation
    package let originModule: String

    package init(
        annotationName: String,
        capability: DiscoveredAdapterCapability,
        location: SourceLocation,
        originModule: String
    ) {
        self.annotationName = annotationName
        self.capability = capability
        self.location = location
        self.originModule = originModule
    }
}

/// Recognise an adapter-annotation definition — a `let`/`static let` whose
/// initialiser is a `WireAdapterAnnotationV1(annotation:, capability:)` call —
/// and capture its annotation name and key reference. Returns `nil` for any
/// declaration that doesn't construct `WireAdapterAnnotationV1` with both arguments.
func adapterAnnotation(
    from node: VariableDeclSyntax,
    sourcePath: String,
    converter: SourceLocationConverter,
    module: String
) -> DiscoveredAdapterAnnotation? {
    guard node.bindings.count == 1, let binding = node.bindings.first else { return nil }
    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
    guard let call = binding.initializer?.value.as(FunctionCallExprSyntax.self),
        let called = call.calledExpression.as(DeclReferenceExprSyntax.self),
        called.baseName.text == "WireAdapterAnnotationV1"
    else { return nil }

    var annotationName: String?
    var capability: DiscoveredAdapterCapability?
    for argument in call.arguments {
        switch argument.label?.text {
        case "annotation":
            annotationName = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        case "capability":
            capability = adapterCapability(from: argument.expression)
        default:
            break
        }
    }

    guard let annotationName, let capability else { return nil }
    return DiscoveredAdapterAnnotation(
        annotationName: annotationName,
        capability: capability,
        location: makeSourceLocation(of: pattern.identifier, sourcePath: sourcePath, converter: converter),
        originModule: module
    )
}

/// Read a `WireAdapterCapability` literal syntactically: `.contributes(to: KEY)`,
/// `.injectsDependencyOnArgument`, or `.rewritesInjection`.
func adapterCapability(from expression: ExprSyntax) -> DiscoveredAdapterCapability? {
    if let call = expression.as(FunctionCallExprSyntax.self),
        let member = call.calledExpression.as(MemberAccessExprSyntax.self)
    {
        if member.declName.baseName.text == "contributes",
            let toArgument = call.arguments.first(where: { $0.label?.text == "to" })
        {
            return .contributes(key: toArgument.expression.trimmedDescription)
        }
        if member.declName.baseName.text == "contributesProxy",
            let toArgument = call.arguments.first(where: { $0.label?.text == "to" }),
            let prefixArgument = call.arguments.first(where: { $0.label?.text == "proxyTypePrefix" }),
            let prefix = prefixArgument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        {
            // `proxyScope:` has a single value (`.singleton`) today, so it is read as that regardless of
            // whether the source states it. When `WireProxyScope` grows cases, parse the argument here.
            return .contributesProxy(
                key: toArgument.expression.trimmedDescription,
                proxyTypePrefix: prefix,
                proxyScope: .singleton
            )
        }
        if member.declName.baseName.text == "liftsPeersToProxy",
            let prefixArgument = call.arguments.first(where: { $0.label?.text == "proxyTypePrefix" }),
            let prefix = prefixArgument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        {
            // `proxyScope:` has a single value (`.singleton`) today, read as that regardless of source.
            return .liftsPeersToProxy(proxyTypePrefix: prefix, proxyScope: .singleton)
        }
        if member.declName.baseName.text == "mapsFactoryRoles",
            let rolesArgument = call.arguments.first(where: { $0.label?.text == "roles" }),
            let array = rolesArgument.expression.as(ArrayExprSyntax.self)
        {
            let roles = array.elements.compactMap {
                $0.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
            }
            return .mapsFactoryRoles(roles: roles)
        }
    }
    if let member = expression.as(MemberAccessExprSyntax.self) {
        switch member.declName.baseName.text {
        case "injectsFromGraph": return .injectsFromGraph
        case "rewritesInjection": return .rewritesInjection
        default: return nil
        }
    }
    return nil
}
