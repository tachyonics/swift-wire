import SwiftSyntax
import SwiftSyntaxMacros

/// `@Container` is a marker peer macro. It generates no code on its own
/// — its purpose is to be recognised by the build plugin's source scan,
/// which routes the container's `@Provides` declarations and nested
/// `@Singleton` types into a separate selectable graph
/// (`_<ContainerName>WireGraph`) rather than the default graph.
///
/// Iteration 2b commits to single-declaration containers: only the
/// `@Provides`/`@Singleton` declared inside the container's primary
/// enum body count. `extension TestContainer { @Provides ... }` is
/// silently ignored — see `ContainerKey` in the deferred-decisions
/// section of M1_PLAN.md for the planned cross-file composition story.
public struct ContainerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
