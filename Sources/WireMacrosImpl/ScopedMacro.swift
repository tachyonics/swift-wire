import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// `@Scoped(seed: X.self)` — type-level macro for seed-typed scopes.
///
/// The synthesised members (`init(...)` and `static var key`) are
/// identical to `@Singleton`. What makes `@Scoped` different is the
/// `seed:` argument: it identifies *which* scope this type belongs to.
/// The build plugin reads the seed type from the attribute's argument
/// list and routes the binding into the per-seed graph partition; the
/// expansion itself doesn't need to use the seed type, so this macro
/// delegates to the same expansion code as `@Singleton`.
///
/// Two `@Scoped(seed: X.self)` types share a scope. A `@Scoped(seed: A.self)`
/// type and a `@Scoped(seed: B.self)` type live in independent scopes
/// even when both scopes are active at runtime.
///
/// Validation parity with `@Singleton`: see that macro's doc comment.
public struct ScopedMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        do {
            return try SingletonMacro.expansion(
                of: node,
                providingMembersOf: declaration,
                conformingTo: protocols,
                in: context
            )
        } catch SingletonMacroError.unsupportedDeclaration {
            throw ScopedMacroError.unsupportedDeclaration
        }
    }
}

enum ScopedMacroError: Error, CustomStringConvertible {
    case unsupportedDeclaration

    var description: String {
        switch self {
        case .unsupportedDeclaration:
            return "@Scoped can only be applied to a struct, class, or actor."
        }
    }
}
