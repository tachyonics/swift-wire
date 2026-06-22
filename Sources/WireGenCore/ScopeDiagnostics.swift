import SwiftSyntax

// Axis A validation diagnostics — scope annotations on producers. Run
// per-declaration by the discovery visitor from the var/func visits.

/// A `@Scoped(seed:)` on a property or function with no co-located
/// `@Provides`. On a var/func `@Scoped` only modifies a *producer's*
/// scope, so without `@Provides` it's inert — the value never enters the
/// graph and the scope annotation is silently ignored. Flagging it
/// mirrors the bare-`@Contributes` check (a marker that needs a producer
/// to mean anything). On a type, `@Scoped` *is* the producer, so this
/// doesn't apply — the type visits never call this.
func strayScopedProviderDiagnostics(
    in attributes: AttributeListSyntax,
    sourcePath: String,
    converter: SourceLocationConverter
) -> [Diagnostic] {
    guard let scopedAttribute = attribute(in: attributes, named: "Scoped") else {
        return []
    }
    if hasAttribute(attributes, named: "Provides") {
        return []
    }
    return [
        Diagnostic(
            location: makeSourceLocation(
                of: scopedAttribute,
                sourcePath: sourcePath,
                converter: converter
            ),
            message:
                "@Scoped on a property or function requires a co-located @Provides — on its own it has no effect; Wire reads scope identity from a producer.",
            severity: .error
        )
    ]
}
