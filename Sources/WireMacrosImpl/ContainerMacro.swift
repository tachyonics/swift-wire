import SwiftSyntax
import SwiftSyntaxMacros

/// `@Container` is a marker peer macro. It generates no code on its own
/// — its purpose is to be recognised by the build plugin's source scan,
/// which routes the container's `@Provides` declarations and nested
/// `@Singleton` types into a separate selectable graph
/// (`_<ContainerName>WireGraph`) rather than the default graph.
///
/// All `@Container`-annotated declarations targeting the same type
/// name merge their bindings into one logical container — a primary
/// `@Container enum Foo { ... }` plus any `@Container extension Foo`
/// or `@Container struct Foo` declarations contribute jointly to
/// Foo's container. A plain `extension Foo { ... }` *without* the
/// `@Container` annotation does not contribute to the container; its
/// bindings fall through to the default graph. Cross-type
/// composition (multiple unrelated types contributing to one logical
/// container) and container-includes-container hierarchies are
/// deferred — see the `ContainerKey` and `@Container(includes:)`
/// design sketches in M1_PLAN.md.
public struct ContainerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
