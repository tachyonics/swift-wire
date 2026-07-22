# WireHummingbird — design note (M2)

> **Status:** the model settled during M2 design and was then **refined against the
> real [hummingbird-examples](https://github.com/hummingbird-project/hummingbird-examples)
> repo** (the controller survey below). Proven against real Hummingbird via
> [spike-9](../../../swift-wire-spikes/spike-9-hummingbird-bootstrap/) (bootstrap +
> collation) and [spike-10](../../../swift-wire-spikes/spike-10-graph-conformance/)
> (graph conformance); the context-free surface + conformance-extension seam were
> re-proven in the external `wire-hummingbird` repo.
>
> **This note supersedes two earlier drafts of its own:** (1) the `_wireRegister`
> side-effect `@RoutedBy` contract (collation replaced it — [AdapterModel.md](AdapterModel.md)
> is not the mechanism here); (2) the *proxy / binding-rewrite* for signature
> adaptation, the `Wire<Module>` public entry, the composed `some (A & B)` return,
> and the context-*pinned* `RouteContributor<Context>` — all replaced by the
> context-free surface, the internal `Wire.bootstrap()` returning the concrete
> graph, and a conformance-extension macro (below).

## What M2 is

A **Tier-1 framework adapter**: automate application-level wiring — construct
controllers from Wire's graph and get their routes/middleware onto a Hummingbird
`Router` — while controllers keep their native Hummingbird form. It does **not**
abstract routes (WireMVC, M5) and does **not** cover OpenAPI `registerHandlers`
(WireOpenAPI, M3).

**App-scoped only.** Request-scoped controllers need generated routing and are
M5/WireMVC (see *The WireHummingbird ↔ WireMVC boundary*). The forcing case is
task-cluster: its hand-written `buildApplication` becomes generated.

## The architecture

### Router outside the graph; the graph collates contributions

The `Router` is a **bootstrap builder that stays outside the graph** (spike-9). The
graph only *collates contributions*; a facade applies them to a user-provided
router and assembles the `Application`. Nothing in the graph consumes a mutated
collaborator, so ordering never arises — and the whole `_wireRegister`
adapter-registration contract is unnecessary.

- **Routes → a `CollectedKey`.** A controller `@Contributes` into
  `HummingbirdKeys.routes = CollectedKey<any HummingbirdRouteContributor>`. Routes
  can't fold to a value (each applies its own routes as a side effect) — hence
  `CollectedKey`.
- **Middleware → out of scope (M2.4).** It doesn't fit collation: a middleware
  *is* a context-typed value (`RouterMiddleware<Context>`) in the pipeline, not a
  callable whose context defers to the call site the way a route contributor's
  `addRoutes` does. Wrapping each in a `MiddlewareContributor` is a hack in the
  wrong shape, and a `BuilderKey<MiddlewareFixedTypeBuilder<…, Context>>` fold pins a
  concrete `Context` — reintroducing exactly the pinning routes removed. Zero
  regression: the app owns the `Router` and calls `router.addMiddleware { … }`
  itself. The callable-vs-value distinction is the deciding factor — services
  (below) are also values but **context-free**, so they collate; middleware is a
  *context-typed* value, so it can't. The standard-`Middleware` cross-runtime path
  is WireMVC/M5 (see *Standard middleware* below).

### The collation surface is context-free

`RouteContributor` carries **no `Context`** — its witness is a generic method:

```swift
public protocol RouteContributor {
    func addWireRoutes<Context: RequestContext>(to router: some RouterMethods<Context>)
}
public enum HummingbirdKeys {
    public static let routes = CollectedKey<any RouteContributor>(allowUnused: true)
}
```

So the collection is a plain `[any RouteContributor]` (no free type in the key — a
key can't be a stored static in a generic type anyway), `HummingbirdComposable` has
no associated type, and the app's request context binds at the `apply` call:

```swift
public static func apply<Context: RequestContext>(
    _ graph: some HummingbirdComposable, to router: some RouterMethods<Context>
) { for c in graph.routes { c.addWireRoutes(to: router) } }
```

`addWireRoutes` is Wire-internal (generated, not hand-written); the name avoids
collision with the author's own `addRoutes` and carries no leading underscore (so
no SwiftLint `identifier_name` friction in hand-written conformances).

### No proxy — a conformance-extension macro

Adapting a native controller to this surface needs **no separate proxy type**: the
controller is stateless-to-conform and in-module, so a macro-generated **conformance
extension** adds `RouteContributor` directly, with a witness that owns the mount and
delegates to the controller's hand-written `addRoutes`:

```swift
@Singleton
@Contributes(to: HummingbirdKeys.routes)
@HummingbirdController("todos")                 // annotation owns the mount
struct TodoController {
    @Inject init(repo: Repo) { self.repo = repo }
    func addRoutes(to router: some RouterMethods<some RequestContext>) { … }   // untouched
}
// generated:
extension TodoController: RouteContributor {
    func addWireRoutes<Context: RequestContext>(to router: some RouterMethods<Context>) {
        addRoutes(to: router.group("todos"))     // no-arg @HummingbirdController → addRoutes(to: router)
    }
}
```

The Wire-internal witness name means the generated method and the author's
`addRoutes` never collide (verified — no overload/recursion ambiguity). The
"proxy / binding-rewrite" concept is **dropped**: it was only ever needed to
defer-instantiate a *type-generic* `Foo<Context>`, which requiring context-free
controllers removes. The macro can't add `@Singleton`/`@Contributes` (attributes on
the type), so those stay explicit until a plugin-side contribution-attribute folds
`@Contributes` into `@HummingbirdController` (the small surviving remnant of the old
M2.3).

