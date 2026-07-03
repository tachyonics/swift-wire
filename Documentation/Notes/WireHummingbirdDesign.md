# WireHummingbird — design note (M2)

> **Status:** the model settled during M2 design, informed by
> [spike-8](../../../swift-wire-spikes/spike-8-hummingbird-request-scope/) (request-scope
> entry) and [spike-9](../../../swift-wire-spikes/spike-9-hummingbird-bootstrap/)
> (bootstrap shape + collation + context threading), both proven against real
> Hummingbird. Builds on [WireMVCAbstraction.md](WireMVCAbstraction.md) (Tier-1
> framework adapters) and [OpaqueTypesSupport.md](OpaqueTypesSupport.md) (lifting).
> **Supersedes the earlier scope-aware `@RoutedBy` adapter-registration contract**
> for this adapter (see *What changed* below); [AdapterModel.md](AdapterModel.md)'s
> side-effect registration model is not the mechanism WireHummingbird uses.

## What M2 is

A **Tier-1 framework adapter** (per WireMVCAbstraction): automate application-level
wiring — construct controllers from Wire's graph and get their routes/middleware
onto a Hummingbird `Router` — while controllers keep their native Hummingbird form
(routes and handler signatures stay framework-shaped). It does **not** abstract
routes (that's WireMVC, M5) and does **not** cover OpenAPI `registerHandlers`
(WireOpenAPI, M3).

The forcing case is task-cluster: its hand-written `buildApplication` (create
`Router`, add middleware, register the controller, collect services, construct
`Application`) becomes generated. **App-scoped only** — request-scoped controllers
need generated routing and are M5/WireMVC (see *Request scope is WireMVC-only*).

## What changed (why this note was rewritten)

The earlier model made the `Router` a **graph binding** that `@HummingbirdRoutes`
controllers *registered into* via a `_wireRegister` side effect, with a two-sided
scope-aware contract (`selfScopes`/`collaboratorScopes`, a containment rule). That
forced ordering machinery (a consumer of the mutated router had to be built after
registration) and a bespoke adapter-registration contract.

Spike-9 settled a simpler model: **the `Router` is a bootstrap builder that stays
outside the graph.** The graph only *collates contributions*; a facade applies
them to a user-provided builder and assembles the `Application`. Nothing in the
graph consumes a mutated collaborator, so the ordering problem never arises, and
the whole `_wireRegister` adapter-registration contract is unnecessary here.

## The architecture

### Router outside the graph; the graph collates contributions

- **Routes → a `CollectedKey`.** A controller is a `RouteContributor`:
  ```swift
  protocol RouteContributor<Context> {
      associatedtype Context: RequestContext
      func addRoutes(to router: some RouterMethods<Context>)   // generic over the router
  }
  ```
  Collated as `[any RouteContributor<Context>]`. Keeping `addRoutes` generic over
  the router (through the existential) lets the facade apply contributors to a root
  `Router` **or** a `RouterGroup` — the app context pinned as a primary associated
  type (spike-9, proven end-to-end). The contributor is either the controller
  **instance** (when its `addRoutes` already matches the requirement — no proxy) or
  a small **generated proxy** that conforms and delegates (when the signature
  doesn't — e.g. `addRoutes(to group: RouterGroup<Ctx>)` or a differently-named
  method). Both are collated identically; M2 covers both.
- **Middleware → a `BuilderKey`.** Because Wire knows the contributor set at
  codegen time, it emits them as *static* expressions inside Hummingbird's
  `@MiddlewareFixedTypeBuilder`, fusing them into one `some MiddlewareProtocol`
  (static composition, one existential boundary for the whole stack — the idiomatic
  `addMiddleware { … }` shape). This is the parameterized-opaque `BuilderKey`
  ([BuilderKeyDesign.md](BuilderKeyDesign.md), [OpaqueTypesSupport.md](OpaqueTypesSupport.md)),
  proven in spike-9. Routes can't fold to a single value (each applies its own
  routes as a side effect) — hence `CollectedKey`; middleware folds to a value —
  hence `BuilderKey`.

