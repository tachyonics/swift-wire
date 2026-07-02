# M2 Implementation Plan — WireHummingbird

The implementation plan for M2: swift-wire's first framework adapter,
`WireHummingbird`. Design is in
[Notes/WireHummingbirdDesign.md](Notes/WireHummingbirdDesign.md); the milestone
sits in [ROADMAP.md](../ROADMAP.md). Iterative, same discipline as
[the archived M1 plan](Archive/M1_PLAN.md): each iteration runs end-to-end and
has a validation gate.

**The headline: the two hardest core pieces already ship.** Opaque-type lifting
(iterations 9–10) and **seeded-scope construction** (iteration 4 —
`_Wire.bootstrap<Seed>Scope(seed:, wireGraph:)`, which builds a `@Scoped` graph
from a seed while aliasing app singletons, exercised by the `RequestLogger`
integration fixture) are both done and tested. Spike-8's hand-written
`requestBootstrap(seed:app:)` *is* that shipped entry. So M2 is largely
**assembly over shipped machinery** — one new core piece (the scope-aware adapter
contract), the `WireHummingbird` package, and the middleware-fold `BuilderKey`.

## How to use this plan

- Each iteration has a *scope*, a *why-now*, and a *validation gate*. Don't move
  on until the gate passes.
- **Highest-risk integration first** (M1's philosophy): the riskiest unproven
  seam is *generated code → a real Hummingbird app that runs*, so M2.1 proves that
  minimally before anything is built on it.
- **Validation vehicle:** a new in-repo `WireHummingbirdHarness` (a consumer
  package that depends on swift-wire + the WireHummingbird adapter, built and run
  in CI — same shape as `CompositionHarness` / `AdapterHarness`). Requests are
  driven in-process via `HummingbirdTesting`'s `app.test(.router)`, as spike-8
  does. Optionally, an adapted example from the local `hummingbird-examples` clone
  for manual end-to-end.
- **Spike anything unproven.** The two load-bearing shapes are already proven —
  spike-8 (request-scope entry at the HB boundary) and spike-7 Proof 2
  (`some P<A,B,C>` lifting for the middleware fold). No new spike is anticipated;
  add one if an iteration surfaces an unknown.
- **Diagnostics continue M1's standard** — new error paths (scope-contract
  violations, unsupported `(Self × collaborator)` scope cells) get good
  diagnostics as they land.

## What M2 rests on (shipped / proven)

- **Controller construction** — lift-the-minimum (iteration 10); the generic
  `Controller<Repository>` idiom is Wire-native. No new work.
- **Seeded-scope construction** — `_Wire.bootstrap<Seed>Scope(seed:, wireGraph:)`
  (iteration 4). The request-scope engine; M2 wires an adapter + framework around it.
- **Adapter contract** — `@RoutedBy`'s `_wireRegister(instance:, router:)`,
  app-scoped, proven by `AdapterHarness` (concrete + full + partial lifting).
- **Multibindings** — `CollectedKey` (iteration 5), for the `[any Service]` list.
- **Request-scope-at-the-HB-boundary shape** — [spike-8](../../swift-wire-spikes/spike-8-hummingbird-request-scope/)
  (mechanism B).
- **Parameterized-opaque lifting** — [spike-7](../../swift-wire-spikes/spike-7-iteration-10-lifting/)
  Proof 2 (`some P<A,B,C>`), for the middleware fold.

## Scope boundary

`WireHummingbird` targets **native Hummingbird controllers** (`@HummingbirdRoutes`,
`addRoutes(to:)`). task-cluster uses the **OpenAPI** generator
(`registerHandlers(on:)`) — auto-wiring that is `@RoutedBy` for `APIProtocol`,
which is **M3 (WireOpenAPI)**. M2's composition-root, service-lifecycle, request-
scope, and middleware machinery is what M3 reuses. So M2's validation vehicle is
a native-HB harness, not task-cluster directly — though M2 can already automate
task-cluster's non-OpenAPI app assembly (router, middleware, `Application`,
services), leaving `registerHandlers` manual until M3.

## Iteration M2.1 — WireHummingbird skeleton + app-scoped composition root

Highest-risk integration: generated code driving a real Hummingbird app.

