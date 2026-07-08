# M5 Implementation Plan — WireMVC

The implementation plan for M5: swift-wire's cross-framework declarative-routing
adapter, `WireMVC`. The milestone sits in [ROADMAP.md](../ROADMAP.md); the authoritative
record of the settled M5.0 decisions and annotation surface is
[Notes/WireMVCDesign.md](Notes/WireMVCDesign.md). The earlier design-space *exploration* is
[Notes/WireMVCAbstraction.md](Notes/WireMVCAbstraction.md) (superseded — still written
against the retired `_wireRegister` model; its rewrite is M5.6). Iterative, same discipline as
the archived [M1](Archive/M1_PLAN.md) and [M2](Archive/M2_PLAN.md) plans: each
iteration runs end-to-end and has a validation gate.

**The headline:** WireMVC is a **spec-free, annotation-driven analogue of the OpenAPI
generator's registration codegen.** `@Controller`/`@Get`/`@Path`/`@JSONResponse`
**fold into M3's `ServerTransport` collation surface** (`TransportContributor` /
`TransportKeys.handlers` / `TransportComposable` / `apply`) — a *re-home*, not a
parallel surface. Where WireOpenAPI's `TransportContributor` witness calls the
generator's `registerHandlers(on:)`, WireMVC's witness is a body Wire *generates* from
the annotations: decode path/query/body params from the raw request, call the handler,
encode the response. Because the target is `some ServerTransport`, the same controller
mounts on Hummingbird, Vapor, or Lambda unchanged — cross-runtime for free, exactly as
M3 proved.

**Middleware needs no native-middleware router.** Because WireMVC owns the
route-registration codegen, controller- and route-scoped `@Middleware` are nested
wrappers around the generated handler closure. Composition is closure nesting; no
runtime router type exists. **Type-transforming middleware falls out as a compile
error** — the codegen threads each middleware's output type into the next stage's
input, so an auth middleware producing an authenticated principal a handler requires
either type-checks or fails at the generated seam. This retires the "native-middleware
router PoC" the M2 deferral parked.

**The escape hatch is a raw handler.** Anything WireMVC's typed core can't express —
streaming, SSE, WebSocket upgrades, proxying — falls into a catch-all route whose
handler takes the transport-native raw request/response and is registered verbatim,
skipping decode/encode. Middleware can still wrap it. One catch-all, not a growing
list of special-case annotations.

## How to use this plan

- Each iteration has a *scope*, a *why-now*, and a *validation gate*. Don't move on
  until the gate passes.
- **Highest-risk first** (M1/M2 philosophy): the riskiest seam is **M5.0's target
  decision + the generated `TransportContributor` witness body** (param decode / call /
  encode against a bare `ServerTransport`). Everything else layers on it. Middleware
  (M5.3) and request scope (M5.4) are the two conceptually hard follow-ons, but both
  have their load-bearing shapes already proven (see *What M5 rests on*).
- **Validation vehicle:** WireMVC ships as an **external repo** depending on *pushed*
  swift-wire main (the task-cluster pattern — see
  [[feedback_adapters_are_external_repos]]). Any new Core capability an iteration needs
  lands in swift-wire, gets pushed, then the adapter repo picks it up. The
  framework-agnostic core capabilities (graph-conformance emission, the
  `BuilderKey`→opaque-member fold) are validated *in* swift-wire's
  `Tests/IntegrationTests`, framework-free.
- **The gate is the example set.** Beyond the harness, M5's real gate is a
  **progressively-ported example repo** (`wire-hummingbird-examples`, or a sibling of
  the `wire-hummingbird` adapter repo) — each iteration un-gates when the examples it
  targets express cleanly on WireMVC. This is the "task-cluster forces the next
  milestone" discipline at example granularity, and it doubles as the content piece the
  roadmap wants M5 to be (a literal side-by-side of the Hummingbird example vs. the
  WireMVC version). The example→capability map is in *Cross-cutting concerns*.
- **Diagnostics continue M1's standard** — new error paths (a `@Get` on a non-func, a
  `@Path` param with no `{name}` in the route, a middleware type-thread mismatch) get
  good diagnostics with fix-its.

