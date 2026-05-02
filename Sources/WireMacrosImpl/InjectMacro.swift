import SwiftSyntax
import SwiftSyntaxMacros

/// `@Inject` is a marker peer macro. It generates no code on its own —
/// its purpose is to be recognised by the enclosing scope macro
/// (`@Singleton`, `@RequestScope`, `@JobScope`) when the latter walks the
/// type's stored properties to synthesise an initialiser.
public struct InjectMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
