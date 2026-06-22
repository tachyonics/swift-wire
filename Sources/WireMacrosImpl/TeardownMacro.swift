import SwiftSyntax
import SwiftSyntaxMacros

/// `@Teardown` is a marker peer macro. It generates no code on its own
/// — its purpose is to be recognised by the build plugin's source scan,
/// which records the binding's teardown action so the scope's teardown
/// phase can run it (in M4; M1 records but emits nothing).
///
/// Two overloads share this implementation, distinguished only by the
/// build plugin reading the use site:
/// - the no-argument form marks the teardown *method* on a
///   `@Singleton`/`@Scoped` type (effects read off the method signature);
/// - the `@Teardown(<action>)` form carries a closure or function
///   reference on a `@Provides` declaration.
///
/// Neither needs the macro to generate anything — like `@Container` and
/// `@Provides`, the work happens in the plugin's parse, not in expansion.
public struct TeardownMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
