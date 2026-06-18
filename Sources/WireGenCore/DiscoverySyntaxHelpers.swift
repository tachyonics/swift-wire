import SwiftSyntax

// Shared syntax-extraction helpers used across the discovery files
// (the visitor, the multibinding scanners, the diagnostic helpers).
// Free functions, factored out of `BindingDiscovery` to keep that file
// under the `file_length` cap.

func makeSourceLocation(
    of node: some SyntaxProtocol,
    sourcePath: String,
    converter: SourceLocationConverter
) -> SourceLocation {
    let position = node.startLocation(converter: converter)
    return SourceLocation(file: sourcePath, line: position.line, column: position.column)
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
