/// Shared emission for visibility-driven diagnostics raised at discovery
/// time. The model these diagnostics enforce — which binding surfaces
/// must be reachable from Wire's generated bootstrap, and why — is
/// pinned in `Documentation/Notes/VisibilityModel.md`.

/// Build the declaration-too-private error diagnostic for a binding
/// whose *effective* access — its own modifier folded together with
/// every enclosing scope — puts it below `internal`. Wire's generated
/// bootstrap lives in a separate file and can't reach `fileprivate` or
/// `private` declarations. Returns `nil` when the binding is reachable.
///
/// `surfaceLabel` names the binding surface and matches the wording the
/// user sees in the diagnostic — e.g. `"@Provides declaration"`,
/// `"@Provides function"`, `"@Singleton type"`, `"@Scoped type"`. Each
/// surface gets its own label so the user can scan straight to the
/// declaration kind.
///
/// `enclosing` is the chain of enclosing scope `(name, access)` pairs.
/// When an enclosing scope — not the binding's own modifier — is what
/// pushes the effective access below `internal`, the message names that
/// scope as the type to raise; the binding itself may be written
/// `internal` and look fine in isolation. Swift caps a member's
/// effective access at the most restrictive level in its enclosing
/// chain, so a `@Provides static let` written `internal` is unreachable
/// inside a `private enum`.
func declarationTooPrivateDiagnostic(
    surfaceLabel: String,
    name: String,
    ownAccess: AccessLevel,
    enclosing: [(name: String, access: AccessLevel)] = [],
    location: SourceLocation
) -> Diagnostic? {
    let access = enclosing.reduce(ownAccess) { $0.mostRestrictive(with: $1.access) }
    guard !access.isVisibleToGeneratedCode else { return nil }
    // Blame an enclosing scope only when the binding's own modifier is
    // itself reachable — otherwise the own-modifier fix is the primary
    // one to surface. The limiter is the most restrictive enclosing
    // scope the generated bootstrap can't reach.
    let enclosingCulprit =
        ownAccess.isVisibleToGeneratedCode
        ? enclosing.filter { !$0.access.isVisibleToGeneratedCode }
            .max { $0.access.restrictionRank < $1.access.restrictionRank }
        : nil
    let message: String
    if let culprit = enclosingCulprit {
        message =
            "\(surfaceLabel) '\(name)' is effectively '\(access.keyword)' because its enclosing "
            + "scope '\(culprit.name)' is '\(culprit.access.keyword)' — Wire's generated bootstrap "
            + "lives in a separate file and can't reference fileprivate/private declarations. "
            + "Raise '\(culprit.name)' to 'internal', 'package', or 'public'."
    } else {
        message =
            "\(surfaceLabel) '\(name)' is '\(access.keyword)' but must be at least 'internal' — "
            + "Wire's generated bootstrap lives in a separate file and can't reference "
            + "fileprivate/private declarations. Change to 'internal', 'package', or 'public'."
    }
    return Diagnostic(location: location, message: message, severity: .error)
}
