import SwiftSyntax
import SwiftSyntaxMacros

/// `@Provides` is a marker peer macro. It generates no code on its own
/// — its purpose is to be recognised by the build plugin's source scan,
/// which aggregates `@Provides`-marked declarations into the default
/// graph alongside `@Singleton` types. A `@Provides` property
/// contributes a value with no dependencies; a `@Provides` function's
/// parameters become its dependencies.
public struct ProvidesMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
