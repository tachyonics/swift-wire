/// Shared emission for visibility-driven diagnostics raised at discovery
/// time. The model these diagnostics enforce — which binding surfaces
/// must be reachable from Wire's generated bootstrap, and why — is
/// pinned in `Documentation/Notes/VisibilityModel.md`.

/// Build the declaration-too-private error diagnostic for a binding
/// whose source-level access modifier puts it below `internal`. Wire's
/// generated bootstrap lives in a separate file and can't reach
/// `fileprivate` or `private` declarations.
///
/// `surfaceLabel` names the binding surface and matches the wording the
/// user sees in the diagnostic — e.g. `"@Provides declaration"`,
/// `"@Provides function"`, `"@Singleton type"`, `"@Scoped type"`. Each
/// surface gets its own label so the user can scan straight to the
/// declaration kind.
func declarationTooPrivateDiagnostic(
    surfaceLabel: String,
    name: String,
    access: AccessLevel,
    location: SourceLocation
) -> Diagnostic? {
    guard !access.isVisibleToGeneratedCode else { return nil }
    let message =
        "\(surfaceLabel) '\(name)' is '\(access.keyword)' but must be at least 'internal' — "
        + "Wire's generated bootstrap lives in a separate file and can't reference "
        + "fileprivate/private declarations. Change to 'internal', 'package', or 'public'."
    return Diagnostic(location: location, message: message, severity: .error)
}
