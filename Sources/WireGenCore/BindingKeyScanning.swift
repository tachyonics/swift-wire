import SwiftSyntax

// Recognition of single-binding key declarations — `BindingKey<T>`
// `static let`s (or module-scope `let`s). The scope-axis sibling of
// `MultibindingKeyScanning`: same syntax-only discipline, same
// `(enclosingType, member)` reference reconstruction.
//
// Until iteration 7 Wire tracked *multibinding* keys but not single
// `BindingKey`s — the type of a single binding lives producer-side, so
// the compiler enforced it via the generated `_check`s and Wire never
// needed to read the key. Tracking them makes every key "a declared,
// type-carrying reference Wire tracks": it lets Wire diagnose a
// reference to an undeclared key (the missing-key parity with
// multibindings), and is the linchpin for cross-module key references
// (7f) and the value-level scope key (Axis B). See
// `Documentation/Notes/ScopeAndKeyModelEvolution.md` and
// `MultiModuleComposition.md`.

/// One single-binding key declaration found in source — a `static let`
/// (or module-scope `let`) whose type is `BindingKey<T>`.
///
/// Unlike `DiscoveredMultibindingKey`, there is no `allowUnused` here:
/// per the unifying rule, a single binding's liveness is tracked on the
/// *binding* (the dead-binding warning sits on the `@Provides`/`@Singleton`,
/// where `allowUnused:` also lives), not on the key. The key declaration
/// is tracked only so a reference to it can be validated and (later)
/// resolved to its type.
package struct DiscoveredBindingKey: Sendable, Equatable {
    /// Canonical reference text used to match `@Inject(K)` / `@Provides(K)`
    /// sites against this declaration — `Database.primary` for a
    /// `static let primary` on (an extension of) `Database`, or just
    /// `primary` for a module-scope key. Same string-keyed discipline as
    /// `DiscoveredMultibindingKey.keyReference`.
    package let keyReference: String
    /// The key's phantom type argument, verbatim — `Database` for
    /// `BindingKey<Database>`. `nil` when the declaration names no
    /// generic argument (`= BindingKey()` with no annotation); the type
    /// is then producer-side only. Carried for the value-level scope key
    /// (Axis B) and cross-module type checks; 7a's missing-key diagnostic
    /// uses only `keyReference`.
    package let typeArgument: String?
    package let location: SourceLocation
    /// Effective access — the declaration's own modifier folded with
    /// every enclosing type's access. Drives the cross-module visibility
    /// threshold (7f); not consumed single-module in 7a.
    package let accessLevel: AccessLevel
    /// The module this key was discovered in. Used for cross-module key
    /// references (7f).
    package let originModule: String

    package init(
        keyReference: String,
        typeArgument: String?,
        location: SourceLocation,
        accessLevel: AccessLevel,
        originModule: String
    ) {
        self.keyReference = keyReference
        self.typeArgument = typeArgument
        self.location = location
        self.accessLevel = accessLevel
        self.originModule = originModule
    }
}

/// Recognise a single-binding key declaration — a `let`/`static let`
/// whose type is `BindingKey<T>` — and capture its canonical reference
/// text, phantom type argument, and effective access. The type argument
/// comes from the explicit annotation when present, otherwise from a
/// constructor-call initialiser. Returns `nil` for any declaration that
/// doesn't name `BindingKey`.
func bindingKey(
    from node: VariableDeclSyntax,
    enclosingTypeNames: [String],
    enclosingAccessLevels: [AccessLevel],
    sourcePath: String,
    converter: SourceLocationConverter,
    module: String
) -> DiscoveredBindingKey? {
    guard node.bindings.count == 1, let binding = node.bindings.first else { return nil }
    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
    guard
        let typeArguments = bindingKeyTypeArguments(
            annotation: binding.typeAnnotation?.type,
            initializer: binding.initializer?.value
        )
    else { return nil }

    let keyReference = (enclosingTypeNames + [pattern.identifier.text]).joined(separator: ".")
    let effectiveAccess =
        enclosingAccessLevels
        .reduce(accessLevel(from: node.modifiers)) { $0.mostRestrictive(with: $1) }

    return DiscoveredBindingKey(
        keyReference: keyReference,
        typeArgument: typeArguments.first,
        location: makeSourceLocation(of: pattern.identifier, sourcePath: sourcePath, converter: converter),
        accessLevel: effectiveAccess,
        originModule: module
    )
}

/// The generic argument list of a `BindingKey` declaration (read from the
/// type annotation or the constructor-call initialiser), or `nil` when the
/// declaration doesn't name `BindingKey` at all. An empty array means
/// `BindingKey` named without generics (`= BindingKey()` and no
/// annotation) — recognised as a key, type unknown.
private func bindingKeyTypeArguments(
    annotation: TypeSyntax?,
    initializer: ExprSyntax?
) -> [String]? {
    if let identifier = annotation?.as(IdentifierTypeSyntax.self), identifier.name.text == "BindingKey" {
        return genericArgumentList(identifier.genericArgumentClause)
    }
    guard let call = initializer?.as(FunctionCallExprSyntax.self) else { return nil }
    let called = call.calledExpression
    if let specialization = called.as(GenericSpecializationExprSyntax.self),
        let reference = specialization.expression.as(DeclReferenceExprSyntax.self),
        reference.baseName.text == "BindingKey"
    {
        return genericArgumentList(specialization.genericArgumentClause)
    }
    if let reference = called.as(DeclReferenceExprSyntax.self), reference.baseName.text == "BindingKey" {
        return []
    }
    return nil
}
