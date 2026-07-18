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
    /// multibinding key. The build plugin synthesises the proxy binding and, at `proxyScope`, either
    /// **holds** the subject (when the subject shares that scope) or **bridges** into it (when the
    /// subject is narrower — e.g. a `@Scoped(seed:)` subject under a `.singleton` proxy: the proxy
    /// holds a scope-entry, constructing the subject on demand from a seed). Either way the proxy
    /// carries any factories the binding's input-edge use-sites demand, conforms to the adapter's
    /// contributor protocol, and the proxy — not the binding — flows into the multibinding. Keeps the
    /// annotated binding an ordinary footgun-free type. `proxyScope` is the scope of the aggregate the
    /// proxy collates into (where it must live to be collected once), and swift-wire compares it
    /// against the subject's scope to pick hold vs bridge.
    case contributesProxy(to: Any, proxyTypePrefix: String, proxyScope: WireProxyScope)

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

/// The scope at which a `.contributesProxy` proxy is emitted — the scope of the multibinding
/// aggregate it collates into, which is where the proxy must live to be collected and applied.
/// swift-wire compares it against the *subject's* scope: same scope → the proxy **holds** the
/// subject; the subject narrower → the proxy **bridges** into the subject's scope (a
/// `@Scoped(seed:)` subject under a `.singleton` proxy is a sanctioned scope bridge, not a
/// cross-scope violation). `.singleton` is the value for every collating adapter today (collation
/// happens at app scope); a seeded proxy scope is reserved for a future per-request-collation case.
public enum WireProxyScope: Sendable {
    /// The proxy is app-scoped — built once and collated into the app graph.
    case singleton
}
