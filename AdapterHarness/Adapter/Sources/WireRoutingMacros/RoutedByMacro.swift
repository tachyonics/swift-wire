import SwiftSyntax
import SwiftSyntaxMacros

/// Adds the `Controller` conformance for an `@RoutedBy` type. Wire never reads
/// this — it only reads the `WireAdapterAnnotationV1` definition telling it the
/// attribute aliases `@Contributes(to: RoutingKeys.controllers)`; the conformance
/// is the adapter's own framework surface, generated at macro-expansion time.
public struct RoutedByMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let conformance: DeclSyntax = "extension \(type.trimmed): Controller {}"
        return [conformance.cast(ExtensionDeclSyntax.self)]
    }
}
