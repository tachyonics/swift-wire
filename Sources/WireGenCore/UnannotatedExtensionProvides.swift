/// One `@Provides` site found inside an unannotated extension.
/// Carried through discovery as a candidate; the build plugin
/// resolves it into a `Diagnostic` after the module-wide
/// `@Container`-name set is available.
package struct UnannotatedExtensionProvides: Sendable {
    /// The extension's extended type name — what the warning checks
    /// against the container set.
    package let extendedType: String
    /// Display name of the offending `@Provides` declaration, for
    /// the warning message (e.g. property/function source name).
    package let providerName: String
    /// Anchor for the warning's `file:line:col:` prefix.
    package let location: SourceLocation

    package init(extendedType: String, providerName: String, location: SourceLocation) {
        self.extendedType = extendedType
        self.providerName = providerName
        self.location = location
    }
}
