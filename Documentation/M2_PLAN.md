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
collates route contributors + a middleware fold + a service list; a facade applies
them to a user-built router and assembles the `Application`. The two hardest core
pieces already ship (opaque lifting, iterations 9–10; multibindings, iteration 5),
so the one genuinely new core piece is a small, *framework-agnostic* capability —
**emit a graph conformance to an adapter-declared protocol** — plus the
`WireHummingbird` package (macros + a library) on top.

**Request scope is deferred to M5 (WireMVC).** A request-scoped controller needs
routing Wire *controls* (to embed per-request scope entry), which means
*generated* routing — WireMVC, not native hand-written Hummingbird controllers.
So M2 carries no request-scope machinery; spike-8, seeded-scope construction, and
per-root materialisation are the **foundation M5 builds on**, not M2 work. See
*Deferred to M5*.

## How to use this plan

- Each iteration has a *scope*, a *why-now*, and a *validation gate*. Don't move
  on until the gate passes.
- **Highest-risk first** (M1's philosophy): the riskiest unproven core seam is the
  **graph-conformance emission** (M2.1) — the shape is proven (spike-10) but the
  plugin codegen isn't built. Everything else layers on it. It brings the public
  `Wire<Module>` adapter entry with it (no separate rename step — the internal
  member-access surface is left untouched; see M2.1).
- **Validation vehicle:** a new in-repo `WireHummingbirdHarness` (a consumer
  package depending on swift-wire + the WireHummingbird adapter, built and run in
  CI — same shape as `CompositionHarness` / `AdapterHarness`). Requests drive
  in-process via `HummingbirdTesting`'s `app.test(.router)`, as spikes 8–10 do.
  M2.1's framework-agnostic seam gets a *framework-free* conformance harness first.
- **Spikes 8–10 proved the load-bearing shapes** (request-scope entry; bootstrap
  collation + `some RouterMethods`; graph-conformance with associated-type
  inference). No new shape spike is anticipated for M2; add one if an iteration
  surfaces an unknown.
- **Diagnostics continue M1's standard** — new error paths get good diagnostics.

## What M2 rests on (shipped / proven)

- **Controller construction** — lift-the-minimum (iteration 10); the generic
  `Controller<Repository>` idiom is Wire-native. No new work.
- **Multibindings** — `CollectedKey` (iteration 5) for routes + the `[any Service]`
  list; `BuilderKey` for the middleware fold.
- **Bootstrap collation shape** — [spike-9](../../swift-wire-spikes/spike-9-hummingbird-bootstrap/):
  Router outside the graph; routes as `[any RouteContributor<Context>]`; middleware
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
  (WireOpenAPI)**. M2's collation, lifecycle, and middleware machinery is what M3
  reuses; M2 can already automate task-cluster's non-OpenAPI app assembly.
- **Request-scoped controllers** → **M5 (WireMVC)** — they need generated routing
  (see *Deferred to M5*).
- **Fully-abstracted / portable routes** → **M5 (WireMVC)**.

## The model in one paragraph

`@HummingbirdRoute` on a controller is a plain macro → `@Singleton @Contributes(to:
HummingbirdRoutesKey)`, making the controller a **route contributor** (either the
instance conforms to `RouteContributor` directly, or a generated proxy does — see
M2.2). `@HummingbirdMiddleware` → `@Contributes(to: HummingbirdMiddlewareKey)`, a
`BuilderKey` folding via `MiddlewareFixedTypeBuilder` into one `some
MiddlewareProtocol`. WireHummingbird declares a `WireGraphConformanceV1` mapping
those keys onto a `HummingbirdComposable` protocol; **Wire emits the conformance,
knowing nothing about HTTP**. `Wire<Module>.bootstrap()` returns `some (<composed
conformances>)`. A facade `apply(graph, to: router)` applies the collated
middleware + routes to a user-owned `some RouterMethods` and returns `[any
Service]`; the user (Tier 1) or a generated `main` (Tier 2) constructs the
`Application`.

## Iteration M2.1 — Wire Core: `Wire<Module>` entry + graph-conformance emission

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
  a protocol associated type), inferring associated types from the witnesses (e.g.
  `Context` from a `CollectedKey<any RouteContributor<Context>>` element type). No
  composed opaque return needed — the concrete graph conforms to every declared
  protocol, and each adapter's generic `apply` picks the one it needs.

