// Public carrier for an adapter-annotation definition.
//
// An adapter package declares one per annotation it publishes (e.g. `@RoutedBy`,
// `@Middleware`, `@Configuration`), stating what the attribute *does* to the declaration
// it sits on via a `WireAdapterCapability`. Wire discovers the declaration syntactically
// (like a `BindingKey` declaration) and never executes it — the capability and any key
// are read from the written syntax, not a runtime value.
//
// Versioned by type: a change to the contract shape ships a new `WireAdapterAnnotationV2`,
// leaving adapters written against V1 working. The build plugin recognises each version by
// its type name.
public struct WireAdapterAnnotationV1: Sendable {
    /// The attribute's spelling without the leading `@` (e.g. `"RoutedBy"`).
    public let annotation: String

    public init(annotation: String, capability: WireAdapterCapability) {
        self.annotation = annotation
    }
}

/// What an adapter annotation does to the declaration it is applied to. One family, so the
/// build plugin has a single recognizer and dispatches the passes off the capability. Not
/// `Sendable` (nor stored): it's a phantom argument read from source syntax, never executed —
/// `contributes(to:)` carries the key value only so the call site reads naturally.
public enum WireAdapterCapability {
    /// `@X` on a binding aliases `@Contributes(to: key)` — collates the binding into a
    /// multibinding key (an *output* edge).
    case contributes(to: Any)

    /// `@X(T.self)` on a binding makes the binding depend on `T` (an *input* edge),
    /// delivered at construction through a wrapping init the adapter's macro generates.
    /// `T` resolves to an *existing* binding.
    case injectsDependencyOnArgument

    /// `@X(key)` on a binding makes the binding depend on the factory for `key` (an
    /// *input* edge to a *synthesised* value): the build plugin synthesises one concrete
    /// factory per `FactoryKey` from the matching `@Factory(key)` template and injects it,
    /// delivered through the adapter's macro-generated wrapping init. The `.self` form of
    /// the argument is the concrete case — a pass-through factory over an existing binding.
    case injectsFactoryOnArgument

    /// `@X(...)` on a consumer's injection point rewrites how that dependency resolves
    /// (e.g. `@Configuration("port")`). Reserved — no pass yet.
    case rewritesInjection
}
