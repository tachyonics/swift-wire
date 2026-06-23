import SwiftSyntax

// Discovery for `@Teardown` — the explicit teardown annotation. Two forms:
//
// - **Owned-type member form** — bare `@Teardown` on a method of a
//   `@Singleton`/`@Scoped` type (`teardownMethodAction`). The method is
//   called on the constructed instance at scope teardown; its effect
//   specifiers carry the call colour.
// - **Producer form** — `@Teardown(<action>)` on a `@Provides` declaration
//   (`providerTeardownAction`). The action expression (closure or
//   free/static function reference) is applied to the produced value.
//
// M1 records the action but emits nothing — the reverse-dependency
// teardown walk is M4. The helpers here also carry the iteration-6
// misuse diagnostics. See README "Lifecycle and teardown".

/// A teardown action recorded from a `@Teardown` annotation. In M1 it is
/// captured but inert — code emission ignores it; M4 emits the call in
/// reverse dependency order at scope teardown. See the README's
/// "Lifecycle and teardown" section and M1_PLAN iteration 6.
package struct TeardownAction: Sendable, Equatable {
    package enum Kind: Sendable, Equatable {
        /// Owned-type member form — `@Teardown func teardown() async throws`
        /// on a `@Singleton`/`@Scoped` type. The method is invoked on the
        /// constructed instance; `isAsync`/`isThrowing` are read off the
        /// method's effect specifiers so the (future) call site gets the
        /// right `try`/`await` colour.
        case member(methodName: String, isAsync: Bool, isThrowing: Bool)
        /// Producer form — `@Teardown(<action>)` on a `@Provides`. The
        /// action expression (a closure literal or a free/static function
        /// reference), captured verbatim, is applied to the produced value.
        /// Treated as `async throws` at the (future) call site: the macro's
        /// parameter type pins the contract and sync actions coerce in.
        case action(expression: String)
    }
    package let kind: Kind
    /// The `@Teardown` declaration's source position — for misuse
    /// diagnostics and (eventually) any teardown-ordering diagnostic.
    package let location: SourceLocation

    package init(kind: Kind, location: SourceLocation) {
        self.kind = kind
        self.location = location
    }
}

/// Every `@Teardown` attribute in the list (there should be at most one;
/// more than one is a misuse the callers diagnose).
private func teardownAttributes(in attributes: AttributeListSyntax) -> [AttributeSyntax] {
    attributes.compactMap { element in
        guard let attribute = element.as(AttributeSyntax.self) else { return nil }
        return wireMacroNameMatches(attribute.attributeName.trimmedDescription, "Teardown")
            ? attribute
            : nil
    }
}

/// Build the owned-type teardown action from a `@Teardown`-marked method
/// on a `@Singleton`/`@Scoped` type, with the iteration-6 misuse
/// diagnostics. `alreadyHasTeardown` is `true` when an earlier member of
/// the same type already supplied a teardown — a binding declares at most
/// one. Returns `nil` (and a diagnostic) for the malformed shapes whose
/// recorded action would be meaningless; a too-private method is still
/// recorded (mirroring `@Inject func`), since the action is well-formed
/// and only its visibility is wrong.
func teardownMethodAction(
    from funcDecl: FunctionDeclSyntax,
    attribute teardownAttribute: AttributeSyntax,
    alreadyHasTeardown: Bool,
    sourcePath: String,
    converter: SourceLocationConverter
) -> (action: TeardownAction?, diagnostics: [Diagnostic]) {
    let location = makeSourceLocation(of: funcDecl.name, sourcePath: sourcePath, converter: converter)
    let methodName = funcDecl.name.text

    // Malformed shapes whose recorded action would be meaningless: bail
    // with the diagnostic, record nothing.
    if let blocking = blockingMemberTeardownMisuse(
        funcDecl: funcDecl,
        attribute: teardownAttribute,
        alreadyHasTeardown: alreadyHasTeardown,
        methodName: methodName,
        location: location
    ) {
        return (nil, [blocking])
    }

    // Well-formed action; only its visibility may be wrong. Record it
    // anyway (mirroring `@Inject func`) alongside any too-private error.
    var diagnostics: [Diagnostic] = []
    let access = accessLevel(from: funcDecl.modifiers)
    if !access.isVisibleToGeneratedCode {
        diagnostics.append(
            Diagnostic(
                location: location,
                message:
                    "@Teardown method '\(methodName)' is '\(access.keyword)' but must be at least 'internal' — Wire's generated bootstrap calls it at scope teardown and lives in a separate file. Change to 'internal', 'package', or 'public'.",
                severity: .error
            )
        )
    }
    let effects = functionEffectFlags(funcDecl.signature.effectSpecifiers)
    let action = TeardownAction(
        kind: .member(methodName: methodName, isAsync: effects.isAsync, isThrowing: effects.isThrowing),
        location: location
    )
    return (action, diagnostics)
}