### Plain annotations, existing multibinding + container machinery

`@HummingbirdRoute` / `@HummingbirdMiddleware` are **plain macros** expanding to
`@Singleton @Contributes(to: HummingbirdRoutesKey)` and
`@Contributes(to: HummingbirdMiddlewareKey)` — where WireHummingbird ships
`HummingbirdRoutesKey = CollectedKey<any RouteContributor<Ctx>>` and
`HummingbirdMiddlewareKey = BuilderKey<…>`. No `WireAdapterAnnotationV1`, no
`_wireRegister`, no adapter-registration contract.

The **container is the app boundary**: `@Container(PublicAPI)` scopes a
contribution to that app's collections. Multibindings already fan in per partition
(`MultibindingDiagnostics.swift`: contributions "run per partition", and containers
*are* partitions), so per-container route/middleware collections fall out of
existing machinery — multiple Hummingbird apps in one process, each with its own
collections.

### The one new Wire Core capability: graph-conforms-to-declared-protocol-via-keys

`_WireGraph` is generated in the consumer module and exposes bindings as
generated-*named* properties (no generic `graph[Key.self]` accessor), so a
framework library can't read the collections off it directly. The bridge is
**generic and framework-ignorant**: an adapter declares a conformance, discovered
syntactically like a key declaration —

```swift
// contributed by WireHummingbird
WireGraphConformanceV1(
    conforms: HummingbirdComposable.self,
    members: [.member("routes",     from: HummingbirdRoutesKey.self),      // CollectedKey product
              .member("middleware", from: HummingbirdMiddlewareKey.self)]  // BuilderKey product
)
```

Wire emits `extension WireGraph: HummingbirdComposable { var routes { <collectedProp> } … }`,
mapping key products to the protocol's requirements — **without knowing the
protocol is HTTP-shaped**. Associated types (the protocol's `Context`) are inferred
from the key's element type (`CollectedKey<any RouteContributor<BasicRequestContext>>`
⇒ `Context = BasicRequestContext`). This replaces "adapter emits a code template"
with "adapter declares a conformance mapping" — declarative, no arbitrary codegen,
and reusable (WireOpenAPI surfaces its handler collection the same way).

**Concern split:** Wire Core = DI graph + multibindings + containers + this generic
conformance capability, zero framework knowledge. WireHummingbird = the
`HummingbirdComposable` protocol, the conformance declaration, the two macros, and
the `apply` library — all HTTP knowledge lives here.

### Public entry: `Wire<Module>.bootstrap()`

The bootstrap is consumed by user code and the adapter library, so it's public API
and shouldn't wear the `_Wire` "generated-internal" underscore. The underscore
partly existed to avoid clashing with the `Wire` *module* name; `Wire<Module>`
sidesteps that — the library defines `enum Wire<Module> {}` and generated code
extends it per module:

```swift
enum TaskClusterModule {}                                    // generated marker
extension Wire where Module == TaskClusterModule {           // generated
    public static func bootstrap() async throws -> some HummingbirdComposable { … }
}
// user / adapter: try await Wire<TaskClusterModule>.bootstrap()
```

