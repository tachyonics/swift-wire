# M2 Implementation Plan — WireHummingbird

The implementation plan for M2: swift-wire's first framework adapter,
`WireHummingbird`. Design is in
[Notes/WireHummingbirdDesign.md](Notes/WireHummingbirdDesign.md); the milestone
sits in [ROADMAP.md](../ROADMAP.md). Iterative, same discipline as
[the archived M1 plan](Archive/M1_PLAN.md): each iteration runs end-to-end and
has a validation gate.

**The headline:** M2 is **app-scoped** WireHummingbird — native Hummingbird
controllers auto-wired onto a `Router` that stays *outside* the graph. The model
(settled across spikes 8–10) is **collation, not registration**: the graph
collates route contributors + a service list; a facade applies
them to a user-built router and assembles the `Application`. The two hardest core
pieces already ship (opaque lifting, iterations 9–10; multibindings, iteration 5),
so the new core work is two small *framework-agnostic* capabilities — **emit a
graph conformance to an adapter-declared protocol** (M2.1, done) and the
**contribution-attribute + binding-rewrite adapter contract** (M2.3, replacing the
iteration-8 `_wireRegister` model) — plus the external `WireHummingbird` package on
top.

**Request scope is deferred to M5 (WireMVC).** A request-scoped controller needs
routing Wire *controls* (to embed per-request scope entry), which means
*generated* routing — WireMVC, not native hand-written Hummingbird controllers.
So M2 carries no request-scope machinery; spike-8, seeded-scope construction, and
per-root materialisation are the **foundation M5 builds on**, not M2 work. See
*Deferred to M5*.

## How to use this plan

- Each iteration has a *scope*, a *why-now*, and a *validation gate*. Don't move
  on until the gate passes.
