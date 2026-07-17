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

    /// `@X` on a binding contributes a **generated proxy** — not the binding itself — into a
    /// multibinding key. The adapter's macro generates a peer type `<proxyTypePrefix><Binding>`
    /// that holds the binding (constructed its ordinary way) plus any factories the binding's
    /// input-edge use-sites demand, and carries the adapter's witness; the build plugin
    /// synthesises the proxy binding (depending on the binding + those factories), and the proxy,
    /// not the binding, flows into the multibinding. Keeps the annotated binding an ordinary
    /// footgun-free type — nothing about it depends on being constructed "the right way".
    case contributesProxy(to: Any, proxyTypePrefix: String)

    /// `@X(argument)` on a binding makes the binding depend on a graph value named by `argument` (an
    /// *input* edge), lifted onto the binding's contributor proxy. The **argument's kind** chooses what
    /// is injected:
    /// - a `FactoryKey` → the factory synthesised from the matching `@Factory(key)` template (its box-role
    ///   `create` + `@Inject` dependencies + the injected axis);
    /// - a `BindingKey<T>` → that keyed binding, by key;
    /// - `T.self` → the binding of type `T`, by type.
    ///
    /// So one capability spans the factory, keyed-binding, and by-type cases — the plugin dispatches on
    /// whether the argument is a factory key, a binding key, or a metatype.
    case injectsFromGraph

    /// `@X` / `@X(.role, …)` on a `@Factory` template supplies the **role mapping** for the
    /// factory's assisted (non-`@Inject`-typed) generic parameters. `roles` is the adapter's ordered
    /// vocabulary of canonical slot names (e.g. `["RequestContext", "Reader", "ResponseSender"]`), read
    /// by the plugin as **opaque ordered identifiers** — it names the synthesised `create`'s generic
    /// parameters and, at the call site, the fixed order the consumer's macro passes them in. A bare
    /// `@X` maps the template's assisted parameters to these roles *by order*; `@X(.a, .b, …)` maps them
    /// *by the listed roles* (positional over the assisted parameters, referenced `.` + the role name
    /// lower-cameled). Producer-side, joined to the template by type identity.
    case mapsFactoryRoles(roles: [String])

    /// `@X(...)` on a consumer's injection point rewrites how that dependency resolves
    /// (e.g. `@Configuration("port")`). Reserved — no pass yet.
    case rewritesInjection
}
