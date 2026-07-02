// Public carrier for an adapter-annotation definition.
//
// An adapter package declares one of these per annotation it publishes (e.g.
// `@RoutedBy`), describing what the annotation's macro generates so the build
// plugin can validate the annotation's dependencies and emit registration
// calls without expanding the macro. Wire discovers the declaration
// syntactically (like a `BindingKey` declaration) and never executes it.
//
// Versioned by type: a change to the contract shape ships a new
// `WireAdapterAnnotationV2`, leaving adapters written against V1 working. The
// build plugin recognises each version by its type name.
public struct WireAdapterAnnotationV1: Sendable {
    /// Where the annotation attaches. M1 supports type-level only.
    public enum Form: Sendable {
        case typeLevel
    }

    /// The attribute's spelling without the leading `@` (e.g. `"RoutedBy"`).
    public let annotation: String
    public let form: Form

    /// A parenthesised `label: placeholder` list describing the parameters of
    /// the generated `_wireRegister`. Placeholders: `Self` (the annotated
    /// type), `$0` (the annotation's first type argument); any other token is
    /// a literal binding type.
    public let registerSignature: String

    public init(
        annotation: String,
        form: Form,
        registerSignature: String
    ) {
        self.annotation = annotation
        self.form = form
        self.registerSignature = registerSignature
    }
}