### The one new Wire Core capability (M2.1, shipped): graph-conforms-to-declared-protocol

`_WireGraph` exposes bindings as generated-*named* properties, so a framework
library can't read the collections directly. The bridge is **generic and
framework-ignorant** — an adapter declares a conformance, discovered syntactically:

```swift
// contributed by WireHummingbird
public let wireHummingbirdConformance = WireGraphConformanceV1(
    conformsTo: (any HummingbirdComposable).self,
    members: [.init("routes", from: HummingbirdKeys.routes)]     // CollectedKey product
)
```

Wire emits `extension _WireGraph: HummingbirdComposable { var routes: [any RouteContributor] { <collectedProp> } }`
— **without knowing the protocol is HTTP-shaped**. (Where a member's key element
has an associated type, it's inferred from the witness; the context-free surface is
the simpler non-associated case.) Wire Core = DI graph + multibindings + this
conformance capability, zero framework knowledge; WireHummingbird = the protocol,
the conformance declaration, the macro, and `apply`.

### Entry: internal `Wire.bootstrap()` returning the concrete graph

The generated entry is `internal enum Wire { static func bootstrap() … }` — **not**
the earlier public `Wire<Module>` marker, and **not** a composed `some (A & B)`
return. It returns the **concrete `_WireGraph`**, which *conforms to every declared
adapter protocol* (`HummingbirdComposable`, and later `MVCComposable`, …). There's
no information hiding: the developer keeps member access (`graph.logger`), and each
adapter's generic facade picks the conformance it needs:

```swift
let graph = try await Wire.bootstrap()                 // concrete _WireGraph
let services = WireHummingbird.apply(graph, to: router)  // apply<…>(_ graph: some HummingbirdComposable, …)
```

