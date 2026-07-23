import SwiftSyntax
import SwiftSyntaxMacros

/// `@Scopable` is a bare marker peer macro. It generates no code on its own —
/// its purpose is to be recognised by the build plugin's source scan, which
/// records that the named app-scoped (`@Singleton`) binding may be lifted into a
/// seeded scope under the `TestingKey` it attaches to, so a per-scope-entry
/// double can reach a singleton consumer (including at that consumer's `init`).
///
/// Like `@BindType`, `@Replaces`, and the other markers, the work happens in the
/// plugin's parse, not in expansion.
public struct ScopableMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
