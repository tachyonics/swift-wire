import SwiftSyntax
import SwiftSyntaxMacros

/// `@BindType` is a bare marker peer macro. It generates no code on its own —
/// its purpose is to be recognised by the build plugin's source scan, which
/// records the `(slot, Mock)` substitution against the `TestingKey` static it
/// attaches to, so the test graph binds the slot to `Mock` and sources its
/// instance from the scope-entry doubles.
///
/// Like `@Replaces`, `@Provides`, and the other markers, the work happens in the
/// plugin's parse, not in expansion.
public struct BindTypeMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
