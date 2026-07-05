import SwiftSyntax

// Recognition of adapter-annotation definitions — `WireAdapterAnnotationV1`
// declarations. An adapter package declares one per annotation it publishes (e.g.
// `@RoutedBy`, `@HummingbirdRoute`): the attribute `@annotation` on a binding is an
// alias for `@Contributes(to: contributesTo)`.
//
// Discovered anywhere in source, syntax-only — the same discipline as
// `BindingKeyScanning`. A consumer re-parses its Wire-aware dependencies' sources,
// so an adapter package's definitions reach WireGen without a manifest file. See
// `MultiModuleComposition.md`.

/// One adapter-annotation definition found in source — a `WireAdapterAnnotationV1`
/// declaration mapping an annotation the module publishes to a multibinding key.
package struct DiscoveredAdapterAnnotation: Sendable, Equatable {
    /// The attribute spelling without the leading `@` — `"RoutedBy"`. Matches
    /// use-sites to this definition.
    package let annotationName: String
    /// The multibinding-key reference the annotation contributes to — `@X` on a
    /// binding aliases `@Contributes(to: contributesToKey)`.
    package let contributesToKey: String
    package let location: SourceLocation
    package let originModule: String

    package init(
        annotationName: String,
        contributesToKey: String,
        location: SourceLocation,
        originModule: String
    ) {
        self.annotationName = annotationName
        self.contributesToKey = contributesToKey
        self.location = location
        self.originModule = originModule
    }
}

/// Recognise an adapter-annotation definition — a `let`/`static let` whose
/// initialiser is a `WireAdapterAnnotationV1(annotation:, contributesTo:)` call —
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
    var contributesToKey: String?
    for argument in call.arguments {
        switch argument.label?.text {
        case "annotation":
            annotationName = argument.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        case "contributesTo":
            contributesToKey = argument.expression.trimmedDescription
        default:
            break
        }
    }

    guard let annotationName, let contributesToKey else { return nil }
    return DiscoveredAdapterAnnotation(
        annotationName: annotationName,
        contributesToKey: contributesToKey,
        location: makeSourceLocation(of: pattern.identifier, sourcePath: sourcePath, converter: converter),
        originModule: module
    )
}
