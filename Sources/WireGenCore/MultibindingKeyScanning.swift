import SwiftSyntax

// Recognition of multibinding key declarations — `CollectedKey<…>`,
// `MappedKey<…>`, `BuilderKey<…>` `static let`s. The visitor supplies the
// enclosing-scope context (type names, access levels) and source
// position; everything here is a pure function of syntax. See
// `Documentation/Notes/MultibindingsImplementationPlan.md` (Step 1).

/// Recognise a multibinding key declaration — a single-binding
/// `let`/`static let` whose type is `CollectedKey<…>`, `MappedKey<…>`,
/// or `BuilderKey<…>` — and capture its flavour, generic argument(s),
/// canonical reference text, and effective access. The flavour and
/// generics come from the explicit type annotation when present,
/// otherwise from a constructor-call initialiser. Returns `nil` for any
/// declaration that doesn't name a known flavour.
func multibindingKey(
    from node: VariableDeclSyntax,
    enclosingTypeNames: [String],
    enclosingAccessLevels: [AccessLevel],
    sourcePath: String,
    converter: SourceLocationConverter
) -> DiscoveredMultibindingKey? {
    guard node.bindings.count == 1, let binding = node.bindings.first else { return nil }
    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
    guard
        let info = multibindingKeyInfo(
            annotation: binding.typeAnnotation?.type,
            initializer: binding.initializer?.value
        )
    else { return nil }

    let keyReference = (enclosingTypeNames + [pattern.identifier.text]).joined(separator: ".")
    let effectiveAccess =
        enclosingAccessLevels
        .reduce(accessLevel(from: node.modifiers)) { $0.mostRestrictive(with: $1) }

    return DiscoveredMultibindingKey(
        keyReference: keyReference,
        flavour: info.flavour,
        typeArguments: info.typeArguments,
        location: makeSourceLocation(of: pattern.identifier, sourcePath: sourcePath, converter: converter),
        accessLevel: effectiveAccess
    )
}

/// Resolve a key declaration's flavour and generic argument list from its
/// type annotation or constructor-call initialiser. Returns `nil` when
/// neither names a known flavour.
private func multibindingKeyInfo(
    annotation: TypeSyntax?,
    initializer: ExprSyntax?
) -> (flavour: MultibindingKeyFlavour, typeArguments: [String])? {
    if let identifier = annotation?.as(IdentifierTypeSyntax.self),
        let flavour = multibindingFlavour(named: identifier.name.text)
    {
        return (flavour, genericArgumentList(identifier.genericArgumentClause))
    }
    guard let call = initializer?.as(FunctionCallExprSyntax.self) else { return nil }
    let called = call.calledExpression
    if let specialization = called.as(GenericSpecializationExprSyntax.self),
        let reference = specialization.expression.as(DeclReferenceExprSyntax.self),
        let flavour = multibindingFlavour(named: reference.baseName.text)
    {
        return (flavour, genericArgumentList(specialization.genericArgumentClause))
    }
    if let reference = called.as(DeclReferenceExprSyntax.self),
        let flavour = multibindingFlavour(named: reference.baseName.text)
    {
        return (flavour, [])
    }
    return nil
}

private func multibindingFlavour(named name: String) -> MultibindingKeyFlavour? {
    switch name {
    case "CollectedKey": return .collected
    case "MappedKey": return .mapped
    case "BuilderKey": return .builder
    default: return nil
    }
}

/// The verbatim generic arguments of a clause, each with its trailing
/// comma stripped — `["any Service"]`, `["String", "any Strategy"]`.
private func genericArgumentList(_ clause: GenericArgumentClauseSyntax?) -> [String] {
    guard let clause else { return [] }
    return clause.arguments.map { $0.with(\.trailingComma, nil).trimmedDescription }
}
