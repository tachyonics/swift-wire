# Bootstrap collation — design note (M5)

> **Status:** captured during M4.2. A design space for the **Tier-2 composition-root
> macro** (M5.2), not a committed plan. Records the "an adapter's contributions must be
> applied, but nothing enforces it" problem and a mechanism for collating the apply
> steps, so M5's Tier-2 work doesn't start from scratch.

## The problem

Each framework adapter collates contributions into its own keys and ships an `apply`
facade the app calls at bootstrap to wire them onto the runtime:

- `WireHummingbird.apply(graph, to: router)` — mounts `@HummingbirdController` routes and
  returns `@HummingbirdService` services.
- `WireOpenAPI.apply(graph, to: transport)` — registers `@OpenAPIController` handlers.
- (M5) `WireMVC.apply(graph, to: transport)` — the declarative-routing equivalent.

**Nothing enforces that the app calls every adapter whose keys have contributions.** Add a
`@HummingbirdController` to an app that only calls `WireOpenAPI.apply`, and the route
collates into `HummingbirdKeys.routes` and simply never mounts — no error, silent
breakage. task-cluster exhibits this today (it calls `WireOpenAPI.apply` +
`mountIntrospection`, not `WireHummingbird.apply`; it's only safe because it has no
Hummingbird contributions).

Teardown is **not** an instance of this problem — it's a *graph* concern (`Teardownable`,
universal), applied by a single standalone `teardownService`, so there's no "which
adapter" ambiguity. This note is about the *adapter* apply steps.

## Why documentation isn't enough

The obvious fallback — "document that every adapter's `apply` must be called" — breaks on
the Tier-2 composition-root macro. A Hummingbird-specific `@WireHummingbird` bootstrap
macro codifies `bootstrap → router → apply → Application → run`, but it can't know it
should *also* call `WireOpenAPI.apply` / `WireMVC.apply` — those are cross-runtime
adapters it has no compile-time knowledge of. So the macro must **collate** apply steps,
not hard-code its own.

## Mechanism — collated apply steps

Same discipline as the existing adapter contracts (`WireGraphConformanceV1`,
`WireAdapterAnnotationV1`, `WireGraphConformanceV1`): an adapter *declares* its apply step,
and the plugin discovers it by re-parsing sources.

```swift
// WireOpenAPI declares:
public let wireOpenAPIApplyStep = WireApplyStepV1(
    entry: "WireOpenAPI.apply",              // called as entry(graph, to: <target>)
    targetConformsTo: (any ServerTransport).self
)
// WireHummingbird declares one targeting (any RouterMethods<…>) / its composable.
```

The Tier-2 composition-root macro (which knows the runtime and builds the target — a
Hummingbird `Router`) emits `<step.entry>(graph, to: router)` for **every** discovered
step. It never names WireOpenAPI or WireMVC; WireMVC declaring a step is all it takes for
the macro to call it. This is the collation pattern the adapters already use, lifted to
the bootstrap.

### The cross-runtime conformance is a *feature* here

The router conforms to `ServerTransport` only if a transport bridge (`OpenAPIHummingbird`)
is imported. So a generated `WireOpenAPI.apply(graph, to: router)` in an app that depends
on WireOpenAPI but hasn't imported a bridge is a **compile error** — which converts
today's *silent runtime* under-wiring into a *loud build-time* one. That's the
improvement. And because the plugin knows the step's `targetConformsTo`, it can emit a
targeted diagnostic — "WireOpenAPI applies to `some ServerTransport`; your router isn't
one — add `import OpenAPIHummingbird`" — rather than a raw conformance error.

Teardown folds in as one more collated step (unconditional, since every graph is
`Teardownable`), so the Tier-2 bootstrap ends with the graph teardown wired without the
app doing anything.

## Interim: a build-time reminder (could land before M5)

Short of full collation, the plugin already knows each collation key's contribution count.
A build note when a key has contributions — "graph has N `HummingbirdKeys.routes`
contributions; ensure `WireHummingbird.apply` is wired at bootstrap" — surfaces the
requirement without generating any bootstrap. Non-enforcing, cheap, and it would have
caught the "added a controller, forgot `apply`" case. A candidate for M4/pre-1.0 polish if
Tier-2 is far off.

## Open questions for M5

1. **Step ordering.** Does apply order matter across adapters (routes vs handlers on the
   same router)? Likely independent, but the collated steps need a deterministic order.
2. **Target construction.** The Tier-2 macro builds the runtime target (HB `Router`); a
   `WireVapor` Tier-2 would build a Vapor `Application`. The step's `targetConformsTo`
   protocol is the contract; the macro supplies a conforming value.
3. **Manual (Tier-1) apps.** They keep calling `apply` by hand. The interim diagnostic is
   their safety net; full collation is a Tier-2 benefit.

## References

- [AdapterModel.md](AdapterModel.md) — the contribution-alias contract this extends.
- [WireHummingbirdDesign.md](WireHummingbirdDesign.md) — the Tier-2 macro (`bootstrap →
  router → apply → Application → run`) this generalises.
- [WireMVCAbstraction.md](WireMVCAbstraction.md) — the cross-runtime adapters whose apply
  steps must collate.
