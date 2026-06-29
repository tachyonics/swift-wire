import SwiftSyntax

// Recognition of adapter-annotation use-sites — type declarations carrying an
// attribute of the adapter shape `@Name(SomeType.self, ...)` (e.g.
// `@RoutedBy(Router<BasicRequestContext>.self)`).
//
// The scan is deliberately *name-agnostic*: it captures every type-decl
// attribute of this shape as a candidate, without knowing which names are
// adapter annotations. Classification — keeping only those whose name matches
// a discovered `DiscoveredAdapterAnnotation` — is a separate step
// (`AdapterResolution`), because a use-site's defining package may be a
// different module than the use-site itself. See `MultiModuleComposition.md`.

/// One adapter-annotation use-site found in source — an adapter-shaped
/// attribute on a type declaration, captured *raw* (the annotation name and
/// the type arguments as written), before any match against a definition or
/// the binding graph.
package struct AdapterUseSite: Sendable, Equatable {
    /// The attribute spelling without the leading `@` — `"RoutedBy"`. Matched
    /// against a `DiscoveredAdapterAnnotation.annotationName`.
    package let annotationName: String
    /// The annotated type's simple name — `"TaskController"`. Substituted for
    /// the `Self` placeholder in the register signature.
    package let annotatedTypeName: String
    /// The annotated type's name qualified by its enclosing types —
    /// `"Outer.TaskController"` — used as the callee of the emitted
    /// `_wireRegister` call.
    package let annotatedQualifiedTypeName: String
    /// The annotation's type arguments, as written — `["Router<…>"]` for
    /// `@RoutedBy(Router<…>.self)`. Substituted for the `$0`, `$1`, …
    /// placeholders in the register signature.
    package let typeArguments: [String]
    /// The attribute site — the diagnostic anchor for a missing-binding error.
    package let location: SourceLocation
    package let originModule: String

    package init(
        annotationName: String,
        annotatedTypeName: String,
        annotatedQualifiedTypeName: String,
        typeArguments: [String],
        location: SourceLocation,
        originModule: String
    ) {
        self.annotationName = annotationName
        self.annotatedTypeName = annotatedTypeName
        self.annotatedQualifiedTypeName = annotatedQualifiedTypeName
        self.typeArguments = typeArguments
        self.location = location
        self.originModule = originModule
    }
}

/// Capture the adapter-shaped attributes on one type declaration: those with
/// one or more arguments, all unlabelled, each a `SomeType.self` metatype.
/// The unlabelled-`.self` shape is the M1 adapter contract and excludes Wire's
/// own attributes (`@Singleton`, `@Scoped(seed: X.self)`, …, which are
/// argument-less or labelled). Returns every match; classification happens
/// later against the discovered definitions.
func scanAdapterUseSites(
    annotatedTypeName: String,
    annotatedQualifiedTypeName: String,
    attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter,
    module: String
) -> [AdapterUseSite] {
    var sites: [AdapterUseSite] = []
    for element in attributes {
        guard let attribute = element.as(AttributeSyntax.self) else { continue }
        guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
            !arguments.isEmpty,
            arguments.allSatisfy({ $0.label == nil })
        else { continue }
        let typeArguments = arguments.compactMap { metatypeBaseType(of: $0.expression) }
        guard typeArguments.count == arguments.count else { continue }
        sites.append(
            AdapterUseSite(
                annotationName: attribute.attributeName.trimmedDescription,
                annotatedTypeName: annotatedTypeName,
                annotatedQualifiedTypeName: annotatedQualifiedTypeName,
                typeArguments: typeArguments,
                location: makeSourceLocation(of: attribute, sourcePath: sourcePath, converter: converter),
                originModule: module
            )
        )
    }
    return sites
}

/// The base type of a `SomeType.self` metatype expression — `Router<C>` for
/// `Router<C>.self`. `nil` for any expression that isn't a `.self` metatype.
private func metatypeBaseType(of expression: ExprSyntax) -> String? {
    guard let member = expression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "self",
        let base = member.base
    else { return nil }
    return base.trimmedDescription
}
