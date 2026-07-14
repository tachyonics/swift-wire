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

/// What a discovered adapter annotation does — the source-read form of `WireAdapterCapability`.
package enum DiscoveredAdapterCapability: Sendable, Equatable {
    /// `@X` aliases `@Contributes(to: key)` — the multibinding-key reference (an output edge).
    case contributes(key: String)
    /// `@X(T.self)` makes the annotated binding depend on `T` (an input edge to an
    /// existing binding).
    case injectsDependencyOnArgument
    /// `@X(key)` makes the annotated binding depend on the factory synthesised from the
    /// `@Factory(key)` template (an input edge to a synthesised value).
    case injectsFactoryOnArgument
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
        let member = call.calledExpression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "contributes",
        let toArgument = call.arguments.first(where: { $0.label?.text == "to" })
    {
        return .contributes(key: toArgument.expression.trimmedDescription)
    }
    if let member = expression.as(MemberAccessExprSyntax.self) {
        switch member.declName.baseName.text {
        case "injectsDependencyOnArgument": return .injectsDependencyOnArgument
        case "injectsFactoryOnArgument": return .injectsFactoryOnArgument
        case "rewritesInjection": return .rewritesInjection
        default: return nil
        }
    }
    return nil
}
