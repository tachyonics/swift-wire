import SwiftSyntax

// Parsing of `@Contributes(to:withOrder:atKey:)` annotations into
// `Contribution` values. Factored out of `BindingDiscovery` as free
// functions; shared by the scope-bound and `@Provides` producer paths so
// any producer can contribute uniformly. See
// `Documentation/Notes/MultibindingsImplementationPlan.md` (Step 2).

/// Every `@Contributes(to:)` annotation on a declaration, in source
/// order. A contributor may target several keys via repeated
/// `@Contributes` (Swift permits the same attached macro multiple times),
/// so this returns a list rather than a single optional. Tolerates the
/// SE-0491 `@Wire::Contributes` selector via `wireMacroNameMatches`.
func contributions(
    in attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Contribution] {
    attributes.compactMap { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return nil }
        guard wireMacroNameMatches(attribute.attributeName.trimmedDescription, "Contributes") else {
            return nil
        }
        return contribution(from: attribute, sourcePath: sourcePath, converter: converter)
    }
}

/// Parse a single `@Contributes(to:withOrder:atKey:)` attribute. Returns
/// `nil` when the required `to:` argument is absent — a malformed form
/// the compiler also rejects (no matching `@Contributes` overload).
private func contribution(
    from attribute: AttributeSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> Contribution? {
    guard case let .argumentList(arguments) = attribute.arguments else { return nil }
    guard let toArgument = arguments.first(where: { $0.label?.text == "to" }) else { return nil }

    let order =
        arguments
        .first(where: { $0.label?.text == "withOrder" })
        .flatMap { Int($0.expression.trimmedDescription) }
    let mapKeyExpression =
        arguments
        .first(where: { $0.label?.text == "atKey" })?
        .expression.trimmedDescription

    return Contribution(
        keyReference: toArgument.expression.trimmedDescription,
        order: order,
        mapKeyExpression: mapKeyExpression,
        location: makeSourceLocation(of: attribute, sourcePath: sourcePath, converter: converter)
    )
}