- **Highest-risk first** (M1's philosophy): the riskiest core seam was the
  **graph-conformance emission** (M2.1) — now **shipped and validated end-to-end**
  (shape proven by spike-10, codegen built, exercised in `wire-hummingbird`).
  Everything else layers on it. It brought the internal `Wire` adapter entry (the
  `_Wire`→`Wire` rename; the member-access surface is untouched; see M2.1).
- **Validation vehicle:** WireHummingbird is an **external repo** depending on
  *pushed* swift-wire main (the task-cluster pattern — see
  [[feedback_adapters_are_external_repos]]), with its own Hummingbird example that
  drives requests in-process via `HummingbirdTesting`'s `app.test(.router)`. This
  keeps the adapter *product* out of swift-wire's own tests: the framework-agnostic
  core is validated *in* swift-wire (M2.1's conformance emission is exercised
  framework-free in `Tests/IntegrationTests`), and the Hummingbird-specific
  integration lives in the adapter repo. Any new core capability a later iteration
  needs (M2.3's contribution contract) lands in swift-wire, gets pushed, then the
  adapter repo picks it up.
- **Spikes 8–10 proved the load-bearing shapes** (request-scope entry; bootstrap
  collation + `some RouterMethods`; graph-conformance with associated-type
  inference). No new shape spike is anticipated for M2; add one if an iteration
  surfaces an unknown.
- **Diagnostics continue M1's standard** — new error paths get good diagnostics.

## What M2 rests on (shipped / proven)

- **Controller construction** — lift-the-minimum (iteration 10); the generic
  `Controller<Repository>` idiom is Wire-native. No new work.
- **Multibindings** — `CollectedKey` (iteration 5) for routes + the `[any Service]`
  list. (`BuilderKey` for value folds exists but is unused in M2 — middleware, its
  intended use, is out of scope; see M2.4.)
- **Bootstrap collation shape** — [spike-9](../../swift-wire-spikes/spike-9-hummingbird-bootstrap/):
  Router outside the graph; routes as `[any RouteContributor]` (context-free); middleware
  folded via `MiddlewareFixedTypeBuilder`; `some RouterMethods<Context>`; the
  `[any Service]` lifecycle ordering.
- **Graph-conformance shape** — [spike-10](../../swift-wire-spikes/spike-10-graph-conformance/):
  a graph conforming to an externally-declared protocol, `Context` inferred and the
  opaque middleware bound via an associated type, consumed generically.
- **Parameterized-opaque lifting** — [spike-7](../../swift-wire-spikes/spike-7-iteration-10-lifting/)
  Proof 2 (`some P<A,B,C>`), underneath the middleware `BuilderKey`.

## Scope boundary

`WireHummingbird` targets **native Hummingbird controllers** (`@HummingbirdRoute`,
hand-written `addRoutes(to:)`), **app-scoped only**. Three things are out:

- **OpenAPI `registerHandlers(on:)`** (task-cluster's generator) → **M3
  (WireOpenAPI)**. M2's collation and lifecycle machinery is what M3
  reuses; M2 can already automate task-cluster's non-OpenAPI app assembly.
- **Request-scoped controllers** → **M5 (WireMVC)** — they need generated routing
  (see *Deferred to M5*).
- **Fully-abstracted / portable routes** → **M5 (WireMVC)**.

## The model in one paragraph

A controller is a **route contributor**: it conforms to `RouteContributor` and is
`@Contributes`'d to `HummingbirdRoutesKey` (a `CollectedKey`). In M2.2 that's
written raw (`@Singleton @Contributes(to:) …`) with the conformance the
`@HummingbirdRoute("path")` **macro** generates — an extension owning the mount and
delegating to the controller's `addRoutes`, **no proxy type**. (An optional M2.3
lets `@HummingbirdRoute` also alias `@Contributes` so the developer drops that
annotation; scope stays explicit via `@Singleton`.) Middleware is **out of scope**
(M2.4) — a context-typed value with no clean collation shape; the app owns the
`Router` and calls `router.addMiddleware` itself. WireHummingbird declares a
`WireGraphConformanceV1` mapping the routes key (plus the M2.5 services key) onto a
`HummingbirdComposable` protocol; **Wire emits `extension _WireGraph:
HummingbirdComposable`, knowing nothing about HTTP**. `Wire.bootstrap()` returns
the concrete graph, which *conforms* to `HummingbirdComposable`; the user passes it
to a facade `apply(graph, to: router)` (generic over the conformance) that applies
the collated routes to a user-owned router and returns `[any Service]`
(M2.5). The user (Tier 1) or a generated `main` (Tier 2) constructs the
`Application`.

## Iteration M2.1 — Wire Core: `Wire` entry + graph-conformance emission (shipped)

The one new core piece (conformance emission), plus a developer-facing rename. Both
**internal** and **framework-agnostic** — no Hummingbird knowledge.

> **Access vs. hiding vs. naming — three separate decisions, settled:**
> - **Access:** `bootstrap()` is called only intra-module (the user's composition
>   root; the Tier-2 macro's generated `main`), never by the adapter *library* — it
>   consumes the graph through a generic `apply<G: Composable>` the user passes into.
>   So the entry is **internal**, not public.
> - **Hiding:** `bootstrap()` returns the **concrete `_WireGraph`** (no opaque
>   view). Member access (`graph.logger`) stays, the concrete graph *conforms* to
>   the adapter protocols so it feeds `apply` too, and it leaves the graph open for
>   whatever else the developer wants. (Hiding would need a root/internal split +
>   `@testable` tests, and is emptiest exactly in the no-adapter case.)
> - **Naming:** the developer calls this, so it shouldn't wear the generated `_`
>   signal — rename `_Wire` → `Wire` (a plain **internal `enum Wire`**). Verified: a
>   local `enum Wire` coexists with `import Wire` without clashing, and since the
>   entry is internal there's nothing to disambiguate across modules — so **no
>   `Wire<Module>` generic, marker, or extension is needed** (the generic form was
>   only ever for public cross-module disambiguation, which is moot here).

**Scope:** *(rename done)*
- **`_Wire` → `Wire` rename** — the façade is a plain `internal enum Wire { static
  func bootstrap() … }` (+ container/scope variants) returning the concrete
  `_WireGraph`. A one-word emission change; `_wireBootstrap()`/`_WireGraph`
  unchanged. Migration was `_Wire.` → `Wire.` across goldens, integration tests,
  and harness consumers — no library type, no marker, no `import Wire`. task-cluster
  updates when it picks up the change (its `_Wire.bootstrap()` → `Wire.bootstrap()`).
- **Graph-conformance emission** — the public `WireGraphConformanceV1` declaration
  type (a protocol + members-to-keys mapping) + syntactic discovery; emit
  `extension _WireGraph: <Protocol> { … }` mapping each declared key's product to
  its member (`CollectedKey` → array member; `BuilderKey` → opaque member bound to
  a protocol associated type), inferring any associated types from the witnesses.
  The `CollectedKey` → array case is **shipped and validated** (WireHummingbird's
  context-free surface uses exactly it: `var routes: [any RouteContributor]`);
  associated-type inference is proven (spike-10 / IntegrationTests) and is what a
  context-*carrying* adapter surface would use. No composed opaque return needed —
  the concrete graph conforms to every declared protocol, and each adapter's generic
  `apply` picks the one it needs.

**Why now:** the conformance emission is the seam the whole model rests on,
framework-agnostic (testable in isolation), and reusable (M3/M5 surface the same
way). The rename is bundled because both touch the same generated file + goldens.

**Validation gate:** full suite + all harness gates + task-cluster green on the
`Wire` surface; plus a *framework-free* conformance check — a consumer
declares a protocol, a `CollectedKey`, and a `WireGraphConformanceV1`, the generated
graph conforms, and a generic function consumes it through the conformance while
same-module code still reads members. (spike-10 proved the conformance compiles.)

## Iteration M2.2 — WireHummingbird context-free route slice (+ `@HummingbirdRoute` macro)

First generated-code → real-Hummingbird proof. Built as an **external repo**
(`wire-hummingbird`, see *Validation vehicle*).

**Scope:**
- WireHummingbird library: a **context-free** `RouteContributor` (witness
  `addWireRoutes<Context: RequestContext>(to: some RouterMethods<Context>)`),
  `HummingbirdComposable` (no associated type), `HummingbirdKeys.routes =
  CollectedKey<any RouteContributor>`, the `WireGraphConformanceV1` declaration, and
  `apply<Context>(_ graph: some HummingbirdComposable, to router: some RouterMethods<Context>)`
  (routes only; middleware is out of scope, see M2.4). No `Context` on the surface — the app's context
  binds at `apply`.
- **Step one (done):** controllers with raw `@Singleton @Contributes(to:
  HummingbirdKeys.routes)` + a hand-written conformance extension; the natural
  `addRoutes(to: some RouterMethods<some RequestContext>)` is untouched, and the
  conformance's `addWireRoutes` owns the mount (`router.group("path")`) and delegates.
- **Step two:** the `@HummingbirdRoute("path")` **extension macro** generates that
  conformance (no separate proxy type — the controller is stateless-to-conform and
  in-module). No-arg form → root mount (`addRoutes(to: router)`). It can't add
  `@Singleton`/`@Contributes` (attributes on the type), so those stay explicit (M2.3).

**Why now:** proves the codegen → real-Hummingbird seam (bootstrap → conformance →
apply → served request) using only M2.1 core, on the shape the examples actually use.

**Validation gate:** the `wire-hummingbird` repo's Hummingbird example — a
`@Singleton @Contributes` controller with an `@Inject`ed service and a self-grouping
conformance; `Wire.bootstrap()` → `WireHummingbird.apply(graph, to: router)` →
`Application`; a request via `app.test(.router)` resolves through it. (Step one is
green against pushed main; step two swaps the hand-written conformance for the macro.)

## Iteration M2.3 — *optional*: fold `@Contributes` into `@HummingbirdRoute`

Small, deferrable ergonomic. **No proxy / binding-rewrite** — that concept is
dropped: it only existed to defer-instantiate a type-generic controller, which the
context-free surface removes, and signature adaptation is the M2.2 conformance macro,
not a separate type.

**Scope:**
- Evolve `WireAdapterAnnotationV1` from the `_wireRegister` side-effect to a *scoped
  contribution*: an adapter declares that its annotation **aliases `@Contributes(to:
  key)`** (plus `contributableScopes`). The plugin then reads `@HummingbirdRoute`
  generically as a contribution, so the developer writes `@Singleton
  @HummingbirdRoute("path")` instead of *also* writing `@Contributes` — scope stays
  explicit. `registerSignature`/`_wireRegister` and their emission
  (`AdapterResolution`) retire; the AdapterHarness `@RoutedBy` fixture is rewritten
  or retired.

**Why (and why optional):** it removes one annotation, nothing more — routes already
collate via raw `@Contributes` from M2.2. Deferrable behind middleware/lifecycle.

**Note:** the *request-scope* case (a `@Scoped` controller entering a per-request
scope) is **M5/WireMVC** via the adapter-replaces-the-binding proxy — a distinct,
request-scope mechanism, not this app-scoped contribution-attribute.

## Iteration M2.4 — middleware: *out of scope for Tier 1*

Middleware collation is **dropped from M2** (like the M2.3 proxy). Zero
regression: the app owns the `Router` and still calls `router.addMiddleware { … }`
itself; wire-hummingbird simply doesn't claim middleware.

**Why it doesn't fit the collation model** — the deciding factor is *callable vs
value*:
- **Routes are callables.** `apply` *invokes* a contributor's `addRoutes`, so the
  context defers to the call site (a generic method absorbs it) — the contributor
  is a provider shape, the routes it registers are the runtime interest.
- **Middleware are values.** A middleware *is* the runtime object in the pipeline,
  and it's `RouterMiddleware<Context>` — a context-*typed* value. There's no call to
  defer the context to; the type is baked in. A `MiddlewareContributor` wrapper
  whose only job is `router.add(middleware: theRealThing)` is a hack in the wrong
  shape, and the `BuilderKey` fold (`MiddlewareFixedTypeBuilder<…, Context>`) pins a
  concrete `Context` — reintroducing exactly the pinning routes removed. Making the
  graph "define the context type" (a provider returning `MyContext.self`) is a type
  masquerading as a value — it doesn't fit Wire's value-DI model.

Contrast **services** (M2.5), which *are* values but **context-free** (`any Service`
has no context parameter), so they collate cleanly. Middleware is specifically a
*context-typed value*, and there's no clean shape for it here.

**Future (WireMVC/M5, deferred):** the standard proposed
[`Middleware`](https://github.com/apple/swift-http-api-proposal/blob/main/Sources/Middleware/Middleware.swift)
is parameterised by `Input`/`Output` only (no framework context), so it *is*
collatable in principle — WireMVC owning an aggregation key, wire-hummingbird
declaring the concrete type. But applying that stack means the router must
understand that middleware type rather than Hummingbird's `RouterMiddleware<Context>`,
which likely needs a custom router/transport — a big lift, gated on ecosystem
convergence. Not designed from inside M2.

## Iteration M2.5 — service lifecycle (`[any Service]` incl. graph teardown)

**Scope:**
- Collect `@Contributes` services into `CollectedKey<any Service>`.
- Synthesise the **graph-teardown Service** — one `Service` whose `run()` awaits
  graceful shutdown then runs the `@Teardown` unwind — and place it **first** in
  the returned array so it shuts down **last**.
- `apply` returns the ordered `[any Service]`; the user hands it to
  `Application(services:)`.

**Why now:** every non-trivial HB app needs ordered startup/shutdown of a
DB client / pool alongside the server, and the graph's own `@Teardown` unwind has
to bracket the app's lifetime.

**Validation gate:** harness app with a fake `Service` (records start/stop) **and**
a `@Teardown` binding; passing `services:` into `Application`, the shutdown order
is server → services → graph-teardown (verified against Hummingbird's `services +
[dateCache, serverService]` reverse-order group, per spike-9).

**Note:** `@Teardown` *emission* is M4; here the ordering aligns and the
graph-teardown-as-`Service` wrapper is the M2 piece.

## Iteration M2.6 — Tier-2 composition-root macro: *deferred to M5.2*

The `@main @WireHummingbird` macro is **moved to the second half of M5**. It codifies
the composition-root assembly (`bootstrap → routerBuilder → apply → Application →
run`) — exactly the shape WireMVC is most likely to perturb: if native middleware
returns via a custom router/transport (the likely M5 path) or request-scoped routing
changes how the router is built, the generated `main` changes with it. It's **pure
sugar over a working Tier-1** (the two-call `bootstrap()` + `apply()` path ships in
M2.2–M2.5), so deferring costs no capability and avoids codifying a shape we'd rewrite.

**Gate to un-defer:** WireMVC's shape is known *and* a router PoC has proven the
native-middleware assembly. Build it once, against the settled shape.

## Iteration M2.7 — runtime introspection

Split along the framework boundary — the model is framework-agnostic, the endpoint is
WireHummingbird's.

**Core — `introspect()` → a wiring model.** A read-only, framework-agnostic view of the
graph (bindings, dependency edges, scopes) — the `introspect()` API the README's M2
entry names. Any adapter or app gets the model and can serve, log, or diff it. Not
dynamic resolution (stays [rejected](Archive/M1_PLAN.md#design-decisions-settled-during-m1)).

**WireHummingbird — a mountable introspection endpoint.** A convenience *over*
`introspect()` that the app **mounts where it wants**, so it can put it behind its own
auth — the endpoint exposes the DI graph, so it is *not* a bare flag on `apply` (which
stays routes + services, a consistent surface). Shape:
`WireHummingbird.mountIntrospection(for: graph, on: router.group("admin"))`.

**Validation gate:** Core — `introspect()` returns the wiring model for a small graph,
unit-tested framework-free in `Tests/IntegrationTests`. WireHummingbird — the harness
mounts the endpoint on an authed group and it returns the wiring view.

## Deferred to M5 (WireMVC) — with M2/prior work as its foundation

Request scope leaves M2 entirely, because it needs routing Wire generates:

- **Request-scoped controllers** are **WireMVC-only.** A native controller's
  `addRoutes` is arbitrary hand-written routing; embedding per-request scope entry
  would mean parsing and rewriting that body — intractable. WireMVC *generates* the
  routing, so it can embed the scope entry cleanly.
- **The mechanism** (the design's *only* proxy — request-scope, not the dropped
  app-scoped one): a `@Scoped` controller becomes an app-scoped **proxy contributor**
  whose *generated* `addRoutes` embeds the scope entry, holding a **weak
  back-reference to the app graph** (the shipped `@Inject weak var` pattern) to build
  per-request scopes. Collated and applied like any contributor — no separate scoped
  path.
- **The back-reference does double duty:** it's also how a seeded scope receives
  its **parent** — `bootstrap<Seed>Scope(seed:, wireGraph:)`'s `wireGraph:` becomes
  the proxy's back-ref rather than an argument threaded through a route wrapper. The
  graph wires it in.
- **"Adapter replaces the binding" is a shared Wire primitive** (the same shape
  `@Configuration` needs — replace `let port: Int` with a config-reading provider),
  built here in M5 and reused rather than reinvented per adapter.
- **Foundation carried forward, not discarded:** [spike-8](../../swift-wire-spikes/spike-8-hummingbird-request-scope/)
  (request-scope entry, mechanism B), seeded-scope construction
  (`bootstrap<Seed>Scope`, iteration 4), and per-root reachability materialisation
  are exactly M5's engine.

## Stretch / adjacent (not core M2)

- **WireVapor** — a second adapter validates the graph-conformance + collation model
  generalises across frameworks; can follow once WireHummingbird is shaken out.
- **Adapted `hummingbird-examples`** — port a todos-style native-HB example onto
  WireHummingbird for a real-world end-to-end, beyond the harness.

## Cross-cutting concerns

- **task-cluster** stays the downstream validator against pushed swift-wire main
  (`swift package update swift-wire`); its OpenAPI controller migrates in M3, but
  its app-assembly (router, middleware, `Application`, services) can adopt M2
  machinery earlier.
- **`AdapterModel.md`** documents the **contribution-alias** adapter contract
  (rewritten in M2.3 — an annotation aliases `@Contributes(to: key)`); the
  `_wireRegister` side-effect model it described is retired. WireHummingbird's
  collation/conformance model is in the design note.

## Open decisions to pin

- **`WireMVCAbstraction.md` collation-pivot rewrite** (M5 doc debt) — it's built on
  the retired `_wireRegister` mechanism (a `_wireRegister<S: WireMVCServer>` section)
  and predates the collation / `ServerTransport` pivot. Rewrite it around the
  collation model (contribution aliases, `ServerTransport`, request-scoped injection)
  when M5/WireMVC design starts. Incidental `_wireRegister` mentions in
  `ScopeAndKeyModelEvolution.md`, `OpaqueTypesSupport.md`, `VisibilityModel.md` are
  minor and can be swept alongside.
- **BuilderKey conformance member** — *deferred with middleware*. The recon confirmed
  the shipped emission already handles a `BuilderKey`→opaque member (`var x: some P
  { self.prop }`) with no Core change, but there's no M2 consumer now that middleware
  is out of scope. WireMVC's standard-`Middleware` aggregation (M5) would exercise and
  validate it.

**Decided** (were open): the graph conformance is **shipped** (M2.1); the entry is
internal `Wire.bootstrap()` returning the **concrete** graph (no `Wire<Module>`, no
composed `some (A & B)`); the route surface is **context-free**; signature adaptation
is a **conformance-extension macro**, not a proxy; the `@HummingbirdRoute` macro +
`@Contributes` alias are **shipped** (M2.2/M2.3 payoff); **middleware is out of scope**
for M2 (M2.4 — a context-typed value with no clean collation shape; app-owned).

## When M2 is "done"

- `WireHummingbird` ships: native app-scoped HB controllers auto-wired (routes via
  `@HummingbirdRoute`), service lifecycle via `@HummingbirdService` → `[any Service]`,
  and a mountable `introspect()` endpoint. (Middleware is app-owned/out of scope; the
  Tier-2 `@WireHummingbird` macro is deferred to M5.2 — see M2.4/M2.6.)
- Wire Core gains the framework-agnostic graph-conformance capability, the
  contribution-alias adapter contract (`_wireRegister` retired), the framework-agnostic
  `introspect()` wiring model, and the `Wire.bootstrap()` façade.
- The external **WireHummingbird repo** builds + serves against pushed swift-wire
  main on macOS and Linux (its own CI).
- Sets up M3 (WireOpenAPI reuses the machinery for `registerHandlers`) and M5
  (WireMVC reuses it + the deferred request-scope foundation).
- No public 0.x tag yet — pre-alpha stays loud.