A local `enum Wire` coexists with `import Wire` (verified), so no marker/generic is
needed. Access is internal because the entry is only referenced intra-module (the
composition root or a Tier-2 macro's `main`).

### The two integration tiers, and lifecycle

- **Tier 1 — minimal.** `let graph = try await Wire.bootstrap(); let services =
  WireHummingbird.apply(graph, to: router); return Application(router:, services:, …)`.
  Two idiomatic touch points.
- **Tier 2 — `@main @WireHummingbird`.** A composition-root type the macro reads;
  it generates `main` (bootstrap → build router → apply → construct → run). *(Retired:
  the Tier-2 macro shipped as the proposal-native `@WireMVCBootstrap` in M5.5, not a
  Hummingbird-specific `@WireHummingbird` — see [ROADMAP.md](../../ROADMAP.md) M5.5. Tier 1
  above stays the idiomatic Hummingbird path.)*

`apply` returns one ordered `[any Service]`: collected services (`@Contributes` into
`CollectedKey<any Service>`) plus the graph teardown modelled as a single `Service`
placed **first** so it unwinds **last** (verified against Hummingbird's reverse-order
`ServiceGroup` shutdown). The graph's lifetime is bracketed by the app's
`ServiceGroup` with no separate handle. (M2.5.)

## What the examples actually look like (the survey that shaped this)

Surveying every `addRoutes` in hummingbird-examples pinned the design:

- **`addRoutes(to:)` is a universal convention, not a protocol.** Controllers are
  bare structs with an `addRoutes` method the app calls directly.
- **Universal wiring pattern:** `Controller(deps).addRoutes(to: router.group("path"))`
  — the mount path lives *app-side*, deps are constructor-injected, some controllers
  mount at root (`addRoutes(to: router)`). This maps 1:1 onto `@Inject` +
  `@HummingbirdController("path")` (the annotation takes over the `router.group` line).
- **Two axes of variance:** router type (`Router` / `RouterGroup` / `some
  RouterMethods`) and context (generic `<Context>` / opaque `some RequestContext` /
  **concrete `typealias Context = AppRequestContext`**).
- **Correction that mattered:** `typealias Context = AppRequestContext` is
  context-*specific*, not generic. So the **majority** of real (auth) apps are
  context-specific — every auth/session example fixes a concrete `AuthRequestContext`
  to read `context.identity`. Context-free/opaque is the *no-auth* minority.

The context-free surface therefore fits new, context-agnostic controllers written
*for* WireHummingbird; auth controllers that read a typed context belong on the
other side of the boundary below. WireHummingbird prescribes the context-free shape
(self-grouping or `@HummingbirdController` owns the mount) — of the 18 example
controllers only one matches directly, so this is "write controllers *for*
WireHummingbird," not drop-in adaptation (that was the proxy's job, and it's gone).

## The WireHummingbird ↔ WireMVC boundary

### Three models for request-scoped data

- **Hummingbird** puts it on the typed request **context** (`context.identity`).
- **Vapor** puts it on the **request** (`req.auth.get(User.self)`).
- **Wire** puts it in a request-seeded **scope** as **injected bindings** — the DI
  model (ASP.NET Core scoped services, Spring `@AuthenticationPrincipal User`).

Wire's model is *orthogonal* and *unifying*: the Hummingbird-vs-Vapor difference
collapses to a single seam — how the scope is seeded (off the HB context vs the
Vapor request) — and above it the model is identical. Wire doesn't pick a side; it
makes the sides interchangeable. `requireIdentity()`'s throw becomes a binding that
throws and propagates out of scope bootstrap to the normal HTTP error handling —
nothing new to design there.

### The line, and where it sits

- **WireHummingbird (this note)** — app-scoped, native controllers; request data via
  the closure's `(request, context)` params or a task-local (the OpenAPI escape
  valve). This is the *simple tier* and the proof vehicle for the collation
  mechanics that WireMVC reuses.
- **WireMVC (M5)** — request-scoped **injection** (per-request deps injected into
  handlers), which needs generated routing. The typed-context auth idiom lands here.

So *wiring to* a controller (collate) and *wiring within* it (request-scoped inject)
are separable: the former is WireHummingbird and works now; the latter is WireMVC. A
controller migrates as a unit when it wants injection over context-reading
(auth-abac is the worked example — a request-seeded scope providing `identity`,
carried on the context during migration, then controller-by-controller to WireMVC).
WireHummingbird's *durable* value is the assembly layer (services, router assembly,
`Application`, lifecycle), which every Wire+Hummingbird app needs regardless.

### Native vs cross-runtime surfaces (the ServerTransport question)

The future common surface is the OpenAPI generator's **`ServerTransport`** (already
has Hummingbird/Vapor/Lambda adapters), which WireOpenAPI (M3) uses via
`registerHandlers(on: some ServerTransport)`. But a native controller **cannot** be
retrofitted onto it, for a decisive reason: **`ServerTransport` is context-free**
(http-types handlers), while `RouterMethods<Context>` handlers get the app's real
per-request context. The bridge is *one-way*:

- **native → transport works** (swift-openapi-hummingbird): the HB router *owns
  context creation*, builds the `Context` per request, and runs the context-free
  handler inside it.
