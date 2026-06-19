import SwiftSyntax

// Recognition of `@resultBuilder` type declarations and the result type
// of their `buildBlock` / `buildFinalResult`. A `BuilderKey<Builder>`
// aggregate produces that result type; codegen needs it spelled out
// because a result-builder fold function requires an explicit concrete
// return type. See
// `Documentation/Notes/MultibindingsImplementationPlan.md` (Step 5b).

/// Recognise a `@resultBuilder` type and capture its result type, or
/// `nil` when the declaration isn't a result builder or has neither
/// `buildFinalResult` nor `buildBlock` with a return clause.
func resultBuilder(
    named nameToken: TokenSyntax,
    attributes: AttributeListSyntax,
    members: MemberBlockItemListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> DiscoveredResultBuilder? {
    guard hasAttribute(attributes, named: "resultBuilder") else { return nil }
    guard let resultType = resultBuilderResultType(members) else { return nil }
    return DiscoveredResultBuilder(
        typeName: nameToken.text,
        resultType: resultType,
        location: makeSourceLocation(of: nameToken, sourcePath: sourcePath, converter: converter)
    )
}

/// The fold result type: `buildFinalResult`'s return when present (it has
/// the final say in the result-builder protocol), otherwise `buildBlock`'s.
private func resultBuilderResultType(_ members: MemberBlockItemListSyntax) -> String? {
    returnType(ofMethodNamed: "buildFinalResult", in: members)
        ?? returnType(ofMethodNamed: "buildBlock", in: members)
}

private func returnType(
    ofMethodNamed name: String,
    in members: MemberBlockItemListSyntax
) -> String? {
    for member in members {
        guard let function = member.decl.as(FunctionDeclSyntax.self),
            function.name.text == name,
            let returnClause = function.signature.returnClause
        else { continue }
        return returnClause.type.trimmedDescription
    }
    return nil
}
