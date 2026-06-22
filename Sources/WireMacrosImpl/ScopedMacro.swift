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
///
/// On a struct/class/actor it synthesises `init`/`key` (delegating to
/// `@Singleton`). On a namespace `enum` it synthesises nothing — there
/// `@Scoped(seed:)` is a scope-block marker the build plugin reads to
/// route the block's `@Provides` into the seed scope (the scope-axis
/// sibling of `@Container`). Any other declaration kind is unsupported.
public struct ScopedMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Scope-block form: `@Scoped(seed:)` on a namespace enum is an
        // inert marker (like `@Container`); the plugin does the routing.
        if declaration.is(EnumDeclSyntax.self) {
            return []
        }
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
            return "@Scoped can only be applied to a struct, class, or actor, or a namespace enum (as a scope block)."
        }
    }
}
