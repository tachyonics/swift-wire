import SwiftSyntax
import SwiftSyntaxMacros

/// `@Replaces(T.self)` is a marker peer macro. It generates no code on its
/// own — its purpose is to be recognised by the build plugin's source scan,
/// which records the key `T` the co-located binding supersedes so the graph's
/// duplicate-binding resolution keeps this binding and drops the one it
/// replaces (see `WireGenCore/Graph.swift`'s `resolveReplacements`).
///
/// Like `@Teardown`, `@Container`, and `@Provides`, the work happens in the
/// plugin's parse, not in expansion.
public struct ReplacesMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
