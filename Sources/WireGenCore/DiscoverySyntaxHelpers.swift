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