**Scope:**
- New `WireHummingbird` adapter package (the member macro + Wire-facing adapter
  definition, mirroring `AdapterHarness/Adapter`'s `WireRouting`).
- `@HummingbirdRoutes(at:)` annotation, **app-scoped only** — a route-registration
  adapter (type-level) over the existing contract (`_wireRegister(instance:,
  router:)`). Walk annotated `@Singleton` controllers, construct from the graph,
  open the route group, call `addRoutes(to:)`.
- **Composition-root codegen:** generate the `buildApplication` equivalent —
  create the `Router`, register app-scoped controllers, construct `Application`.
- The generated bootstrap consumes `_Wire.bootstrap()` (the app graph) as today.

**Why now:** proves the codegen → real-Hummingbird seam end-to-end, and is the
foundation every later iteration builds on. Uses only shipped machinery
(app scope + the app-scoped adapter contract).

**Validation gate:** `WireHummingbirdHarness` — an app with one app-scoped
`@HummingbirdRoutes` controller holding an `@Inject`ed service; the generated
`buildApplication` builds the router; a request driven via `app.test(.router)`
resolves through the controller and returns the expected body.

## Iteration M2.2 — service lifecycle (`CollectedKey` → `ServiceGroup`)

**Scope:**
- Collect `@Contributes` services into a `CollectedKey<any Service>`.
- Generate the `ServiceGroup` wiring: services in dependency (topological) order,
  the `Application` itself as a `Service`, `gracefulShutdownSignals`, `run()`.
- The composition root returns/runs the `ServiceGroup` rather than a bare
  `Application`.

**Why now:** it's the first concrete consumer of `CollectedKey` (the M2 forcing
case), and every non-trivial HB app needs ordered startup/shutdown of a DB
client / connection pool alongside the server.

**Validation gate:** harness app with a fake service (a type conforming to
`Service` that records start/stop) plus the app; the generated `ServiceGroup`
starts services before the server and shuts them down in reverse order.

**Note:** startup = topological order, shutdown = reverse — the same ordering
`@Teardown` will use (M4). `@Teardown` *emission* is M4; here the ordering just
aligns.

## Iteration M2.3 — scope-aware adapter contract + request-scoped controllers

The one genuinely new core piece. De-risked by spike-8.

**Scope:**
- **Core:** extend the adapter contract to the two-sided scope declaration —
  `selfScopes` (scopes the annotated binding may occupy) and `collaboratorScopes`
  (scopes the collaborator it registers with may occupy). Wire validates the
  actual `(Self × collaborator)` pair against the declared sets and the
  containment rule (collaborator outlives `Self`), and selects the registration
  mode: `_wireRegister(instance:)` when same-scope, `_wireRegisterScoped(…)` when
  `Self` is narrower. Impossible cells become adapter-contract diagnostics.
- `@HummingbirdRoutes` on a `@Scoped(seed:)` controller → marks it a **root** of
  the seeded scope; the generated route wrapper builds the seed from
  `(Request, Context)`, calls the shipped `_Wire.bootstrap<Seed>Scope(seed:,
  wireGraph:)`, reads the controller off it, and dispatches. (Opacity-clean: the
  controller is a local inside the closure.)
- The `(Request, Context) → seed` bridge — a WireHummingbird convention (or a
  user-provided conformance).

**Why now:** it's the request-scoped-observability forcing case for M2, and the
foundation WireMVC (M5) requires. The scope engine already exists; this is the
adapter integration on top of it.

**Validation gate:** harness app with a `@Scoped(seed:)` controller injecting a
request-scoped service (RequestLogger-style, tagged from the seed) **and** an app
singleton; per-request construction; a request returns both values — spike-8's
assertions, now generated end-to-end through real Hummingbird.

**Note:** M2.3 reuses the shipped single *whole-scope* seeded bootstrap
unchanged — every request builds the entire scope and the controller is read off
it. Per-root pruning is M2.3b.

## Iteration M2.3b — per-root request materialisation (refinement)

**Scope:** the shipped seeded-scope construction builds *one whole* scope graph.
Here we **emit N pruned copies of it — one per root** — each pruned by
reachability from its root controller to the subgraph that root actually needs,
replacing the single whole-scope bootstrap. It's the same reachability analysis
M6b uses, but applied *per root within the scope* (N prunings) rather than once to
the whole app graph. Shared `@Scoped` bindings appear in each pruned copy that
reaches them (codegen duplication, not runtime — one request hits one root).

