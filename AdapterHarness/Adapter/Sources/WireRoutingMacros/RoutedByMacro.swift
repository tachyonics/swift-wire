import SwiftSyntax
import SwiftSyntaxMacros

/// Generates `_wireRegister(instance:router:)` for an `@RoutedBy(R.self)` type:
/// it extracts the router type from the annotation argument (the Spike-3
/// pattern) and registers the instance with the router. This is the adapter's
/// own framework logic, run at macro-expansion time — Wire never reads this
/// body, only the `WireAdapterAnnotationV1` definition describing the signature.
public struct RoutedByMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first
        else { return [] }

        var routerType = first.expression.trimmedDescription
        if routerType.hasSuffix(".self") {
            routerType = String(routerType.dropLast(".self".count))
        }

        return [
            """
            static func _wireRegister(instance: Self, router: \(raw: routerType)) {
                router.register(instance)
            }
            """
        ]
    }
}