## What M5 rests on (shipped / proven)

- **The `ServerTransport` collation surface** — M3 shipped `TransportContributor`,
  `TransportKeys.handlers = CollectedKey<any TransportContributor>`, `TransportComposable`,
  and `apply(graph, to: transport)`. WireMVC's `@Controller` contributes into exactly
  this key; only the *witness body* is new (generated, not `registerHandlers`). See
  [Notes/WireOpenAPIDesign.md](Notes/WireOpenAPIDesign.md).
- **The `@Contributes`-alias adapter contract** — a `WireAdapterAnnotationV1` aliasing
  `@Controller` to `@Contributes(to: TransportKeys.handlers)`, mirroring
  `@OpenAPIController`/`@HummingbirdController`. No new contract form.
- **Graph-conformance emission** — `extension _WireGraph: TransportComposable`, emitted
  by Core knowing nothing about HTTP (M2.1, shipped). Reused verbatim.
- **Type-level macro walking method-level annotations** — [spike-2](../../swift-wire-spikes/spike-2-macro-member-walk/)
  PASSED: a type-level `@Controller` macro reading its members' `@Get`/`@Path`
  annotations is mechanically viable. M5 is contract/codegen design, not macro
  de-risking.
- **The `BuilderKey`→opaque-member fold** — the shipped-but-unused-in-M2 emission
  (`var x: some P<…> { self.prop }`) is what the *global* standard-`Middleware`
  aggregation (M5.5, option iii) exercises. Parameterized-opaque lifting proven by
  [spike-7](../../swift-wire-spikes/spike-7-iteration-10-lifting/) Proof 2.
- **Request-scope foundation** — [spike-8](../../swift-wire-spikes/spike-8-hummingbird-request-scope/)
  (request-scope entry), seeded-scope construction (`bootstrap<Seed>Scope`,
  iteration 4), the `@Inject weak var` back-reference pattern, and per-root
  reachability materialisation are M5.4's engine, carried forward from M2's
  *Deferred to M5* section — not rebuilt.

## Scope boundary

WireMVC's **typed core** covers request→response handlers with structured
params and encoded bodies. Explicitly **out of the typed core, into the raw
escape hatch (M5.2):** streaming responses, server-sent events, WebSocket upgrades,
and proxying. Explicitly **not M5 at all:**

- **Background/scheduled work** (`jobs`-style) — a scope/lifecycle axis, not routing.
  Not a WireMVC gate.
- **Content negotiation beyond JSON + form/multipart decode** — a narrow
  encoder/decoder hook is in M5.1's scope; pluggable multi-format negotiation is
  post-1.0 unless an example forces it.
- **A second HTTP-framework adapter (`WireMVCVapor`)** — the cross-runtime property is
  *structural* (the target is `ServerTransport`), so a second adapter proves nothing
  new (same reasoning that skipped M3.4). Follows post-M5 only if a Vapor variant of
  task-cluster materialises.

## The model in one paragraph

A `@Controller("/tasks")` type is a **transport contributor**: the plugin injects
`@Contributes(to: TransportKeys.handlers)` (the alias), and the macro generates a
`TransportContributor` conformance whose `registerWireHandlers(on: any ServerTransport)`
witness, for each `@Get`/`@Post`/… member, registers a handler closure that (a) decodes
the member's `@Path`/`@Query`/`@Body`/`@Header` params from the raw request, (b) applies
the route's and controller's `@Middleware` layers as nested wrappers, (c) calls the
handler, and (d) encodes the return via `@JSONResponse` (status + body). The controller
is constructed from the graph (lift-the-minimum, shipped) and collated exactly like an
OpenAPI controller — `Wire.bootstrap()` returns the concrete graph, which conforms to
`TransportComposable`, and `WireMVC.apply(graph, to: transport)` registers the collated
handlers on a user-owned `some ServerTransport` that stays *outside* the graph. Global
middleware is a **Tier-2 concern** (M5.5), applied at the router-assembly layer — not
folded per-route — so it keeps its pre-routing / unmatched-request coverage. A
`@Scoped(seed:)` controller (M5.4) becomes an app-scoped proxy contributor whose generated
witness embeds per-request scope entry, **rooted per-controller by reachability**. A raw
handler (M5.2) skips (a) and (d)
and registers verbatim.

