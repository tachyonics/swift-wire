# WireHummingbird — design note (M2)

> **Status:** design-space note for M2's first framework adapter, informed by
> [spike-8](../../../swift-wire-spikes/spike-8-hummingbird-request-scope/) (request-scope
> entry, proven against real Hummingbird) and a survey of
> [hummingbird-examples](https://github.com/hummingbird-project/hummingbird-examples).
> Builds on [AdapterModel.md](AdapterModel.md) (the `@RoutedBy` adapter contract),
> [WireMVCAbstraction.md](WireMVCAbstraction.md) (Tier-1 framework adapters), and
> [OpaqueTypesSupport.md](OpaqueTypesSupport.md) (lifting). Not a committed plan;
> it captures the model settled during M2 design discussion so implementation
> doesn't start from scratch. The scope-aware adapter contract below generalises
> `AdapterModel.md` and should fold back into it once built.

## What M2 is

A **Tier-1 framework adapter** (per WireMVCAbstraction): automate the
application-level wiring — construct controllers from Wire's graph and register
them with Hummingbird — while controllers keep their native Hummingbird form
(routes and handler signatures stay framework-shaped). It does **not** abstract
routes (that's WireMVC, M5) and does **not** cover OpenAPI `registerHandlers`
(that's WireOpenAPI / `@RoutedBy` for `APIProtocol`, M3).

The forcing case is task-cluster: its hand-written `buildApplication` (create
`Router`, add middleware, register the controller, construct `Application`)
becomes generated, and request-scoped observability (a request-tagged logger)
becomes expressible.

### What it rests on (already shipped / proven)

- **Controller construction** — the dominant Hummingbird idiom is a generic
  `struct Controller<Repository: RepoProtocol> { let repository: Repository }`,
  which is exactly the lift-the-minimum shape shipped in iteration 10. Wire
  already builds these; the adapter only registers them.
- **App-scoped registration** — `@RoutedBy`'s `_wireRegister(instance:, router:)`,
  proven by the AdapterHarness (concrete + full + partial lifting).
- **Request-scope entry** — spike-8 (mechanism B: per-request scope entered in
  the route wrapper, composing with opaque lifting, reading app singletons upward).
- **Multibinding collection** — `CollectedKey`, for the `[any Service]` list.

## The five sub-surfaces

From the hummingbird-examples survey, WireHummingbird spans:

1. **Controller construction** — native (lift-the-minimum); no new work.
2. **Route registration** — the scope-aware adapter contract (below).
3. **Service lifecycle** — `CollectedKey<any Service>` → `ServiceGroup`.
4. **Request scope** — spike-8's mechanism, generalised (below).
5. **Middleware** — the fold; the deferred parameterized-opaque `BuilderKey`.

## Scope model: bindings + roots

The load-bearing model. Drop the assumption that *a scope is one dependency
graph*; that's the degenerate case. The general shape:

> **A scope is a set of bindings + a set of roots. Construction materialises the
> subgraph reachable from the roots being materialised.**

- **App scope** materialises *all* its roots at bootstrap — so it looks like one
  graph (everything built at once). Roots here are implicit (reachable-from-a-
  consumer, or `allowUnused` in the home package — the M6b definition).
- **A seeded (request) scope** materialises *one explicitly-marked root* per
  request — so it looks like N subgraphs (one per root controller). Only the
  dispatched controller's subgraph is built.

Same machinery (roots + reachability + topological construction); the app scope
selects all roots at once, a request scope selects one per request.

### Why per-root, not eager-whole-scope

Request-scoped bindings do real per-request work — deriving a logger from the
request, loading a principal from a token, opening a transaction — and Wire can't
stop a binding from being expensive (a remote fetch). Materialising the *whole*
request scope per request would run every route's per-request work on every
request, regardless of which route was hit. That's not waste, it's wrong.
Per-root materialisation runs only the dispatched controller's subgraph.

No cross-root sharing problem arises: one request dispatches to exactly one
controller-root, and middleware populates the Hummingbird **context** (a separate
channel), not Wire request bindings. If multiple roots ever needed to share a
request-scoped instance *within* one request, that's a per-request scope
*instance* with caching — the deferred `Provider<T>`/lazy territory, not M2.

### Explicit roots

Unlike M6b's implicit app-scope roots, a request-scope root must be **explicitly
marked** — a controller isn't `@Inject`ed by anything (the framework dispatches
to it), so reachability-from-a-consumer doesn't find it, and `allowUnused` only
means "don't warn." The **adapter annotation is the root marker**: `@RoutedBy` /
`@HummingbirdRoutes` on a `@Scoped` controller means "the framework dispatches to
this per request" — i.e. "this is a per-request materialisation root."

### Prior art — compile-time frameworks especially

Explicit roots + per-scope-instance materialisation is well-trodden **compile-time**
ground. That's reassuring: the scoping isn't where Wire takes a risk (the novel
bit is the opaque-type lifting layered underneath it — the scope model itself is
conventional).

- **Dagger** (Java/Kotlin, annotation processor) — the canonical model, and
  structurally what we've landed on. Scopes are generated **`@Subcomponent`s**
  instantiated per entry; roots are **explicit** provision methods on the
  component interface; seeds are **`@BindsInstance`** on a `@Subcomponent.Factory`
  (a runtime value bound into the subcomponent — our `RequestSeed`). Dagger-on-
  server creates a request subcomponent per request and pulls the handler from it
  → request-scoped handlers, the model we're building.
- **SafeDI** (Swift, macros + build plugin — closest to Wire's own approach) —
  **`@Forwarded`** provides a runtime value at a subtree's instantiation,
  available to everything downstream: the seed forwarded into a per-entry subtree,
  macro-driven. The Swift-native compile-time precedent for exactly this shape.
- **Needle** (Uber) and **Weaver** (Scribd), both Swift code-generators —
  hierarchical scopes as a **tree of components / containers**; entering a scope
  instantiates a child. Same "materialise a subcomponent per entry," tree-structured.
- **Micronaut** (Java, AOT) — the other end: compile-time DI but **singleton
  controllers** with parameter binding, `@RequestScope` beans runtime-lazy
  (request-attribute cache). The compile-time exemplar for Hummingbird's own
  "singleton + request state via params" recommendation.

Runtime frameworks do the same shape dynamically — Guice (`injector.getInstance`),
ASP.NET Core (`GetRequiredService` on a per-request `IServiceScope`), Spring
(request-scoped proxies) all name the root and materialise per-root, lazy +
per-request-cached. None — compile-time or runtime — materialises a whole scope
blindly. In *mechanism*, the adapter annotation is Wire's compile-time equivalent
of a Dagger provision method / a `GetRequiredService` call site, and per-root
construction is a generated bootstrap rather than runtime lazy resolution.

So the split we support — Dagger-style per-request subcomponent vs
Micronaut/Spring-style singleton + params — appears on both sides of the
compile/runtime line, and we offer both (request-scoped opt-in, singleton
default; see *Positioning*, and note Hummingbird itself recommends the singleton
path — request-scoped controllers are possible there but need manual wiring).

**Where Wire differs — eagerness within a materialised scope.** Dagger (and the
others) build bindings **lazily** within a subcomponent — generated
`Provider`/`DoubleCheck`, built on first access, scoped instances cached. Wire
builds the **whole reachable subgraph from the selected root eagerly**, with
`Lazy<T>`/`Provider<T>` as the opt-out. Not an accident: it's Wire's eager-graph
philosophy (already how the app scope works) applied consistently to request
scopes — build-all-reachable-from-the-root, defer explicitly. Dagger inverts the
default (lazy, eager on demand). Neither is wrong; Wire stays internally
consistent, and `Lazy<T>` covers the finer-grained deferral Dagger gets for free.

## The scope-aware adapter contract

The mechanism that turns a marked root into registration. It generalises
`AdapterModel.md`'s single-shape contract.

### The annotation is scope-polymorphic

`@RoutedBy` *can* mark a root — which behaviour it triggers depends on the
**attached binding's scope**, not the annotation:

- on a `@Singleton` controller → app-scoped instance registration
  (`_wireRegister(instance:, router:)`, unchanged);
- on a `@Scoped(seed:)` controller → a request-scope root
  (`_wireRegisterScoped(…)`, per-request wrapper).

### The contract declares both sides

An adapter contract declares the scopes on **both** sides of a registration:

- **`selfScopes`** — the scopes the annotated binding (`Self`) may occupy.
  `@RoutedBy`: `{ singleton, seeded }`.
- **`collaboratorScopes`** — the scopes the collaborator it registers *with* (the
  `Router`, named by `@RoutedBy(Router.self)`) may occupy. `@RoutedBy`:
  `{ singleton }` — you register routes once, at app start.

Wire reads the *actual* scopes of `Self` and the collaborator, checks them
against the declared sets **and** the containment rule, then selects the mode:

> **Containment rule:** the collaborator must outlive `Self` (its scope contains
> `Self`'s). You register a narrower `Self` into a broader collaborator; the
> collaborator holds the route closures that materialise `Self` per `Self`-entry.

The `(Self scope × collaborator scope)` matrix for `@RoutedBy`:

| Self \ Router | singleton | seeded |
|---|---|---|
| **singleton** | `_wireRegister(instance:, router:)` | ✗ collaborator narrower than Self |
| **seeded** | `_wireRegisterScoped(…)` | (n/a — router isn't seeded) |

The impossible cells become **declared-invalid**, surfaced as adapter-contract
diagnostics rather than special-case checks:

- **Self broader than the collaborator** (a `@Singleton` controller registering
  with a per-request router) violates containment → error.
- A **`@Singleton` controller with a request-scoped `@Inject` dependency** is a
  separate, already-diagnosed case — Wire's existing cross-scope storage rule (a
  singleton can't store a scoped value); it fires independently of the adapter.

### Registration rule

**Register at the collaborator's (broader) scope; materialise `Self` at `Self`'s
scope.**

- `Self` scope == collaborator scope → register the constructed instance
  (`_wireRegister(instance:, router:)`).
- `Self` scope ⊂ collaborator scope → register a per-`Self`-entry wrapper
  (`_wireRegisterScoped(…)`), emitted once at the collaborator's scope.

With only two scope levels today, "the collaborator's scope" is the app/singleton
scope; the rule generalises to "the nearest common enclosing scope" if nested
scopes (`@Scoped(within:)`) ever land.

### `_wireRegisterScoped` mechanics

From spike-8 (mechanism B), corrected to be opacity-clean — the opaque per-request
graph is built and consumed *inside* each route closure, so it never appears in a
signature:

```swift
// generated by @HummingbirdRoutes on the @Scoped controller; called once at app scope.
extension TaskController {
  static func _wireRegisterScoped<Ctx: RequestContext>(
    on group: RouterGroup<Ctx>,
    app: _WireGraph
  ) {
    group.get(":id") { req, ctx in
      let seed = RequestSeed(request: req, context: ctx)      // seed from (Request, Context)
      let controller = _Wire.requestScope(seed: seed, app: app).taskController  // per-root bootstrap
      return try controller.getTask(req, ctx)                 // dispatch
    }
    // one closure per declared route
  }
}
```

Two decisions this encodes:

1. **The seed-owning adapter references the scope's public bootstrap entry.**
   WireHummingbird *owns* `RequestSeed` and declares the scope keyed on it, so its
   codegen legitimately references the scope's public entry (`_Wire.requestScope(seed:)`,
   the `_Wire.bootstrap()` analog) — not an arbitrary cross-package reference. It
   references the **public façade entry**, keeping the uniform generated surface.
2. **Per-root bootstrap.** `_Wire.requestScope(seed:app:)` (or a per-controller
   `_Wire.makeTaskController(seed:app:)`) builds only the dispatched controller's
   reachable subgraph — reusing the reachability analysis M6b needs anyway.

### How the mode is selected

The binding's **scope is the single source of truth**, read in two places:

- **Macro (generation):** the `@RoutedBy`/`@HummingbirdRoutes` member macro reads
  the co-located `@Scoped(seed:)` — which it needs anyway to name the seed type —
  so detecting scoped-ness is a byproduct: `@Scoped(seed:)` present → generate
  `_wireRegisterScoped` referencing the scope entry; absent → `_wireRegister(instance:)`.
- **Plugin (call emission):** Wire's build plugin, authoritative on each binding's
  scope, emits the call to whichever entry, at the collaborator's scope.

**Caveat / boundary:** the macro's scope detection is syntactic — it only sees
attributes on the *same declaration*. That covers controllers (`@Scoped` is on
the type). If scope ever came from enclosing context (a `@Container`-nested
binding), the macro couldn't see it and the plugin would have to drive selection,
which pushes toward generating the wrapper in the plugin's route-assembly codegen
rather than the controller's macro. Controllers aren't `@Container`-nested, so the
macro path is fine for M2; this is the edge where it stops working.

## Request scope ↔ Hummingbird context: layered, not competing

Hummingbird threads request state through the generic `Context` parameter, never
storage-on-request (confirmed across the examples). Wire's request scope and the
Hummingbird context are **layers, not rivals**:

- **Context = framework/middleware-owned state** — `context.identity`, sessions,
  the request logger/id. Populated by Hummingbird's middleware ecosystem (auth,
  sessions), which we don't want to reinvent.
- **Wire request scope = app-composed request services** — derived from the seed
  (a request-tagged logger, a per-request client, a tenant object).

They compose: the seed is built from `(Request, Context)`, so Wire's request scope
can read context-populated values through the seed. A controller can use both.

## Positioning: opt-in, layered over Hummingbird's idiom

Request-scoped controllers diverge from Hummingbird's recommended singleton +
context idiom. That divergence is justified and additive:

- **It's opt-in.** A `@Singleton` controller reading the context still works,
  registers the app-scoped way, and has zero per-request construction cost. The
  documented default stays singleton + context; request-scoped is the
  deeper-adoption step (WireMVCAbstraction's three-step progression).
- **WireMVC (M5) needs it.** Cross-framework portable controllers can't lean on a
  framework-specific request-state channel (Hummingbird's `Context`, Vapor's
  `Request` storage). "A request-scoped binding with injected request deps" is the
  one framework-agnostic model — so building the request-scoped-root machinery in
  M2 is the foundation M5 sits on, proven early against the hardest framework.
- **It matches Wire's audience** (the JVM-DI on-ramp, where request scopes are
  idiomatic).

Cost is a conscious choice: `@Scoped` controllers construct a subgraph per
request; docs should let users pick with eyes open, default to the cheap path.

## Service lifecycle: `CollectedKey` → `ServiceGroup`

Every example converges on `[any Service]` → `ServiceGroup(services:,
gracefulShutdownSignals:)` → `run()`; the `Application` is itself a `Service`;
external types (AWSClient, PostgresClient) are extended to conform. Maps directly:

- `@Contributes` services into a `CollectedKey<any Service>` — the M2 forcing case
  for `CollectedKey`.
- Hand the collection to the `ServiceGroup`. **Startup order = Wire's topological
  order; shutdown = reverse** — which is exactly `@Teardown`'s reverse-order model
  (M4). Clean fit; `@Teardown` emission is M4, but the ordering aligns now.

## Middleware: the fold

task-cluster's `router.addMiddleware { LogRequestsMiddleware(.info) }` and the
auth examples' `addMiddleware { LogRequestsMiddleware; SessionMiddleware(storage:
fluentPersist) }` are a **fold of middleware that need DI** (injected storage,
auth key collections). That's the concrete consumer for the parameterized-opaque
`BuilderKey` deferred to M2 (see [OpaqueTypesSupport.md](OpaqueTypesSupport.md),
*Deferred to M2*, and [BuilderKeyDesign.md](BuilderKeyDesign.md)). Middleware are
app-scoped bindings; the fold assembles the stack from the graph.

## Composition-root automation

WireHummingbird generates the `buildApplication` equivalent — create the router,
fold middleware, register annotated controllers (app-scoped and request-scoped),
collect services, construct the `Application` — replacing task-cluster's
hand-written one. `_Wire.bootstrap()` still yields the app graph; the generated
assembly consumes it.

## Suggested sequencing

1. **Minimal slice** — composition-root automation + `[any Service]` collection +
   `@HummingbirdRoutes` for **app-scoped** controllers (uses the existing
   `_wireRegister` contract; no new scope machinery). Replaces task-cluster's
   manual `buildApplication` end-to-end.
2. **Request scope** — the scope-aware contract (`selfScopes`/`collaboratorScopes`),
   per-root request bootstraps, `_wireRegisterScoped`. Proven by spike-8.
3. **Middleware fold** — the parameterized-opaque `BuilderKey`.

## Open decisions to pin

- `_wireRegisterScoped` in the controller macro (references the public scope
  entry) vs the plugin's route-assembly codegen (owns wrapper generation). Leaning
  macro for scope-on-the-type; plugin is the fallback for enclosing-context scope.
- Per-root bootstrap surface: one `_Wire.requestScope(seed:)` returning a graph
  the wrapper indexes, vs per-controller `_Wire.makeX(seed:)`. The latter is
  leaner per route; the former is fewer entry points.
- The two-sided scope contract's home: fold into `AdapterModel.md` once built.
- The `(Request, Context) → seed` bridge: a WireHummingbird convention vs a
  user-provided conformance.

## References

- [spike-8](../../../swift-wire-spikes/spike-8-hummingbird-request-scope/) — request-scope entry, mechanism B.
- [WireMVCAbstraction.md](WireMVCAbstraction.md) — Tier-1 vs Tier-2, the three-step adoption progression.
- [AdapterModel.md](AdapterModel.md) — the `@RoutedBy` adapter contract this extends.
- [OpaqueTypesSupport.md](OpaqueTypesSupport.md) — lifting; the deferred parameterized-opaque `BuilderKey`.
- [BuilderKeyDesign.md](BuilderKeyDesign.md) — the middleware-fold key.
