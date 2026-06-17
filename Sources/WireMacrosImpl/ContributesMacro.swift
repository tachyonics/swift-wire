import SwiftSyntax
import SwiftSyntaxMacros

/// `@Contributes(to:)` is a marker peer macro. It generates no code on
/// its own — its purpose is to be recognised by the build plugin's
/// source scan, which records the annotated declaration as a contributor
/// to the referenced multibinding key and folds it into the aggregate.
///
/// All flavour/argument validity (`atKey:` required on `MappedKey`,
/// `withOrder:` disallowed on `MappedKey`, the key-type of `atKey:`) is
/// carried by the `@Contributes` overload set at the type level (see
/// `Macros.swift`); the build plugin only enforces the cross-contributor
/// rules overloads can't see (no-mixing `withOrder:`, duplicate `atKey:`).
public struct ContributesMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