**The bootstrap returns `some (<the composed contributed conformances>)`, and the
concrete graph type stays fully internal.** With only WireHummingbird present the
return is `some HummingbirdComposable`; with WireMVC too it's `some
(HummingbirdComposable & MVCComposable)` — Wire composes the return type from the
set of contributed `WireGraphConformanceV1` declarations. This keeps the concrete
`WireGraph` out of the public surface entirely (not "public type, internal
members" — *not public at all*), exposes exactly the capability set the graph
offers, and grows by `& NewComposable` as adapters are added. It composes with the
generic facades: `apply<G: HummingbirdComposable>(_:)` accepts a `some (A & B)`
value since it satisfies `HummingbirdComposable`, and Tier 1's `let graph = …`
never names the type. (Associated-type collisions across composed protocols — both
likely have `Context` — are harmless as long as consumers go through a
single-protocol-generic facade, where `G.Context` is unambiguous; direct `.Context`
on the raw composition would need qualification, which consumers shouldn't do.)

### The two integration tiers

Both feed from the same collation; only the ergonomic wrapper differs.

- **Tier 1 — minimal.** The user keeps their `buildApplication`, their router,
  their own `.get`/middleware. Wire integration is:
  ```swift
  let graph = try await Wire<TaskClusterModule>.bootstrap()
  let services = WireHummingbird.apply(graph, to: router)   // applies middleware+routes, returns [any Service]
  return Application(router: router, configuration: configuration, services: services, logger: logger)
  ```
  Two touch points, both already idiomatic in a Hummingbird app.
- **Tier 2 — full WireMVC (`@main @WireHummingbird`).** A composition-root type
  whose members the macro reads (spike-2): an `@Inject`ed config value, a
  `routerBuilder()`, an `applicationConfiguration()`. The macro generates `main`:
  bootstrap → `routerBuilder()` → apply collated middleware+routes → construct with
  `applicationConfiguration()` → run. One declaration, no boilerplate.

### Lifecycle: one ordered `[any Service]`

`apply` returns a single `[any Service]` the user hands to `Application(services:)`.
It carries **two** concerns, ordered correctly:

1. **Collected services** — `@Contributes` into a `CollectedKey<any Service>`.
2. **Graph teardown** — the graph's `@Teardown` unwind (M4) modelled as *one
   `Service`* whose `run()` is "await graceful shutdown → run teardowns," placed
   **first** in the array so it unwinds **last**.

Verified against Hummingbird (`Application.swift:148`, `self.services + [dateCache,
serverService]` + reverse-order `ServiceGroup` shutdown): server drains → collected
services stop → graph tears down last. So the graph's lifetime is bracketed by the
app's `ServiceGroup` with no separate handle — Tier 1 needs nothing beyond passing
`services:`. Tier 2's generated `main` passes the same array.

## Scope model: bindings + roots (the M5/WireMVC foundation)

> **Request scope is deferred to M5 (WireMVC), not part of M2.** A request-scoped
> controller needs routing Wire *generates* (see *Request scope is WireMVC-only*
> below), so it can't ride native hand-written Hummingbird controllers. This
> section is the model M5 builds on; M2/WireHummingbird is app-scoped only.

The load-bearing model for request scope. Drop the assumption that *a scope is one
dependency graph*; that's the degenerate case:

> **A scope is a set of bindings + a set of roots. Construction materialises the
> subgraph reachable from the roots being materialised.**

- **App scope** materialises *all* roots at bootstrap — looks like one graph.
- **A seeded (request) scope** materialises *one explicitly-marked root* per
  request — looks like N subgraphs, one per root controller; only the dispatched
  controller's subgraph is built.

### Why per-root, not eager-whole-scope

Request-scoped bindings do real per-request work (a request-derived logger, a
principal from a token, a transaction), and Wire can't stop a binding being
expensive. Materialising the *whole* request scope per request would run every
route's per-request work on every request. Per-root runs only the dispatched
controller's subgraph. One request dispatches to exactly one controller-root, and
middleware populates the Hummingbird **context** (a separate channel), not Wire
request bindings — so no cross-root sharing problem.

### Request scope is WireMVC-only (why native HB can't have it)

A native `@HummingbirdRoute` controller has **hand-written** routing in its
`addRoutes` (`router.group("todos").get(...) { self.list }`, helper calls, nested
closures — todos-dynamodb). Making it request-scoped would mean a macro *parsing*
that body, working out which routes map to which handlers, and *rewriting* each to
wrap per-request scope entry — intractable across the edge cases. So request scope
needs routing Wire **generates**, which is **WireMVC (M5)**, not native
Hummingbird. M2/WireHummingbird native controllers are **app-scoped only**.

When request scope lands in M5, it fits the *same* collation via the
**adapter-replaces-the-binding** shape (also what `@Configuration` needs):

- **App-scoped controller** — the instance *is* the `RouteContributor` (or a small
  generated proxy when its `addRoutes` signature doesn't match; see M2.2). `apply`
  calls `addRoutes(to:)`.
- **Request-scoped controller (M5)** — the binding is replaced by a **proxy
  contributor**: an app-scoped `RouteContributor` whose *generated* `addRoutes`
  embeds the per-request scope entry (spike-8 mechanism B — the opaque per-request
  graph built and consumed *inside* the handler closure). The proxy holds a
  **back-reference to the app graph** (populated post-construction, weakly, via the
  shipped `@Inject weak var` pattern) to build per-request scopes. The graph
  collates the proxy like any other; `apply` calls `addRoutes(to:)` uniformly — no
  separate scoped path, no `_wireRegisterScoped`, no two-sided scope contract.

**The back-reference does double duty:** it's also how a seeded scope receives its
**parent** — `bootstrap<Seed>Scope(seed:, wireGraph:)`'s `wireGraph:` becomes the
proxy's back-ref rather than an argument threaded through the route wrapper. The
graph wires it in during construction. `@HummingbirdRoute`/`@MVCRoute` on the
controller is the explicit per-request root marker (a controller isn't `@Inject`ed
by anything, so reachability can't find it); per-root bootstrap reuses M6b
reachability.

### Request scope ↔ Hummingbird context: layered, not competing

- **Context** = framework/middleware-owned state (`context.identity`, sessions, the
  request logger/id) — populated by Hummingbird's middleware ecosystem.
- **Wire request scope** = app-composed request services derived from the seed (a
  request-tagged logger, a per-request client, a tenant object).

They compose: the seed is built from `(Request, Context)`, so the request scope can
read context-populated values through the seed.

### Prior art — compile-time frameworks especially

Explicit roots + per-scope-instance materialisation is well-trodden compile-time
ground (reassuring: the scoping isn't where Wire takes a risk — the opaque-type
lifting underneath it is).

- **Dagger** (annotation processor) — the canonical model: scopes are generated
  `@Subcomponent`s per entry; roots are explicit provision methods; seeds are
  `@BindsInstance` (our `RequestSeed`). Dagger-on-server pulls the handler from a
  per-request subcomponent — the model we're building.
- **SafeDI** (Swift, macros + build plugin — closest to Wire) — `@Forwarded`
  provides a runtime value into a per-entry subtree, macro-driven. The Swift-native
  compile-time precedent for this shape.
- **Needle** / **Weaver** (Swift codegen) — hierarchical scopes as a tree of
  components; entering a scope instantiates a child.
- **Micronaut** (Java AOT) — the other end: compile-time DI but singleton
  controllers with parameter binding; the exemplar for Hummingbird's own
  "singleton + request state via params" recommendation.

Runtime frameworks (Guice, ASP.NET Core per-request `IServiceScope`, Spring
request-scoped proxies) do the same shape dynamically. None materialises a whole
scope blindly.

**Where Wire differs — eagerness within a materialised scope.** Dagger builds
bindings lazily within a subcomponent (generated `Provider`/`DoubleCheck`); Wire
builds the whole reachable subgraph from the selected root eagerly, with
`Lazy<T>`/`Provider<T>` as the opt-out — its eager-graph philosophy applied
consistently to request scopes.

## Positioning: opt-in, layered over Hummingbird's idiom

Request-scoped controllers diverge from Hummingbird's recommended singleton +
context idiom. The divergence is justified and additive:

- **Opt-in.** A `@Singleton` controller reading the context still works and has zero
  per-request construction cost. The documented default stays singleton + context;
  request-scoped is the deeper-adoption step.
- **WireMVC (M5) is where it lands.** Cross-framework portable controllers can't
  lean on a framework-specific request-state channel, so "a request-scoped binding
  with injected request deps" is the one framework-agnostic model — and since it
  needs generated routing, it's WireMVC's, on the spike-8 + seeded-scope foundation.
- **Matches Wire's audience** (the JVM-DI on-ramp, where request scopes are
  idiomatic).

## Suggested sequencing

See [M2_PLAN.md](../M2_PLAN.md) for the full iteration breakdown. In brief:

1. **Wire Core seam** — the framework-agnostic graph-conformance emission + public
   `Wire<Module>.bootstrap()`.
2. **App-scoped route slice** — `@HummingbirdRoute` → `CollectedKey`, the `apply`
   library (instance-conformance + proxy cases). Replaces task-cluster's manual
   `buildApplication` (Tier 1).
3. **Middleware `BuilderKey` fold**, then **`[any Service]` lifecycle**, then the
   **Tier-2 `@WireHummingbird` macro**, then **`introspect()`**.

**Request scope is M5 (WireMVC)**, not M2 — it needs generated routing.

## Open items to pin

- **The graph-conformance mechanism** (`WireGraphConformanceV1`) — the seam the
  whole model rests on. The *language shape* is proven (spike-10: a graph conforms
  to an externally-declared protocol, `Context` inferred and the opaque middleware
  bound via an associated type, consumed generically). What remains is Wire-side
  implementation: discover the declaration and *emit* the extension, plus **collect
  all contributed conformances to compose the bootstrap return type** (`some (A & B)`).
- **Empty collections** — a middleware `BuilderKey` with zero contributors needs an
  identity/empty case (does `MiddlewareFixedTypeBuilder` support an empty block?);
  a routes `CollectedKey` with none is just no routes.
- **The `(Request, Context) → seed` bridge** (M5) — a WireMVC convention vs a
  user-provided conformance.
- **Adapter-collection consolidation (M5)** — the general form of a question every
  adapter shares, not just WireHummingbird. Each adapter ships **self-contained**:
  its own keys (`HummingbirdRoutesKey`, `OpenAPIHandlersKey`, …), its own
  `WireGraphConformanceV1`, and its own bootstrap-side handling — and they already
  coexist on one graph via the composed `some (A & B)` return (so an app using two
  adapters isn't blocked on either). **WireMVC (M5) is the single place the
  *consolidation* question lives**, because it's the common portable layer that
  *could* subsume the others' collections. For each adapter the choice is the same
  shape: does WireMVC render *into* that adapter's collection (e.g. `@MVCRoute`
  controllers also contribute to `HummingbirdRoutesKey`; a WireMVC target that *is*
  OpenAPI's `ServerTransport` folds `OpenAPIHandlersKey` in) — or sit *side-by-side*
  under distinct conformances? Consolidation is a later **optimisation** the
  composed return already enables, not a prerequisite; the decision is M5's, made
  when WireMVC's rendering target exists to weigh the coupling. The rule this
  session settled: ship each adapter self-contained, keep its contributor shaped
  around the framework-agnostic target it registers on (`some RouterMethods`, `some
  ServerTransport`), so any later fold-in is a re-home, not a rewrite — and don't
  design M5's target from inside M2/M3.

**Decided** (was open): `Wire<Module>.bootstrap()` returns `some (<composed
contributed conformances>)` with the concrete graph fully internal — see *Public
entry* above.

## References

- [spike-9](../../../swift-wire-spikes/spike-9-hummingbird-bootstrap/) — bootstrap shape, collation, `some RouterMethods`, middleware BuilderKey, lifecycle ordering.
- [spike-8](../../../swift-wire-spikes/spike-8-hummingbird-request-scope/) — request-scope entry, mechanism B.
- [WireMVCAbstraction.md](WireMVCAbstraction.md) — Tier-1 vs Tier-2, the three-step adoption progression.
- [OpaqueTypesSupport.md](OpaqueTypesSupport.md) — lifting; the parameterized-opaque `BuilderKey`.
- [BuilderKeyDesign.md](BuilderKeyDesign.md) — the middleware-fold key.
- [AdapterModel.md](AdapterModel.md) — the side-effect `@RoutedBy` contract this adapter no longer uses (still relevant to WireOpenAPI/M3).
