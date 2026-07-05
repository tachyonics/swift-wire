// Public carrier for an adapter-annotation definition.
//
// An adapter package declares one per annotation it publishes (e.g. `@RoutedBy`,
// `@HummingbirdRoute`): the attribute `@annotation` on a binding is an alias for
// `@Contributes(to: contributesTo)`, so the build plugin collates the annotated
// binding into that multibinding key. Wire discovers the declaration syntactically
// (like a `BindingKey` declaration) and never executes it — `contributesTo` is read
// as its written key reference, not its runtime value.
//
// Versioned by type: a change to the contract shape ships a new
// `WireAdapterAnnotationV2`, leaving adapters written against V1 working. The build
// plugin recognises each version by its type name.
public struct WireAdapterAnnotationV1: Sendable {
    /// The attribute's spelling without the leading `@` (e.g. `"RoutedBy"`).
    public let annotation: String

    public init(annotation: String, contributesTo: Any) {
        self.annotation = annotation
    }
}
