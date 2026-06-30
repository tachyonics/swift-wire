import SwiftSyntax

// Shared syntax-extraction helpers used across the discovery files
// (the visitor, the multibinding scanners, the diagnostic helpers).

func makeSourceLocation(
    of node: some SyntaxProtocol,
    sourcePath: String,
    converter: SourceLocationConverter
) -> SourceLocation {
    let position = node.startLocation(converter: converter)
    return SourceLocation(file: sourcePath, line: position.line, column: position.column)
}

/// Extract the canonical key identifier from an attribute's argument
/// list. Returns `nil` for the unkeyed form (no parentheses or empty
/// argument list). For the keyed form `@Inject(<expr>)` returns the
/// trimmed text of `<expr>` — `Database.primary` → "Database.primary".
///
/// The build plugin matches keyed bindings to keyed consumers by
/// canonical text, so what the user writes IS the key. `Foo.primary`
/// on one side matches `Foo.primary` on the other; `.primary` does
/// not match `Foo.primary` (different canonical text), and Swift's
/// type inference for leading-dot is a separate concern handled by
/// the macro signature, not the build plugin.
func keyIdentifier(from attribute: AttributeSyntax) -> String? {
    guard case let .argumentList(args) = attribute.arguments else { return nil }
    // The key is the positional (unlabelled) first argument. A leading
    // labelled argument — e.g. `@Provides(allowUnused: true)` — means
    // there's no key, not that `allowUnused`'s value is the key.
    guard let firstArg = args.first, firstArg.label == nil else { return nil }
    return firstArg.expression.trimmedDescription
}

/// The parameter's external label — what callers write at the call
/// site. The generated bootstrap emits `Type(label: resolvedValue)`
/// calls and needs the label.
///
/// Returns `nil` for wildcard (`_`) labels so the call site is told
/// to omit the label entirely rather than emit `"_"` as a sentinel
/// the consumer has to special-case downstream.
///
/// - `init(label internal: A)` → `"label"`
/// - `init(_ a: A)` → `nil`
/// - `init(a: A)` → `"a"`
///
/// The internal name (`secondName`, when present) is irrelevant — it
/// only appears inside the init body, which is the user's code, not
/// Wire's.
func parameterName(_ parameter: FunctionParameterSyntax) -> String? {
    if parameter.firstName.tokenKind == .wildcard {
        return nil
    }
    return parameter.firstName.text
}

/// Extract the source-level read access from a declaration's
/// modifier list. Returns `.internal` (Swift's default) when no
/// bare access modifier is present.
///
/// Setter-restriction modifiers (`private(set)`, `fileprivate(set)`,
/// etc.) are intentionally skipped here — they restrict only the
/// property's setter without changing its external read access.
/// See `setterAccessLevel(from:)` for the matching extraction of
/// the setter restriction.
func accessLevel(from modifiers: DeclModifierListSyntax) -> AccessLevel {
    for modifier in modifiers {
        // Skip `private(set)` and similar — the `(set)` detail means
        // the modifier governs the setter, not the property's read
        // access. The bare modifier (if any) governs reads.
        if modifier.detail != nil { continue }
        switch modifier.name.text {
        case "open": return .open
        case "public": return .public
        case "package": return .package
        case "internal": return .internal
        case "fileprivate": return .fileprivate
        case "private": return .private
        default: continue
        }
    }
    return .internal
}

/// Extract the explicit setter-restriction access level from a
/// declaration's modifier list. Returns `nil` when no setter-
/// restricting modifier (`private(set)`, `fileprivate(set)`,
/// `internal(set)`, `package(set)`) is present — meaning the
/// setter inherits the property's read access.
///
/// Member injection's `propertyAssignment` shape (the
/// `@Inject weak var` sugar form) emits a post-construct write to
/// the property from Wire's generated bootstrap; a `private(set)`
/// or `fileprivate(set)` restriction blocks that write even when
/// the property's read access is otherwise reachable. The captured
/// setter level lets the diagnostic emit a tailored error
/// distinguishing setter-restriction failures from outright too-
/// private declarations.
func setterAccessLevel(from modifiers: DeclModifierListSyntax) -> AccessLevel? {
    for modifier in modifiers {
        guard let detail = modifier.detail,
            detail.detail.text == "set"
        else { continue }
        switch modifier.name.text {
        case "open": return .open
        case "public": return .public
        case "package": return .package
        case "internal": return .internal
        case "fileprivate": return .fileprivate
        case "private": return .private
        default: continue
        }
    }
    return nil
}

/// Extract the seed type expression from a `@Scoped(seed: SomeType.self)`
/// attribute. Returns the base of the `.self` member access — `"SomeType"`
/// for `SomeType.self`, `"Foo<Bar>"` for `Foo<Bar>.self`. Returns `nil`
/// if the attribute is malformed in a way Swift would catch later
/// (missing argument, non-`.self` expression).
///
/// Generic seed expressions are kept verbatim — `Foo<Bar>` and `Foo<Bar>`
/// are the same scope, `Foo<Baz>` is a different scope. The build
/// plugin's canonical-type-name whitespace normalisation kicks in
/// during graph identity comparisons separately.
func seedTypeExpression(from attribute: AttributeSyntax) -> String? {
    guard case let .argumentList(args) = attribute.arguments else { return nil }
    guard let seedArg = args.first(where: { $0.label?.text == "seed" }) else { return nil }
    guard let memberAccess = seedArg.expression.as(MemberAccessExprSyntax.self),
        memberAccess.declName.baseName.text == "self",
        let base = memberAccess.base
    else { return nil }
    return base.trimmedDescription
}

/// The opaque graph identity from `@Singleton(as: P.self)` — the `P` of the
/// `as:` argument — or `nil` when the attribute carries no `as:`. The binding is
/// then keyed as `some P`. Mirrors `seedTypeExpression`: validates the `.self`
/// metatype form and returns the base type verbatim.
func asTypeExpression(from attribute: AttributeSyntax) -> String? {
    guard case let .argumentList(args) = attribute.arguments else { return nil }
    guard let asArg = args.first(where: { $0.label?.text == "as" }) else { return nil }
    guard let memberAccess = asArg.expression.as(MemberAccessExprSyntax.self),
        memberAccess.declName.baseName.text == "self",
        let base = memberAccess.base
    else { return nil }
    return base.trimmedDescription
}

/// Recover the bound type from a `Foo(...)` or `Foo<Bar>(...)`
/// initializer when the user omitted the type annotation. Returns
/// `nil` for any other expression shape — member access
/// (`Foo.shared`), function calls returning unspecified types
/// (`makeFoo()`), literals, etc. — so the caller falls back to
/// skipping the declaration. The first-character-uppercase check
/// filters out lowercase function calls that would otherwise be
/// misidentified as type references.
func inferTypeFromConstructorCall(_ expr: ExprSyntax?) -> String? {
    guard let call = expr?.as(FunctionCallExprSyntax.self) else { return nil }
    let called = call.calledExpression
    // Plain `Foo` or generic-specialised `Foo<Bar>`. Member access
    // (`Foo.shared` or `Module.Foo`) is rejected — for a plain
    // type-construction call the called expression is a single
    // identifier or a generic specialization of one.
    guard
        called.is(DeclReferenceExprSyntax.self)
            || called.is(GenericSpecializationExprSyntax.self)
    else { return nil }
    let text = called.trimmedDescription
    guard let first = text.first, first.isUppercase else { return nil }
    return text
}