/// The first blocking misuse of an owned-type `@Teardown` method, or
/// `nil` when the method's shape is well-formed.
private func blockingMemberTeardownMisuse(
    funcDecl: FunctionDeclSyntax,
    attribute teardownAttribute: AttributeSyntax,
    alreadyHasTeardown: Bool,
    methodName: String,
    location: SourceLocation
) -> Diagnostic? {
    if alreadyHasTeardown {
        return Diagnostic(
            location: location,
            message:
                "more than one @Teardown on this type — a binding may declare at most one teardown method.",
            severity: .error
        )
    }
    // The action-carrying overload (`@Teardown({ ... })`) belongs on a
    // `@Provides`; on an owned type's method the marker takes no argument.
    if teardownAttribute.arguments != nil {
        return Diagnostic(
            location: location,
            message:
                "the owned-type @Teardown takes no argument — it marks the teardown method on a @Singleton/@Scoped type. Remove the argument; the action-carrying form '@Teardown({ ... })' belongs on a @Provides.",
            severity: .error
        )
    }
    if funcDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) {
        return Diagnostic(
            location: location,
            message:
                "@Teardown method '\(methodName)' is 'static' — teardown runs on the constructed instance, so the method must be an instance method.",
            severity: .error
        )
    }
    if !funcDecl.signature.parameterClause.parameters.isEmpty {
        return Diagnostic(
            location: location,
            message:
                "@Teardown method '\(methodName)' takes parameters — a teardown method must take none (it is called on the instance with no resolved dependencies).",
            severity: .error
        )
    }
    return nil
}

/// Build the producer-form teardown action from a `@Provides`
/// declaration's attribute list, with the iteration-6 misuse
/// diagnostics. Returns `nil` when there's no `@Teardown`, or when the
/// `@Teardown` is the bare (argument-less) marker — which belongs on an
/// owned type's method, not a `@Provides`.
func providerTeardownAction(
    in attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> (action: TeardownAction?, diagnostics: [Diagnostic]) {
    let teardowns = teardownAttributes(in: attributes)
    guard let first = teardowns.first else { return (nil, []) }
    let location = makeSourceLocation(of: first.attributeName, sourcePath: sourcePath, converter: converter)
    var diagnostics: [Diagnostic] = []
    if teardowns.count > 1 {
        diagnostics.append(
            Diagnostic(
                location: location,
                message:
                    "more than one @Teardown on this @Provides — a binding may declare at most one teardown action.",
                severity: .error
            )
        )
    }
    guard
        let arguments = first.arguments?.as(LabeledExprListSyntax.self),
        let action = arguments.first
    else {
        diagnostics.append(
            Diagnostic(
                location: location,
                message:
                    "@Teardown on a @Provides requires a teardown action — a closure '@Teardown({ (value: T) in ... })' or a free/static function reference '@Teardown(shutdown)'. Bare @Teardown marks the teardown method on a @Singleton/@Scoped type.",
                severity: .error
            )
        )
        return (nil, diagnostics)
    }
    return (
        TeardownAction(kind: .action(expression: action.expression.trimmedDescription), location: location),
        diagnostics
    )
}

/// Diagnose `@Teardown` placed on a `@Singleton`/`@Scoped` *type*
/// declaration itself. Teardown for an owned type is marked on its
/// method, not on the type — the type-level placement is silently inert
/// otherwise, so flag it with the remedy.
func scopeBoundTypeTeardownMisuse(
    in attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    teardownAttributes(in: attributes).map { teardownAttribute in
        Diagnostic(
            location: makeSourceLocation(
                of: teardownAttribute.attributeName,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "@Teardown on a @Singleton/@Scoped type has no effect — mark the type's teardown method with @Teardown instead (e.g. '@Teardown func teardown() async throws { ... }').",
            severity: .error
        )
    }
}