## Iteration M5.0 — pin the target protocol + annotation surface (design gate)

The one iteration that's design-only. Two decisions, both settled here so M5.1 codes
against a fixed shape.

**Scope:**
- **Target protocol.** WireMVC registers routes on a **routing surface** and never
  reimplements routing — a Router does that in every option. Candidates:
  - *`some ServerTransport` (OpenAPIRuntime's), the M3 re-home* — cross-runtime for free,
    reuses the shipped collation/conformance machinery, couples WireMVC to `OpenAPIRuntime`
    only (no HTTP framework, same posture as WireOpenAPI). A per-route registration surface
    that adapters conform their routers to.
  - *`swift-http-api-proposal`'s server surface* — `HTTPServer.serve(handler:)` takes one
    `HTTPServerRequestHandler`, but **that handler is a Router**, not WireMVC: a routing
    framework built on the proposal provides `Router: HTTPServerRequestHandler`, the Router
    sits on top of `serve`, and WireMVC registers per-route on it exactly as it would on a
    transport. The proposal's genuine draws over `ServerTransport` are *first-class typed
    `Middleware`/`@MiddlewareBuilder`* (the fold, native — M5.3), *capability-typed
    `RequestContext`* (request scope — M5.4), and `~Copyable` streaming — **not** "WireMVC
    owns routing." (WireMVC *could* instead emit a **static compile-time dispatch** as a
    terminal `Middleware` and skip a runtime Router, since it knows every route at compile
    time — a possible optimization, deliberately opt-in, not forced by the target and not
    M5.)
  - *A Wire-published `WireMVCServer`* — self-contained but a parallel surface; last resort.

  **Decision: standardise on `some ServerTransport`.** It's the proven Swift shape
  (swift-openapi-generator targets exactly it, verified from source), cross-runtime for
  free, already Wire's shipped collation primitive (M3's `TransportContributor` witness),
  and dispatch-agnostic (per the dispatch decision below). This is not a permanent wedding:
  the **route-descriptor table is the portability layer** — the macro's source of truth is
  the descriptors, not the `register` call, so the transport is a swappable backend (the
  witness parameter swaps). The **`swift-http-api-proposal` server surface is the tracked
  successor**: when it stabilises (a comparable — not longer — timeline than swift-wire's own
  M5 → M6 → feedback path; `anyAppleOS 26.0` server / `26.2` middleware, Swift 6.4), WireMVC
  follows it behind the same seam. One cost accepted with eyes open: `ServerTransport` lives
  in `OpenAPIRuntime`, so WireMVC takes a **light, stable, OpenAPI-*branded* dependency** for
  a non-OpenAPI adapter — the better trade against inventing a parallel surface. The
  successor bridge is spikeable early (see M5.1's cross-runtime demo).
- **Annotation vocabulary.** Fix the surface: `@Controller(path)`; verb annotations
  `@Get`/`@Post`/`@Put`/`@Delete`/`@Patch(subpath)`; param annotations
  `@Path`/`@Query`/`@Body`/`@Header`; response `@JSONResponse` (with an optional status);
  middleware `@Middleware(expr)` at controller and route scope; and the raw escape hatch
  (M5.2). **Scope out** streaming/SSE/WebSocket *param* forms — they go through the raw
  handler, not bespoke annotations.
- **Dispatch model — dynamic now, static-capable by construction.** Register routes on a
  runtime router/transport (**dynamic dispatch**); this is the proven norm, not a
  compromise. Prior art (surveyed, primary sources): genuine compile-time *dispatch* is
  rare — of 15+ frameworks only Go's `ogen` (static radix from an OpenAPI spec) and Scala
  Play (a sequential generated `PartialFunction`) emit it; everything else sold as
  "compile-time"/"type-safe" routing (servant, Rocket, tapir, TanStack, tRPC, **and
  swift-openapi-generator**) provides compile-time *knowledge* over a **runtime** matcher.
  swift-openapi-generator is the direct precedent — verified from `ServerTransport.register`
  + the Vapor adapter, its `registerHandlers` calls `transport.register(...)` once per
  operation (path template as `String`) into the transport's runtime trie: exactly
  WireMVC-on-`ServerTransport`. And `pavex` — the closest analog (AOT codegen +
  compile-time DI) — codegens the *DI wiring* but delegates path matching to a runtime
  `matchit` trie. **Consequence:** the correctness wins people want from a "static router"
  (route-conflict/exhaustiveness detection) come from the **build plugin's global view**
  (a), not from generated dispatch (b) — and WireMVC's plugin already has that. **Design
  rule (zero-cost future-proofing):** the macro's source-of-truth artifact is the **route
  descriptor table** (method, path, param decode, handler ref, middleware chain), off which
  a **dynamic backend** (emit `register` calls — ship this) and, later, an optional
  **static backend** (emit one generated dispatch — a pure perf play, deferred/opt-in since
  routing is ~never the bottleneck; `ogen` is the existence proof it's doable off a build
  step) are both derivable. Do **not** make "emit `register` calls" the macro's only output.

**Why now:** M5.1's generated witness body is written against a concrete transport type
and a concrete param-annotation set; both must be pinned before codegen starts.

**Validation gate — MET.** The decisions are recorded in
[Notes/WireMVCDesign.md](Notes/WireMVCDesign.md) (target `some ServerTransport`; dynamic
dispatch with the route-descriptor table as portability layer; the `@Controller` /
`@Get…` / `@Path`·`@Query`·`@JSONBody`·`@Header` / `@JSONResponse` / `@ResponseStatus`
surface; `@JSONBody` content-type rules). The proving spike,
[spike-11](../../swift-wire-spikes/spike-11-wiremvc-servertransport/), hand-writes the
`registerWireHandlers(on: some ServerTransport)` witness and serves all six surface
behaviors in-process (`@Path` decode, `@JSONBody` 415/422/lenient, `@JSONResponse(status:)`,
`@ResponseStatus(.noContent)` → 204) — `spike-11 OK`. The witness signature and decode/
encode/status logic compile and run against real `ServerTransport` (`swift-openapi-runtime`
1.12.0), so M5.1 codegen has a validated target to emit against.

## Iteration M5.1 — app-scope controllers, JSON in/out, no middleware

The core codegen. App-scoped only, no middleware, typed handlers.

**Scope:**
- `@Controller` macro + `@Contributes(to: TransportKeys.handlers)` alias.
- Generate the `TransportContributor` conformance: per verb-annotated member, register a
  handler that decodes `@Path`/`@Query`/`@Body`/`@Header` params, calls the handler, and
  encodes the `@JSONResponse` return (status + JSON body). Route paths compose the
  controller prefix with the member subpath; `@Path` names must match `{name}`
  placeholders (validated).
- A narrow JSON encoder/decoder hook (JSON in / JSON out) — the one content form the
  core commits to.
- Controller construction via lift-the-minimum (shipped); collation + `apply` reused
  from M3.

**Why now:** this is the milestone's spine — everything else (middleware, request scope,
the Tier-2 macro) wraps or assembles this. Highest-risk-first.

