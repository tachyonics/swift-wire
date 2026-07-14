import SwiftSyntax
import SwiftSyntaxMacros

/// `@Factory(key)` — type-level macro marking a factory *template*.
///
/// A factory template is to a factory what `@Singleton` is to a singleton: it
/// makes the type a Wire component and reads its `@Inject` members as
/// construction dependencies. It differs on two axes:
/// - the type is generic, and its generic parameters are *assisted* parameters
///   supplied per use-site (metatypes at the synthesised factory's `create`
///   call), not resolved from the graph;
/// - it is not registered as a binding of its own. The build plugin synthesises
///   one concrete factory per consumed `FactoryKey`, driven by the template's
///   consumers (`@Middleware(key)`) — see WireGenCore's factory-template
///   discovery.
///
/// The macro's only job is to generate the initialiser the synthesised factory
/// calls, from `@Inject` members, following the same rules as `@Singleton` (see
/// `InjectableInitSynthesis`). Generating it explicitly at the type's access
/// level — rather than relying on the memberwise init — is what lets the
/// plugin's cross-module `SessionMiddleware(store:)` call compile. It emits no
/// `static key`; the key is the user-declared `FactoryKey` passed as the macro
/// argument.
public struct FactoryMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let typeInfo = HostTypeInfo(declaration: declaration) else {
            throw FactoryMacroError.unsupportedDeclaration
        }

        let analysis = InjectableInitSynthesis.analyse(declaration)
        InjectableInitSynthesis.diagnoseInitConfiguration(analysis: analysis, context: context)

        // A user-provided (and `@Inject`-marked) init is the source of truth;
        // otherwise generate one from the `@Inject` members. No `static key` —
        // the template's identity is its `FactoryKey` argument.
        guard analysis.userInits.isEmpty else { return [] }
        return [
            InjectableInitSynthesis.renderInit(
                typeInfo: typeInfo,
                injectionPoints: analysis.injectionPoints
            )
        ]
    }
}

// MARK: - Errors

enum FactoryMacroError: Error, CustomStringConvertible {
    case unsupportedDeclaration

    var description: String {
        switch self {
        case .unsupportedDeclaration:
            return "@Factory can only be applied to a struct, class, or actor."
        }
    }
}
