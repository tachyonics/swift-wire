import SwiftSyntax

// Axis A validation diagnostics — scope blocks. Run by the discovery
// visitor while processing scope-bound types.

/// A `@Singleton` type declared inside a `@Scoped(seed:)` scope block.
/// `@Singleton` is process-lifetime, so it can't live in a seed scope —
/// left unflagged it would silently route to the process graph, ignoring
/// the block. A `@Scoped(seed:)` type carries its own scope (`ownScope`
/// non-nil) and is fine; this only fires for the unscoped self-producer.
func singletonInScopeBlockDiagnostics(
    typeName: String,
    ownScope: ScopeKey?,
    blockSeed: ScopeKey?,
    location: SourceLocation
) -> [Diagnostic] {
    guard ownScope == nil, let blockSeed else { return [] }
    return [
        Diagnostic(
            location: location,
            message:
                "@Singleton '\(typeName)' can't live in the @Scoped(seed: \(blockSeed.seed).self) block — @Singleton is process-lifetime, not scoped. Use @Scoped(seed:) for a scoped self-producer, or move it out of the block.",
            severity: .error
        )
    ]
}

/// `@Container` plus a scope macro on the same type is almost always a
/// user error: `@Container` routes the type's static members into a
/// separate graph, while a scope macro makes the type a binding in the
/// *default* graph — the two roles can't both happen on one type, and
/// neither does what the user probably wants. Warn with a fix-it
/// pointing at the split.
func containerWithScopeDiagnostics(
    nameToken: TokenSyntax,
    attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    guard hasAttribute(attributes, named: "Container") else { return [] }
    guard let scope = scopeMacroNames.first(where: { hasAttribute(attributes, named: $0) })
    else { return [] }
    return [
        Diagnostic(
            location: makeSourceLocation(
                of: nameToken,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "'\(nameToken.text)' carries both @Container and @\(scope) — the two roles end up in separate graphs. Split into two declarations: a @\(scope) type for the binding, and a separate @Container type for the grouping."
        )
    ]
}