- **transport → native cannot**: a `ServerTransport` only ever yields
  `(HTTPRequest, HTTPBody?, ServerRequestMetadata)` — there's no channel/source to
  synthesize the app's `Context`, so a native handler reading `context.identity`
  would get nothing. Not just wasteful double-translation — semantically impossible.

**The typed `Context` is simultaneously what makes native controllers valuable and
what makes them un-portable.** So there are permanently **two surfaces**, coexisting
on one app, bridgeable only native→transport:

| | target | context | portability |
|---|---|---|---|
| **native** (WireHummingbird) | `some RouterMethods<Context>` | app's real per-request context, full DSL | HB-only |
| **cross-runtime** (WireOpenAPI / agnostic WireMVC) | `some ServerTransport` | context-free transport; typed input reconstructed by standard middleware (below) | HB / Vapor / Lambda |

The conformance-extension seam is the same in both; only the target type and the
(agnostic vs native) *input* differ. Genericity lives in the **controller**, not the
protocol — `RouteContributor.addWireRoutes` is irreducibly framework-specific.

### Standard middleware makes the cross-runtime handler typed

WireHummingbird does **not** collate native Hummingbird middleware — it's out of
scope (M2.4, a context-typed value; the app owns it via `router.addMiddleware`).
**WireMVC's** middleware is the ecosystem-standard, proposed
[`Middleware`](https://github.com/apple/swift-http-api-proposal/blob/main/Sources/Middleware/Middleware.swift)
— neither framework-specific nor Wire-invented:

```swift
protocol Middleware {
    associatedtype Input: ~Copyable, ~Escapable
    associatedtype NextInput: ~Copyable, ~Escapable = Input
    func intercept<Return: ~Copyable>(input: consuming Input,
        next: (consuming NextInput) async throws -> Return) async throws -> Return
}
```

`NextInput` can differ from `Input`, so a middleware **transforms the input type** —
and that dissolves the context-loss problem for the cross-runtime surface. The
transport is context-free (http-types), but the middleware *pipeline* constructs the
typed input on top of it: `UserIdentityMiddleware` is `Middleware where Input ==
Request, NextInput == (Request, Identity)`, so the handler receives an input already
carrying `Identity` — non-optional, **guaranteed by the type**. auth-abac's
`context.identity`/`requireIdentity()` becomes a typed value the pipeline builds,
owned by the ecosystem — not the framework, not Wire.

Two consequences:

- **The security boundary is compile-time.** If `create`'s input is `(Request,
  Identity)`, the codegen'd chain only produces it when an identity-adding middleware
  is in the chain; omit the `@Middleware` and the `NextInput → Input` types don't
  compose — a compile error, not a runtime `requireIdentity()` throw.
- **Codegen-into-handlers is the fit, and Wire only *wires*.** The macro injects the
  middleware (graph bindings, with their own deps) and emits the nested `intercept`
  chain (controller-level outside endpoint-level outside the handler), threading the
  `Input` types through to the handler. Wire adds nothing to the middleware model; it
  complements the seeded scope — middleware-provided request data rides the `Input`
  transformation, deeper request-scoped deps not on the request path come from the
  scope.

**Caveats:** it's a *proposal* — targeting it is a forward bet on ecosystem
convergence; and `~Copyable, ~Escapable` + `consuming` mean the input is *consumed*
down the chain, so the generated nesting must respect single-consumption (spike it
when WireMVC starts — a codegen constraint, not a blocker).

## Scope model: bindings + roots (the M5/WireMVC foundation)

> Request scope is **M5**, not M2. This is the model M5 builds on.

Drop the assumption that *a scope is one dependency graph*:

> **A scope is a set of bindings + a set of roots. Construction materialises the
> subgraph reachable from the roots being materialised.**

- **App scope** materialises all roots at bootstrap — one graph.
- **A seeded (request) scope** materialises *one* explicitly-marked root per request
  — only the dispatched controller's subgraph is built.

**Per-root, not eager-whole-scope**, because request-scoped bindings do real
per-request work; materialising the whole request scope would run every route's work
on every request. When request scope lands in M5 it fits the same collation via the
**adapter-replaces-the-binding** shape (also what `@Configuration` needs): a
request-scoped controller becomes an app-scoped **proxy contributor** whose
*generated* `addRoutes` embeds per-request scope entry (spike-8 mechanism B),
holding a **weak back-reference to the app graph** to build per-request scopes. The
back-ref does double duty as the seeded scope's parent
(`bootstrap<Seed>Scope(seed:, wireGraph:)`). Context and Wire request scope compose:
the seed is built from `(Request, Context)`, so the scope can read context-populated
values. (This is the *only* remaining "proxy" in the design — a **request-scope**
mechanism in M5, distinct from the app-scoped conformance-extension above.)

### Prior art

- **Request-scoped injection** — ASP.NET Core `AddScoped<>`, Spring
  `@AuthenticationPrincipal User` (guaranteed present; the security filter rejects
  before the method). This is the model Wire imports; it's the DI-mature standard,
  not a workaround.
- **Context-free handlers + task-local** — the Swift OpenAPI generator: spec-driven
  handlers that know nothing about the framework, request context via task-local.
  Proof that a framework-agnostic surface works in production (at the cost of native
  ergonomics).
- **Compile-time scopes** — Dagger `@Subcomponent`s per entry, SafeDI `@Forwarded`
  (closest Swift precedent), Needle/Weaver hierarchical scopes, Micronaut's
  singleton-controller + param-binding (Hummingbird's own idiom). Where Wire differs:
  it builds the whole reachable subgraph from the selected root **eagerly**
  (`Lazy`/`Provider` as the opt-out), consistent with its app-scope philosophy.

## Positioning

Opt-in, layered over Hummingbird's idiom. A `@Singleton` controller reading the
context still works with zero per-request cost; the documented default stays
singleton + context, and request-scoped injection is the deeper-adoption (WireMVC)
step, matching Wire's JVM-DI on-ramp audience.

## Suggested sequencing

See the archived [M2_PLAN.md](../Archive/M2_PLAN.md). In brief: **M2.1** Wire Core conformance emission +
`Wire.bootstrap()` (done) → **M2.2** context-free route slice + `@HummingbirdController`
macro (done) → **M2.3** `@Contributes` alias (done) → **M2.4** middleware **out of
scope** (app-owned) → **M2.5** `[any Service]` lifecycle → **M2.6** Tier-2 macro →
**M2.7** introspection. Request scope is **M5 (WireMVC)**.

## Open items to pin

- **The `(Request, Context) → seed` bridge** (M5) — a WireMVC convention vs a
  user-provided conformance.
- **Adapter-collection consolidation (M5)** — ship each adapter self-contained (its
  own key + `WireGraphConformanceV1`); the concrete graph conforms to all of them, so
  two adapters coexist without a composed return. WireMVC is the single place the
  *consolidation* question lives (does `@MVCRoute` render into `HummingbirdKeys.routes`
  and/or a `ServerTransport` that folds `OpenAPIHandlersKey` in, or sit side-by-side?).
  A later optimisation, decided when WireMVC's rendering target exists — don't design
  M5's target from inside M2/M3. Keep each contributor shaped around the target it
  registers on (`some RouterMethods`, `some ServerTransport`) so any fold-in is a
  re-home, not a rewrite.

**Decided** (were open): the graph-conformance mechanism is **shipped** (M2.1);
the entry is internal `Wire.bootstrap()` returning the **concrete** graph (no
`Wire<Module>`, no `some (A & B)`); the collation surface is **context-free** (no
`RouteContributor<Context>`); signature adaptation is a **conformance-extension
macro**, not a proxy.

## References

- [spike-9](../../../swift-wire-spikes/spike-9-hummingbird-bootstrap/) — bootstrap, collation, `some RouterMethods`, middleware BuilderKey, lifecycle.
- [spike-10](../../../swift-wire-spikes/spike-10-graph-conformance/) — graph conformance, associated-type inference.
- [spike-8](../../../swift-wire-spikes/spike-8-hummingbird-request-scope/) — request-scope entry, mechanism B (M5).
- `wire-hummingbird` (external repo) — the context-free surface + conformance seam, end-to-end against pushed swift-wire main.
- [BuilderKeyDesign.md](BuilderKeyDesign.md) / [OpaqueTypesSupport.md](OpaqueTypesSupport.md) — the middleware-fold key; lifting.
- [AdapterModel.md](AdapterModel.md) — the side-effect `@RoutedBy` contract this adapter no longer uses (still relevant to WireOpenAPI/M3).
