import SwiftSyntax

// MARK: - File-private helpers

/// Scope-macro attribute names that conflict with `@Container` on
/// the same type. `@Container` routes the type's static members
/// into a separate graph; a scope macro on the same type makes the
/// type a binding in the *default* graph. Combining them means
/// the type is both a node in one graph and a grouping for
/// another — almost always a user error.
let scopeMacroNames = ["Singleton", "Scoped"]

/// Build a candidate when the `@Provides` was found inside an
/// unannotated extension (i.e. the immediate enclosing scope's
/// `VisitorScope.unannotatedExtensionTarget` is non-nil). WireGen
/// resolves candidates against the module-wide `@Container` name
/// set in a later pass.
func unannotatedExtensionProvidesCandidates(
    providerName: String,
    location: SourceLocation,
    extendedType: String?
) -> [UnannotatedExtensionProvides] {
    guard let extendedType else { return [] }
    return [
        UnannotatedExtensionProvides(
            extendedType: extendedType,
            providerName: providerName,
            location: location
        )
    ]
}

/// `@Inject` on the members of a non-scope-annotated type is a silent
/// no-op — there's no macro on the enclosing type to read it. Emit a
/// warning per `@Inject`-marked init or stored property so the user
/// understands they need a scope macro to get wiring.
func strayInjectMemberDiagnostics(
    nameToken: TokenSyntax,
    attributes: AttributeListSyntax,
    members: MemberBlockItemListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    // If the type itself carries a scope macro, `@Inject` on its
    // members IS meaningful — the scope macro reads them. Skip.
    if scopeMacroNames.contains(where: { hasAttribute(attributes, named: $0) }) {
        return []
    }
    var warnings: [Diagnostic] = []
    for member in members {
        if let initDecl = member.decl.as(InitializerDeclSyntax.self),
            let injectAttr = attribute(in: initDecl.attributes, named: "Inject")
        {
            warnings.append(
                Diagnostic(
                    location: makeSourceLocation(
                        of: injectAttr,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    message:
                        "@Inject on this initialiser has no effect — '\(nameToken.text)' has no scope macro. Add a scope macro to the type (@Singleton, @RequestScope, or @JobScope) to enable wiring."
                )
            )
            continue
        }
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
            let injectAttr = attribute(in: varDecl.attributes, named: "Inject")
        else { continue }
        for binding in varDecl.bindings {
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            warnings.append(
                Diagnostic(
                    location: makeSourceLocation(
                        of: injectAttr,
                        sourcePath: sourcePath,
                        converter: converter
                    ),
                    message:
                        "@Inject on '\(pattern.identifier.text)' has no effect — '\(nameToken.text)' has no scope macro. Add a scope macro to the type (@Singleton, @RequestScope, or @JobScope) to enable wiring."
                )
            )
        }
    }
    return warnings
}

/// `@Inject let foo = ...` at module scope is a silent no-op — there's
/// no enclosing type for any macro to read it from. Most often the
/// user meant `@Provides`.
func strayInjectAtModuleScopeDiagnostics(
    for node: VariableDeclSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    guard let injectAttr = attribute(in: node.attributes, named: "Inject") else { return [] }
    guard let binding = node.bindings.first,
        let pattern = binding.pattern.as(IdentifierPatternSyntax.self)
    else { return [] }
    return [
        Diagnostic(
            location: makeSourceLocation(
                of: injectAttr,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "@Inject on '\(pattern.identifier.text)' at module scope has no effect — use @Provides for module-scope bindings."
        )
    ]
}

/// `@Inject` on an init declared in an extension is ignored by the
/// `@Singleton` macro — peer macros only see the primary declaration's
/// members. Warn so the user knows to move the init back to the
/// primary type.
func injectInitInExtensionDiagnostics(
    extension extensionNode: ExtensionDeclSyntax,
    extendedName: String,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    var warnings: [Diagnostic] = []
    for member in extensionNode.memberBlock.members {
        guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { continue }
        guard let injectAttr = attribute(in: initDecl.attributes, named: "Inject") else {
            continue
        }
        warnings.append(
            Diagnostic(
                location: makeSourceLocation(
                    of: injectAttr,
                    sourcePath: sourcePath,
                    converter: converter
                ),
                message:
                    "@Inject on an extension init has no effect — move the init into the primary declaration of '\(extendedName)' so the @Singleton macro can see it."
            )
        )
    }
    return warnings
}

/// Record every non-`@Inject` `init` inside an extension as a
/// candidate. WireGen filters these against the module-wide
/// `@Singleton`-name set after aggregation — the warning fires only
/// when the extended type is a `@Singleton`, since that's when the
/// macro-generated init enters the picture.
func nonInjectExtensionInitCandidates(
    extension extensionNode: ExtensionDeclSyntax,
    extendedName: String,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [NonInjectExtensionInit] {
    var candidates: [NonInjectExtensionInit] = []
    for member in extensionNode.memberBlock.members {
        guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { continue }
        if hasAttribute(initDecl.attributes, named: "Inject") { continue }
        candidates.append(
            NonInjectExtensionInit(
                extendedType: extendedName,
                location: makeSourceLocation(
                    of: initDecl.initKeyword,
                    sourcePath: sourcePath,
                    converter: converter
                )
            )
        )
    }
    return candidates
}