**Why now (or defer):** with the whole-scope bootstrap, every request builds
*all* request-scoped bindings, so every route's per-request work (a token load, a
remote fetch) runs on every request regardless of route — a correctness/cost
issue once there are multiple request-scoped controllers. If M2's harness stays
single-controller, this can slip to post-M2; flag it the moment a second
request-scoped controller lands.

**Validation gate:** multi-controller harness; a request-scoped binding with an
observable effect is constructed only for the route that reaches it.

## Iteration M2.4 — middleware fold (parameterized-opaque `BuilderKey`)

The largest remaining core chunk.

**Scope:**
- The deferred **parameterized-opaque `BuilderKey`**: `some P<A,B,C>` lifting
  (shape proven by spike-7 Proof 2) + the `.opaque(P<…>.self)` fold form (see
  [Notes/BuilderKeyDesign.md](Notes/BuilderKeyDesign.md),
  [Notes/OpaqueTypesSupport.md](Notes/OpaqueTypesSupport.md) *Deferred to M2*).
- Middleware are app-scoped bindings with injected deps
  (`SessionMiddleware(storage:)`, an authenticator holding a key collection). The
  fold assembles the stack from the graph and feeds `router.addMiddleware`.

**Why now:** task-cluster's `addMiddleware { … }` and the auth examples'
DI-holding middleware are the concrete consumers; it's the last piece to make a
generated `buildApplication` a full replacement for a hand-written one.

**Validation gate:** harness app with two middleware, one holding an injected
dependency; the generated fold runs them in order and each receives its deps.

## Iteration M2.5 — runtime introspection (`introspect()` + `/admin/wiring`)

**Scope:** a runtime view of the graph structure (bindings, dependency edges) —
the `Resolver.introspect()` API the README's M2 entry names, plus an
`/admin/wiring` example endpoint. Read-only; not dynamic resolution (which stays
[rejected](Archive/M1_PLAN.md#design-decisions-settled-during-m1)).

**Validation gate:** the harness's `/admin/wiring` endpoint returns the wiring view.

## Stretch / adjacent (not core M2)

- **`@WebSocketRoute`** — a per-connection scope is a natural second scope-root
  example (a websocket connection is a scope); good exercise of the scope-aware
  contract beyond HTTP. The README names it M2's first adapter annotation.
- **WireVapor** — a second adapter validates the contract generalises across
  frameworks (the README pairs it with WireHummingbird in M2); can follow once
  the contract is shaken out on Hummingbird.
- **Adapted `hummingbird-examples`** — port a todos-style native-HB example onto
  WireHummingbird for a real-world end-to-end, beyond the harness.

## Cross-cutting concerns

- **Fold the scope-aware contract into `Notes/AdapterModel.md`** once M2.3 lands —
  it generalises that note's single-shape contract.
- **task-cluster** stays the downstream validator against pushed swift-wire main
  (`swift package update swift-wire`); its OpenAPI controller migrates in M3, but
  its app-assembly can adopt M2 machinery earlier.
- **Two scope levels only** — `_wireRegisterScoped` is emitted at the app scope
  (the collaborator's scope). Nested scopes (`@Scoped(within:)`) generalise this
  to "the nearest common enclosing scope" but are deferred (see ROADMAP).

## Open decisions to pin (from the design note)

- `_wireRegisterScoped` generation home: the controller macro (references the
  public scope entry) vs the plugin's route-assembly codegen. Leaning macro for
  scope-declared-on-the-type; plugin is the fallback for enclosing-context scope.
- Per-root bootstrap surface: the single shipped whole-scope
  `_Wire.bootstrap<Seed>Scope` (M2.3) vs N reachability-pruned per-root bootstraps
  (M2.3b) — and, for the latter, whether they're distinct entries
  (`_Wire.make<Controller>(seed:)`) or one entry parameterised by root.
- The `(Request, Context) → seed` bridge: WireHummingbird convention vs
  user-provided conformance.

## When M2 is "done"

- `WireHummingbird` ships: native HB controllers auto-wired (app-scoped and
  request-scoped), service lifecycle via `ServiceGroup`, middleware fold, and
  `introspect()`.
- The `WireHummingbirdHarness` gate passes on macOS and Linux (added to CI
  alongside the existing harness gates).
- The scope-aware contract is documented in `AdapterModel.md`.
- Sets up M3: WireOpenAPI reuses this machinery for task-cluster's
  `registerHandlers`.
- No public 0.x tag yet — pre-alpha stays loud.