**Validation gate:** the harness serves a decoded GET/POST round-trip; `hello` and a
`todos`-style example (e.g. `todos-dynamodb`, controllers only) port onto WireMVC and serve
in-process. **Cross-runtime demonstration:** the *same* controllers register and serve live
on **two** `ServerTransport`s — Hummingbird's and Vapor's (reuse the existing
`swift-openapi-hummingbird` / `swift-openapi-vapor` transport conformances directly, or thin
WireMVC-owned bridges; the OpenAPI generator isn't involved — WireMVC just calls
`transport.register`). This is a **content/demonstration** asset, *not* added verification:
cross-runtime is *structural* (the target is `some ServerTransport`), so — consistent with
the M3.4 skip — a second live transport doesn't make the property truer, it shows it.
**Optional richer form (gated on the proposal toolchain):** a third transport — a minimal
`ServerTransport` conforming a router to the proposal's
`HTTPServer`/`HTTPServerRequestHandler` — which doubles as the **successor-bridge spike** for
M5.0's tracked-successor claim (prove `ServerTransport` bridges onto the proposal server
surface, de-risking eventual adoption).

## Iteration M5.2 — the raw escape-hatch handler

The catch-all, before middleware — so streaming examples have a home and middleware
(M5.3) can be designed to wrap both typed and raw handlers uniformly.