**Why now:** the conformance emission is the seam the whole model rests on,
framework-agnostic (testable in isolation), and reusable (M3/M5 surface the same
way). The rename is bundled because both touch the same generated file + goldens.

**Validation gate:** full suite + all harness gates + task-cluster green on the
`Wire<Module>` surface; plus a *framework-free* conformance check — a consumer
declares a protocol, a `CollectedKey`, and a `WireGraphConformanceV1`, the generated
graph conforms, and a generic function consumes it through the conformance while
same-module code still reads members. (spike-10 proved the conformance compiles.)

## Iteration M2.2 — WireHummingbird app-scoped route slice

First generated-code → real-Hummingbird proof.

**Scope:**
- New `WireHummingbird` package: the `HummingbirdComposable` protocol, the
  `RouteContributor` protocol, `HummingbirdRoutesKey = CollectedKey<…>`, the
  `WireGraphConformanceV1` declaration, and the `apply` library (routes only for
  now; middleware in M2.3).
- `@HummingbirdRoute` macro → `@Singleton @Contributes(to: HummingbirdRoutesKey)`.
  It makes the controller a `RouteContributor`, covering **both** cases:
  - **Instance is the contributor (conformance).** When the controller's
    `addRoutes(to:)` already matches the `RouteContributor` requirement (`some
    RouterMethods<Context>`), the macro just adds the conformance — no proxy.
  - **Proxy (signature mismatch).** When it doesn't — e.g. `addRoutes(to group:
    RouterGroup<Ctx>)` or a differently-named method (todos-dynamodb style) — the
    macro generates a small proxy contributor that conforms and delegates/adapts to
    the controller's method. The proxy is what's collated. This is a first instance
    of the general "adapter replaces/wraps the binding" shape (shared with
    `@Configuration`; see *Deferred to M5*).
- The Router stays outside the graph; `apply(graph, to: router)` applies the
  collated contributors via `addRoutes(to:)`.

**Why now:** proves the codegen → real-Hummingbird seam end-to-end on the simplest
surface, and exercises the M2.1 conformance emission against a real adapter.

**Validation gate:** `WireHummingbirdHarness` — an app with a `@HummingbirdRoute`
controller holding an `@Inject`ed service whose `addRoutes` **matches** (conformance
case) **and** one whose signature **doesn't** (proxy case); Tier-1 `apply` on a
user-built router; requests via `app.test(.router)` resolve through both.

## Iteration M2.3 — middleware fold (`BuilderKey` via `MiddlewareFixedTypeBuilder`)

**Scope:**
- `@HummingbirdMiddleware` macro → `@Contributes(to: HummingbirdMiddlewareKey)`.
- `HummingbirdMiddlewareKey` is a `BuilderKey` whose builder is Hummingbird's
  `MiddlewareFixedTypeBuilder` — Wire emits the contributors as static expressions
  in the builder block, folding them into one `some MiddlewareProtocol` (the
  parameterized-opaque `BuilderKey`; shape proven by spike-7 Proof 2 + spike-9).
- `apply` adds the folded stack (`_ = router.add(middleware:)`); it's surfaced via
  the conformance as an associated-type-bound member (spike-10).
- Middleware are app-scoped bindings with injected deps (`SessionMiddleware(storage:)`,
  an authenticator holding a key collection).

**Why now:** middleware-with-DI is a core `buildApplication` ingredient; it's the
last collation surface (after routes) needed to replace a hand-written one.

**Validation gate:** harness app with two `@HummingbirdMiddleware`, one holding an
injected dependency; the folded stack runs both in order and each receives its
deps (both effects observed on a graph route).

## Iteration M2.4 — service lifecycle (`[any Service]` incl. graph teardown)

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

## Iteration M2.5 — Tier 2: the `@WireHummingbird` composition-root macro

**Scope:**
- `@main @WireHummingbird` on a composition-root type. The macro reads its members
  (spike-2): an `@Inject`ed config value, `routerBuilder()`, `applicationConfiguration()`.
- Generates `main`: `Wire<Module>.bootstrap()` → `routerBuilder()` → `apply`
  collated middleware+routes → construct `Application(configuration:, services:)`
  → run. Hides the Tier-1 two-call shape (it can name the generated bootstrap).

**Why now:** the ergonomic payoff — a zero-boilerplate entry point — once the
collation underneath (M2.2–M2.4) is proven.

**Validation gate:** Tier-2 harness app; the generated `main` serves graph routes,
folds middleware, runs services, and configures from the `@Inject`ed value.

## Iteration M2.6 — runtime introspection (`introspect()` + `/admin/wiring`)

**Scope:** a read-only runtime view of the graph structure (bindings, dependency
edges) — the `Resolver.introspect()` API the README's M2 entry names, plus an
`/admin/wiring` example endpoint. Not dynamic resolution (stays
[rejected](Archive/M1_PLAN.md#design-decisions-settled-during-m1)).

**Validation gate:** the harness's `/admin/wiring` endpoint returns the wiring view.

## Deferred to M5 (WireMVC) — with M2/prior work as its foundation

Request scope leaves M2 entirely, because it needs routing Wire generates:

- **Request-scoped controllers** are **WireMVC-only.** A native controller's
  `addRoutes` is arbitrary hand-written routing; embedding per-request scope entry
  would mean parsing and rewriting that body — intractable. WireMVC *generates* the
  routing, so it can embed the scope entry cleanly.
- **The mechanism** (M5): the adapter **replaces the binding with a proxy
  contributor** — a request-scoped controller becomes an app-scoped proxy whose
  *generated* `addRoutes` embeds the scope entry, holding a **back-reference to the
  graph** (populated post-construction, weakly, via the shipped `@Inject weak var`
  pattern) to build per-request scopes. The graph collates the proxy like any
  contributor; `apply` calls `addRoutes(to:)` uniformly — no separate scoped path.
- **The back-reference does double duty:** it's also how a seeded scope receives
  its **parent** — `bootstrap<Seed>Scope(seed:, wireGraph:)`'s `wireGraph:` becomes
  the proxy's back-ref rather than an argument threaded through a route wrapper. The
  graph wires it in.
- **"Adapter replaces the binding" is a shared Wire capability** — the same shape
  `@Configuration` needs (replace `let port: Int` with a config-reading provider).
  Worth factoring as a Wire primitive, not a WireHummingbird one-off.
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
- **`AdapterModel.md`** documents the *side-effect* `@RoutedBy` registration model,
  which WireHummingbird no longer uses — it stays relevant to WireOpenAPI (M3);
  WireHummingbird's collation/conformance model is documented in the design note.

## Open decisions to pin

- **The graph-conformance emission details** (M2.1): how associated types are
  inferred when a member maps to a `BuilderKey`'s opaque product; how the composed
  `some (A & B)` return is spelled when zero adapters are present (bare graph) vs one
  vs many.
- **Empty collections** — a middleware `BuilderKey` with no contributors needs an
  identity witness (does `MiddlewareFixedTypeBuilder` accept an empty block?).
- **Proxy vs conformance detection** (M2.2) — the macro inspecting the controller's
  `addRoutes` signature to decide; the fallback (always proxy) if inspection is
  unreliable.

## When M2 is "done"

- `WireHummingbird` ships: native app-scoped HB controllers auto-wired (routes +
  middleware), service lifecycle via `[any Service]` + graph teardown, the Tier-2
  `@WireHummingbird` macro, and `introspect()`.
- Wire Core gains the framework-agnostic graph-conformance capability + public
  `Wire<Module>.bootstrap()`.
- The `WireHummingbirdHarness` gate passes on macOS and Linux (added to CI).
- Sets up M3 (WireOpenAPI reuses the machinery for `registerHandlers`) and M5
  (WireMVC reuses it + the deferred request-scope foundation).
- No public 0.x tag yet — pre-alpha stays loud.