**Scope:**
- A raw route form whose handler takes the transport-native raw request/response
  (`ServerTransport`'s `HTTPRequest`/`HTTPBody?`/metadata → `HTTPResponse`/`HTTPBody?`)
  and is registered verbatim — no param decode, no response encode. Spelling is an open
  decision (an explicit `@RawRoute`, or a verb annotation whose raw handler *signature*
  opts in); pin it here.
- The generated witness registers the raw closure directly; middleware wrapping (M5.3)
  still composes around it.

**Why now:** it bounds the typed core. Without it, every streaming/SSE/WebSocket example
would pressure the core to grow special cases; with it, the core stays typed-only and the
hard cases have one uniform exit.

**Validation gate:** an SSE or streaming example (`server-sent-events`,
`response-body-processing`) ports via the raw handler and streams a response in-process.

## Iteration M5.3 — middleware, folded into codegen

Controller- and route-scoped middleware as nested wrappers; the standard
`Middleware<Input, NextInput>` type; type-threading.

**Scope:**
- `@Middleware(expr)` at controller scope (wraps every route) and route scope (wraps one
  route), composed **outermost-controller → innermost-route → handler** as nested
  closures in the generated witness. **This is the whole of M5.3's middleware scope —
  per-route/controller only.** *Global* middleware is a Tier-2 concern (M5.5), because
  its defining property (pre-routing, unmatched-request coverage) puts it at the
  router-assembly layer the Tier-2 macro owns.
- **All WireMVC middleware is codegen-composed *with* the handler, never handed to a
  framework's `addMiddleware`.** Hummingbird's `RouterMiddleware<Context>` is bidirectional
  and context-typed — a different, incompatible protocol; WireMVC composes its own chain
  around the decoded handler.
- **The composition model, confirmed against the proposal's *actual* `Middleware`.** The
  ecosystem-standard
  [`Middleware<Input, NextInput>`](https://github.com/apple/swift-http-api-proposal/blob/main/Sources/Middleware/Middleware.swift)
  is `intercept<Return: ~Copyable>(input: consuming Input, next: (consuming NextInput)
  async throws -> Return) async throws -> Return`. It **threads a return back** (not
  one-way — an earlier note here was based on a stale `swift-http-server` copy whose `next`
  returned `Void`) and carries the response sender **inside `Input`**
  (`HTTPServerMiddlewareInput`), so it fully expresses request→response. Crucially **the
  handler is just the terminal middleware** (`NextInput == Void`/`Never`): a route is one
  `@MiddlewareBuilder`-style chain — `@Middleware` entries as forward-transforming stages,
  the `@Get` handler as the terminal that writes the response. `Input` is a box bundling
  request + capability-typed `RequestContext` + reader + response-sender
  (`RequestResponseMiddlewareBox`), which is why the terminal writes via the sender. This
  is the *ideal* shape for the fold, and **type-transformation is native to it** — and not
  aspirational: the standard `@MiddlewareBuilder`'s `buildPartialBlock(accumulated:next:)`
  *requires* `First.NextInput == Second.Input` (enforced by `ChainedMiddleware`), so an
  auth stage's `Input → AuthenticatedInput` that doesn't match what the handler-terminal
  requires **fails to compile in the ecosystem builder itself**. The raw escape hatch
  (M5.2) is just a terminal stage with raw `Input`, not a special case.
- **WireMVC keeps a *decoded* layer above the proposal's raw `Middleware`, regardless of
  timeline** — two reasons, one durable, one timing: (1) *durable:* the proposal's
  `Middleware` is at the **raw-transport level** (`HTTPServerMiddlewareInput`, byte
  readers/writers, `HTTPFields`, `~Copyable`/`~Escapable`), while WireMVC's whole value is
  *decoded* typed handlers — so WireMVC's terminal is always "decode params → typed handler
  → encode," a layer *above* the raw chain, even after the proposal ships; (2) *timing:*
  it's `@available(macOS 26.2, …)` over the new `HTTPAPIs`/`Middleware` packages — usable
  once that window opens, on a comparable timeline to M5 itself (not a someday).
  *Recommendation:* model WireMVC's decoded per-route middleware on the proposal's
  **forward-transform-plus-terminal** pattern (which delivers the compile-error property)
  over `some ServerTransport` (M5.0) now; as the proposal stabilizes, the raw `Middleware`
  chain becomes the **substrate under** that decoded layer (per-route *and* global), not a
  replacement for it. The god-object-critique differentiator holds either way.
- Validate `@Middleware` exprs against WireMVC's chosen middleware protocol; a
  type-thread mismatch gets a diagnostic that names the producing middleware, the
  expected input, and the offending stage.

**Why now:** middleware is the first thing that makes the codegen more than a
route-registration convenience. It precedes request scope only nominally — see M5.4.
(The `BuilderKey`→opaque-member fold this once anchored is now exercised by the *global*
standard-`Middleware` aggregation, deferred to M5.5 with the rest of the global layer.)

**Validation gate:** `open-telemetry` ports (pure-interception tracing,
`Input == NextInput`) **and** one `auth-*` example ports (type-transforming: the
authenticated principal is a typed value the handler requires, and removing the auth
middleware fails to compile).

## Iteration M5.4 — request-scoped controllers

Interleaved with M5.3 in practice — auth *identity* is the canonical request-scoped
value a type-transforming middleware produces and a request-scoped controller consumes.

**Scope:**
- A `@Scoped(seed: RequestSeed.self)` controller becomes an **app-scoped proxy
  contributor** whose *generated* `registerWireHandlers` embeds per-request scope entry
  (build the seeded scope from the request, construct the controller fresh, dispatch).
  The mechanism is the M2-deferred one, not new: a **weak back-reference to the app
  graph** (`@Inject weak var`, shipped) feeds `bootstrap<Seed>Scope(seed:, wireGraph:)`,
  the back-ref doing double duty as the scope's parent handle.
- **Each request-scoped controller is a per-request reachability root** (a guarantee, not
  just an optimization). Its generated scope-entry constructs the controller and,
  transitively, *only its own* request-scoped subgraph — a request routed to controller A
  never constructs a request-scoped binding that only B reaches. Precisions:
  - **Same seeded scope, per-controller-root construction.** If A and B share
    `RequestSeed` they're the *same scope by seed identity* (iteration-4 model), but
    per-request construction is rooted at the routed controller — the "separate graphs"
    are separate *construction sets*, reachability-scoped from each root, not separate
    scope types. A dependency both reach is built for whichever request arrived; no
    cross-construction, no double-identity.
  - **Singletons stay shared.** Per-root reachability is the request-scope layer only; app
    singletons are built once at bootstrap and injected into whichever controller.
  - This is the same reachability concept as **M6b** at a different layer (M6b prunes
    app-scope singletons at build time; this roots per-request construction) and, unlike
    M6b, isn't deferrable — it's structural to how the proxy generates scope entry (you
    build what the root needs; reachability is inherent, no separate pass).
- **Alignment with the proposal's request context.** The seed maps onto
  `swift-http-api-proposal`'s `HTTPServerCapability.RequestContext` — a **capability-typed,
  per-request context** where a handler/middleware constrains its generic to require a
  capability, compile-time-verified (the ecosystem-standard analogue of Wire's
  compile-time DI, and the same mechanism as the type-transforming-middleware property).
  Layering keeps the two from colliding: the transport delivers **one** `RequestContext`
  per request (carried through the middleware chain in the `Input` box); WireMVC **seeds
  its request scope from it**; per-controller reachability roots are a DI-scope layer
  *above* that single context. When the proposal ships, the seed can *be* the request
  context and capability requirements interop with the middleware type-thread.
- The shared **"adapter replaces the binding"** primitive (the same shape
  `@Configuration` needs — swap a binding for a synthesized provider) is built here and
  reused, not reinvented.
- App-scoped (`@Singleton`) and request-scoped (`@Scoped`) controllers coexist in one
  app; the user picks per-controller.

**Why now:** request scope is why WireMVC exists rather than staying Tier-1 native
controllers (M2's *Deferred to M5* reasoning: embedding scope entry needs routing Wire
*generates*). It builds directly on M5.1's generated witness and M5.3's typed
middleware.

**Validation gate:** `sessions` or `todos-auth-fluent` ports — a request-scoped
controller injects a request-scoped principal/session, constructed fresh per request,
with a `@Singleton` controller alongside in the same app.

## Iteration M5.5 — Tier-2 `@WireHummingbird` composition-root macro

The M2.6 deferral, un-gated now that the routing/middleware shape is settled.

**Scope:**
- The `@main @WireHummingbird` macro codifying `bootstrap → routerBuilder → apply →
  Application → run` — pure sugar over the working two-call `bootstrap()` + `apply()`
  path. It absorbs the request-scope proxy assembly (M5.4) and the **global-middleware
  application point**, which is exactly why it's built last: those settle the shape it
  codifies.
- **Global middleware is handled here, not in M5.3** — its defining property (pre-routing,
  unmatched-request coverage) belongs at the router-assembly layer. Three options were
  weighed; the plan commits to **(i) now, (iii) when forced, never (ii)**:
  - **(i) default — a framework concern.** The macro exposes the `routerBuilder` hook; the
    user calls `router.addMiddleware` themselves (constructing the middleware from the
    graph if it needs deps). Consistent with M2.4's shipped "middleware is app-owned"
    stance, zero new surface, ships immediately.
  - **(ii) rejected — a collated `[RouterMiddleware]` passed to the router.** Reintroduces
    exactly the context-typed-value problem M2.4 named a "hack in the wrong shape":
    `RouterMiddleware<Context>` pins the context, doesn't collate cleanly, isn't
    cross-runtime.
  - **(iii) the eventual cross-runtime path, when a use case forces it** — run a collated
    **context-free** middleware chain outside the router, preserving pre-routing coverage
    *and* cross-runtime. Two forms: a hand-rolled `HTTPResponder` (Hummingbird) /
    `ServerTransport` decorator as a **pre-proposal stopgap**, or — once the proposal ships
    — the **native** form, where the whole request path is one `Middleware` chain (global =
    outer stages, per-route stages + handler-as-terminal inside), no bespoke wrapper. This
    is where the shipped-but-unused `BuilderKey`→opaque-member fold and the
    standard-`Middleware` aggregation run. Deferred *not* because the type is one-way (it
    isn't — it threads a return and carries the response sender in `Input`) but because it's
    raw-transport-level and OS-26.2-gated; shape it against a real global-middleware-with-DI
    need (matching WireOpenAPI's "middlewares deferred to M5 shape" note).

**Why now:** the un-defer gate from M2.6 — "WireMVC's shape is known *and* the
native-middleware assembly is proven" — is met once M5.3/M5.4 land. Build it once,
against the settled shape.

**Validation gate:** an example's hand-written `main` collapses to the macro and serves
identically (same requests green before and after); a global middleware added via the
`routerBuilder` hook (option i) runs on an unmatched route.

## Iteration M5.6 — `WireMVCAbstraction.md` rewrite (doc debt)

**Scope:** rewrite [Notes/WireMVCAbstraction.md](Notes/WireMVCAbstraction.md) off the
retired `_wireRegister` / `WireMVCServer` model onto the collation / `ServerTransport` /
request-scoped-injection model this plan builds. Sweep incidental `_wireRegister`
mentions in `ScopeAndKeyModelEvolution.md`, `OpaqueTypesSupport.md`, `VisibilityModel.md`
if any survive. (M2's *Open decisions to pin* flagged this as M5 doc debt.)

**Why now:** the doc is stale the moment M5.1 ships; rewriting it against the *built*
model (not a predicted one) is cheaper and more accurate than rewriting speculatively.

**Validation gate:** the note describes only shipped M5 mechanisms; no `_wireRegister`
references remain in the WireMVC design surface.

## Cross-cutting concerns

### The example repo as the progressive gate

`wire-hummingbird-examples` (or a sibling of `wire-hummingbird`) ports
[hummingbird-examples](https://github.com/tachyonics/hummingbird-examples) one at a time
as each capability lands. **Keep the example *controllers* framework-agnostic** — only
the assembly/adapter is Hummingbird — or the examples quietly undercut the cross-framework
claim they exist to prove. The map:

| Gate | Examples that force it |
|---|---|
| **M5.1** app-scope + JSON | `hello`, `todos-dynamodb`, `todos-fluent`, `todos-postgres-tutorial`, `graphql-server` (one POST) |
| **M5.1+** content negotiation | `html-form`, `multipart-form` |
| **M5.2** raw escape hatch | `server-sent-events`, `response-body-processing`, `proxy-server`, `upload`/`upload-s3`/`s3-file-provider`, `websocket-chat`/`websocket-echo`, `http2` |
| **M5.3** pure-interception middleware | `open-telemetry` |
| **M5.3+M5.4** type-transforming middleware + request scope | the `auth-*` cluster (`auth-jwt`, `auth-cognito`, `auth-otp`, `auth-permissions`, `auth-srp`, `auth-abac`), `webauthn`, `sessions`, `todos-auth-fluent` |
| **Not a WireMVC gate** (different axis) | `jobs` (background work — scope/lifecycle) |

The `auth-*` cluster is the M5.3/M5.4 gate *because* it's where the type-threading has to
be real — you can't fake authenticated-principal-as-typed-value with a logging middleware.

### task-cluster

Stays the downstream validator against pushed swift-wire main. Its OpenAPI controller
(M3) is untouched; M5's forcing case is a *new* inline-routed endpoint (an internal admin
route), demonstrating WireMVC and WireOpenAPI **coexisting on one graph** — different
controllers, both contributing to `TransportKeys.handlers`, on the same transport.

## Open decisions to pin

- **Target protocol** (M5.0) — **decided: standardise on `some ServerTransport`** (route
  descriptors as the portability layer; `swift-http-api-proposal` server surface as the
  tracked successor behind the same witness seam). No longer open.
- **Dispatch model** (M5.0) — **decided: dynamic registration now**, static generated
  dispatch a deferred opt-in perf backend off the same route-descriptor table.
- **Raw-handler spelling** (M5.2) — explicit `@RawRoute` vs signature-detected opt-in.
- **Per-route middleware protocol** (M5.3) — the proposal's `Middleware<Input, NextInput>`
  is the ideal shape (forward-transform stages + handler-as-terminal; type-transformation
  as a compile error) but is raw-transport-level and OS-26.2-gated, so M5 uses a WireMVC
  *decoded* fold modeled on it over `ServerTransport`, adopting the proposal chain as
  substrate when it ships. Hummingbird's `RouterMiddleware` is incompatible (bidirectional,
  context-typed). Type-threading recommended regardless.
- **Global middleware** (M5.5) — committed to **(i) framework concern now, (iii)
  context-free responder/transport decorator when forced, never (ii) collated
  `RouterMiddleware`s**.
- **Response surface beyond `@JSONResponse`** — status/headers control, error→response
  mapping. Start narrow (status + JSON); grow only when an example forces it.

## When M5 is "done"

- `WireMVC` ships: `@Controller`/verb/param/`@JSONResponse` controllers generating
  `TransportContributor` witnesses onto `some ServerTransport`, cross-runtime by
  construction; `@Middleware` folded into the generated routing (type-transforming
  middleware surfacing as compile errors); the raw escape-hatch handler; request-scoped
  controllers; and the Tier-2 `@WireHummingbird` composition-root macro.
- Wire Core gains no new *contract* form — M5 rides the shipped
  graph-conformance emission, the `@Contributes` alias, and the (previously unused)
  `BuilderKey`→opaque-member fold; the one new *primitive* is the shared "adapter
  replaces the binding" mechanism (also serving `@Configuration`).
- The external **WireMVC repo** builds + serves against pushed swift-wire main on macOS
  and Linux (its own CI); the **example repo** ports through the M5.1–M5.4 gate set.
- task-cluster demonstrates WireMVC + WireOpenAPI coexisting on one graph/transport.
- `WireMVCAbstraction.md` is rewritten onto the collation model.
- No public 0.x tag yet — pre-alpha stays loud.
