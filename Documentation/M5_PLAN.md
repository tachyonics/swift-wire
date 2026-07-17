# M5 Implementation Plan — WireMVC

The implementation plan for M5: swift-wire's cross-framework declarative-routing
adapter, `WireMVC`. The milestone sits in [ROADMAP.md](../ROADMAP.md); the authoritative
record of the settled M5.0 decisions and annotation surface is
[Notes/WireMVCDesign.md](Notes/WireMVCDesign.md). The earlier design-space *exploration* is
[Notes/WireMVCAbstraction.md](Notes/WireMVCAbstraction.md) (superseded — still written
against the retired `_wireRegister` model; its rewrite is M5.6). Iterative, same discipline as
the archived [M1](Archive/M1_PLAN.md) and [M2](Archive/M2_PLAN.md) plans: each
iteration runs end-to-end and has a validation gate.

> **Update — proposal-native pivot (this plan is reconciled to it).** M5.0 committed to
> `some ServerTransport` (OpenAPIRuntime) as WireMVC's core target, naming the
> `swift-http-api-proposal` server surface a *tracked successor* behind the same seam.
> That successor is now the **core**, ahead of the planned timeline: deploying against
> macOS 26 makes `anyAppleOS 26.0` unconditional, so Wire's ungated generated code compiles
> against the proposal's server API today. WireMVC registers on `RoutableHTTPServerBuilder`
> (over the proposal's `HTTPServer`); `some ServerTransport` is **retained as an opt-in
> adapter** (`WireMVCServerTransport`, behind a `ServerTransport` package trait) so
> Hummingbird/Vapor mount the same controllers. Proven by
> [spike-12](../../swift-wire-spikes/spike-12-wiremvc-proposal-native/),
> [spike-13](../../swift-wire-spikes/spike-13-wiremvc-servertransport-bridge/), and
> [spike-14](../../swift-wire-spikes/spike-14-wiremvc-streaming/). Where sentences below still
> read "the target is `some ServerTransport`," take that as the adapter path; the load-bearing
> passages (the model paragraph, M5.0–M5.5, the open decisions) are updated inline.

**The headline:** WireMVC is a **spec-free, annotation-driven analogue of the OpenAPI
generator's registration codegen.** `@Controller`/`@Get`/`@Path`/`@JSONResponse` fold into a
Wire collation surface — `RouteContributor` / `WireMVCKeys.routeContributors` /
`RouteComposable` / `WireMVC.apply` — mirroring M3's `ServerTransport` collation shape but
with WireMVC's own key (the witness registers on `RoutableHTTPServerBuilder`, not
`transport.register`). Where WireOpenAPI's `TransportContributor` witness calls the
generator's `registerHandlers(on:)`, WireMVC's witness is a body Wire *generates* from the
annotations: decode path/query/body params from the raw request, call the handler, encode the
response. Because the target is the proposal's routing-surface protocol rather than any one
framework, the same controller serves natively on the proposal server and — through the
`WireMVCServerTransport` adapter — on Hummingbird, Vapor, or Lambda unchanged: cross-runtime
for free.

**Middleware needs no native-middleware router.** Because WireMVC owns the
route-registration codegen, controller- and route-scoped `@Middleware` are nested
wrappers around the generated handler closure. Composition is closure nesting; no
runtime router type exists. **Type-transforming middleware falls out as a compile
error** — the codegen threads each middleware's output type into the next stage's
input, so an auth middleware producing an authenticated principal a handler requires
either type-checks or fails at the generated seam. This retires the "native-middleware
router PoC" the M2 deferral parked.

**The escape hatch is a raw handler.** Anything WireMVC's typed core can't express —
streaming, SSE, proxying — falls into a catch-all route whose handler takes the proposal's
raw primitives (`consuming sending Reader` / `ResponseSender`, the exact `RoutableHTTPServerBuilder`
signature) and is registered verbatim, skipping decode/encode. Middleware can still wrap it.
One catch-all, not a growing list of special-case annotations.
[spike-14](../../swift-wire-spikes/spike-14-wiremvc-streaming/) proves SSE streams through it
end-to-end — natively *and* through the `ServerTransport` adapter with real backpressure — so
streaming needs no framework-specific adapter. **WebSocket is the exception:** an upgrade
isn't a response body, so it's escape-to-framework (registered directly on the framework, with
WireMVC coexisting), not a WireMVC route — see the scope boundary.

## How to use this plan

- Each iteration has a *scope*, a *why-now*, and a *validation gate*. Don't move on
  until the gate passes.
- **Highest-risk first** (M1/M2 philosophy): the riskiest seam is **M5.0's target
  decision + the generated `RouteContributor` witness body** (param decode / call /
  encode against `RoutableHTTPServerBuilder`'s `~Copyable` reader/sender). Everything else
  layers on it. Middleware
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

- **The collation surface *shape*** — M3 shipped `TransportContributor`,
  `TransportKeys.handlers = CollectedKey<any TransportContributor>`, `TransportComposable`,
  and `apply(graph, to: transport)`. WireMVC reuses this *shape* with its **own key**:
  `RouteContributor`, `WireMVCKeys.routeContributors = CollectedKey<any RouteContributor>`,
  `RouteComposable`, and `WireMVC.apply(graph, to: &builder)`. A separate key (not a re-home
  into `TransportKeys.handlers`) because the witness registers on `RoutableHTTPServerBuilder`,
  not `some ServerTransport` — a different witness shape. Both keys still collate on one graph.
  See [Notes/WireOpenAPIDesign.md](Notes/WireOpenAPIDesign.md).
- **The `@Contributes`-alias adapter contract** — a `WireAdapterAnnotationV1` aliasing
  `@Controller` to `@Contributes(to: WireMVCKeys.routeContributors)`, mirroring
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
escape hatch (M5.2):** streaming responses, server-sent events, and proxying (all still
request→response, so the raw `RoutableHTTPServerBuilder` handler carries them — proven by
[spike-14](../../swift-wire-spikes/spike-14-wiremvc-streaming/)). **WebSocket upgrades are
neither typed-core nor raw-handler:** an upgrade isn't a request→response body, so it's
escape-to-framework (registered on the framework directly, WireMVC coexisting), not a WireMVC
route — the only case that could ever justify a framework-specific adapter. Explicitly **not
M5 at all:**

- **Background/scheduled work** (`jobs`-style) — a scope/lifecycle axis, not routing.
  Not a WireMVC gate.
- **Content negotiation beyond JSON + form/multipart decode** — a narrow
  encoder/decoder hook is in M5.1's scope; pluggable multi-format negotiation is
  post-1.0 unless an example forces it.
- **Framework-specific adapters (`WireHummingbird` / `WireVapor`)** — the cross-runtime
  property is *structural* (the target is the proposal routing surface, reached natively or
  through the one generic `WireMVCServerTransport` bridge), so a framework-specific adapter
  proves nothing new about portability (same reasoning that skipped M3.4). It could only ever
  be a *performance* play — collapsing the bridge's extra hop/copies, or reaching a framework's
  native WebSocket upgrade — and is deferred as an optimization gated on real numbers, not a
  correctness need. Follows post-M5 only if profiling or a WebSocket-in-WireMVC use case forces
  it.

## The model in one paragraph

A `@Controller("/tasks")` type is a **route contributor**: the plugin injects
`@Contributes(to: WireMVCKeys.routeContributors)` (the alias), and the macro generates a
`RouteContributor` conformance whose `registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on:)`
witness, for each `@Get`/`@Post`/… member, calls `builder.register(method:path:handler:)` with a
closure that (a) decodes the member's `@Path`/`@Query`/`@Body`/`@Header` params from the raw
request, (b) applies the route's and controller's `@Middleware` layers as nested wrappers,
(c) calls the handler, and (d) encodes the return via `@JSONResponse` (status + body) onto the
proposal's response sender. The controller is constructed from the graph (lift-the-minimum,
shipped) and collated exactly like an OpenAPI controller — `Wire.bootstrap()` returns the
concrete graph, which conforms to `RouteComposable`, and `WireMVC.apply(graph, to: &builder)`
registers the collated routes onto a user-owned `RoutableHTTPServerBuilder` (a Router over the
proposal's `HTTPServer`) that stays *outside* the graph. On a `ServerTransport` framework
(Hummingbird/Vapor) the assembly instead calls `WireMVCServerTransport.apply(graph, to: transport)`
— the opt-in adapter — with everything else identical. Global middleware is a **Tier-2 concern**
(M5.5), applied at the router-assembly layer — not folded per-route — so it keeps its
pre-routing / unmatched-request coverage. A `@Scoped(seed:)` controller (M5.4) becomes an
app-scoped proxy contributor whose generated witness embeds per-request scope entry, **rooted
per-controller by reachability**. A raw handler (M5.2) skips (a) and (d) and drives the
proposal reader/sender verbatim.

## Iteration M5.0 — pin the target protocol + annotation surface (design gate) — ✅ COMPLETE

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

  **Original decision (M5.0): standardise on `some ServerTransport`** — the proven Swift
  shape (swift-openapi-generator targets exactly it), cross-runtime for free, already Wire's
  shipped collation primitive, dispatch-agnostic — with the route-descriptor table as the
  portability layer and the `swift-http-api-proposal` server surface named the *tracked
  successor* behind the same seam.

  **Reconciled decision: standardise on the proposal server surface now; keep `ServerTransport`
  as an opt-in adapter.** The tracked successor arrived early. Deploying against macOS 26 makes
  `anyAppleOS 26.0` unconditional, so Wire's ungated generated code compiles against the
  proposal's server API today — there's no reason to route the core through OpenAPIRuntime and
  wait. WireMVC registers on **`RoutableHTTPServerBuilder`** (a per-route surface over the
  proposal's `HTTPServer`); the route-descriptor table stays the portability layer, so the
  registration backend is still swappable. `some ServerTransport` is **retained behind a
  `ServerTransport` package trait** as `WireMVCServerTransport`, bridging the same controllers
  onto Hummingbird/Vapor. This **resolves** the OpenAPI-branded-dependency cost rather than
  accepting it: the core depends only on `swift-http-api-proposal`; OpenAPIRuntime is a
  dependency of the opt-in adapter alone. Proven by
  [spike-12](../../swift-wire-spikes/spike-12-wiremvc-proposal-native/) (native routing over
  `HTTPServer.serve`), [spike-13](../../swift-wire-spikes/spike-13-wiremvc-servertransport-bridge/)
  (the bridge), and [spike-14](../../swift-wire-spikes/spike-14-wiremvc-streaming/) (streaming
  through both).
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
[Notes/WireMVCDesign.md](Notes/WireMVCDesign.md) (target `RoutableHTTPServerBuilder` over the
proposal server, `ServerTransport` as an opt-in adapter; dynamic dispatch with the
route-descriptor table as portability layer; the `@Controller` / `@Get…` /
`@Path`·`@Query`·`@JSONBody`·`@Header` / `@JSONResponse` / `@ResponseStatus` surface;
`@JSONBody` content-type rules). Four spikes prove the target:
[spike-11](../../swift-wire-spikes/spike-11-wiremvc-servertransport/) hand-writes the decoded
witness and serves all six surface behaviors in-process (`@Path` decode, `@JSONBody`
415/422/lenient, `@JSONResponse(status:)`, `@ResponseStatus(.noContent)` → 204) — establishing
the decode/encode/status logic; [spike-12](../../swift-wire-spikes/spike-12-wiremvc-proposal-native/)
moves the registration target to `builder.register` and serves on a real `NIOHTTPServer`;
[spike-13](../../swift-wire-spikes/spike-13-wiremvc-servertransport-bridge/) drives the same
witness through `some ServerTransport` (the retained adapter); and
[spike-14](../../swift-wire-spikes/spike-14-wiremvc-streaming/) streams SSE through both. So
M5.1 codegen has a validated proposal-native target to emit against, and the `ServerTransport`
adapter has a validated bridge.

## Iteration M5.1 — app-scope controllers, JSON in/out, no middleware — ✅ COMPLETE

> **Status: shipped** — the typed core serves in `wire-mvc` + `wire-mvc-examples` (proposal-server,
> Hummingbird, and Vapor runtimes).

The core codegen. App-scoped only, no middleware, typed handlers.

**Scope:**
- `@Controller` macro + `@Contributes(to: WireMVCKeys.routeContributors)` alias.
- Generate the `RouteContributor` conformance: its `registerWireRoutes<Builder>` witness, per
  verb-annotated member, calls `builder.register(method:path:handler:)` with a closure that
  decodes `@Path`/`@Query`/`@Body`/`@Header` params, calls the handler, and encodes the
  `@JSONResponse` return (status + JSON body) onto the proposal response sender. Route paths
  compose the controller prefix with the member subpath; `@Path` names must match `{name}`
  placeholders (validated). The `~Copyable` inverse requirements on the builder's associated
  types are restated at the generic boundary (they don't propagate — see spike-12).
- A narrow JSON encoder/decoder hook (JSON in / JSON out) — the one content form the
  core commits to.
- Controller construction via lift-the-minimum (shipped); collation + `apply` reuse the M3
  collation *shape* on WireMVC's own `RouteComposable` / `WireMVCKeys.routeContributors`.

**Why now:** this is the milestone's spine — everything else (middleware, request scope,
the Tier-2 macro) wraps or assembles this. Highest-risk-first.

**Validation gate:** the harness serves a decoded GET/POST round-trip; `hello` and a
`todos`-style example port onto WireMVC and serve in-process. **Cross-runtime demonstration:**
the *same* controllers serve **(a) natively on the proposal server** (a Router conforming to
`RoutableHTTPServerBuilder` over `NIOHTTPServer`) **and (b) on Hummingbird and Vapor** through
the `WireMVCServerTransport` adapter (`swift-openapi-hummingbird` / `swift-openapi-vapor`
providing the `Router`/`VaporTransport: ServerTransport` conformances — the OpenAPI generator
isn't involved). This is a **content/demonstration** asset, *not* added verification:
cross-runtime is *structural* (the target is the proposal routing surface), so — consistent
with the M3.4 skip — a second live runtime doesn't make the property truer, it shows it. This
is already realised in the `wire-mvc-examples` repo (a proposal-server runtime plus Hummingbird
and Vapor runtimes on the adapter), which stands in for the earlier "successor-bridge spike":
the bridge onto the proposal server surface is no longer a future de-risking exercise but the
shipped core.

## Iteration M5.2 — the raw escape-hatch handler — ✅ COMPLETE

> **Status: shipped** — `@RawRoute` with *generic* role identification serves plain streaming
> (the `events` SSE handler). The *concrete* transformed-slot roles are pulled out to **M5.4R**
> below (a conditional follow-on), so this iteration's committed scope is done.

The catch-all, before middleware — so streaming examples have a home and middleware
(M5.3) can be designed to wrap both typed and raw handlers uniformly.

**Scope:**
- A raw route form whose handler takes the proposal's raw primitives — the
  `RoutableHTTPServerBuilder` handler signature itself (`HTTPRequest`, path parameters,
  `consuming sending Reader`, `consuming sending ResponseSender`) — and is registered verbatim,
  no param decode, no response encode. Because that signature is *already* what the builder
  hands every closure, the raw handler is the typed core's own shape with decode/encode
  skipped; M5.2 is a **macro spelling**, not a new runtime path. **Spelling pinned: `@RawRoute`**
  — a func-level marker that is greppable, stands in for the "one response annotation per route"
  invariant, and flips param binding to type-identification (raw params by type, typed params
  keep their annotations). The full model — a raw handler as a *projection of the box's raw
  slots*, unified with the typed core and with middleware — is in
  [Notes/WireMVCMiddleware.md](Notes/WireMVCMiddleware.md).
- The generated witness registers the raw closure directly; middleware wrapping (M5.3)
  still composes around it. The `WireMVCServerTransport` adapter must carry the raw stream too
  — its response sender streams into the `ServerTransport` `HTTPBody` rather than collecting
  (spike-14 built exactly this; today's shipped adapter still buffers and needs that path).

**Why now:** it bounds the typed core. Without it, every streaming/SSE/WebSocket example
would pressure the core to grow special cases; with it, the core stays typed-only and the
hard cases have one uniform exit.

**Validation gate:** an SSE or streaming example (`server-sent-events`,
`response-body-processing`) ports via the raw handler and streams a response in-process — on
the proposal server *and* through the `ServerTransport` adapter.
[spike-14](../../swift-wire-spikes/spike-14-wiremvc-streaming/) already discharges the shape
(a raw SSE handler streaming both ways, with real backpressure); the gate is met once the
macro spelling and the adapter's streaming path land. **Not this gate:** `websocket-*`
(escape-to-framework — see scope boundary) and `http2` (a transport concern, not a WireMVC
route form).

## Iteration M5.3 — middleware, folded into codegen — ✅ COMPLETE

> **Status: shipped** — controller/route middleware and all three forms (concrete, generic
> dep-free, and the generic-with-deps `@Factory`/`@MiddlewareFactory` tier) serve in `wire-mvc`;
> the codegen-foundation move that this rests on is archived in
> [Archive/WireMVCCodegen.md](Archive/WireMVCCodegen.md).

Controller- and route-scoped middleware as nested wrappers; the standard
`Middleware<Input, NextInput>` type; type-threading.

> **Settled — see [Notes/WireMVCMiddleware.md](Notes/WireMVCMiddleware.md).** A WireMVC middleware
> *is* the proposal's `Middleware` **and** a Wire component; `@Middleware(T.self)` references it
> from the graph. Each route's chain is a per-route `MiddlewareBuilder` fold whose final box type
> the compiler infers; the terminal projects the handler's params off that box (`withContents`),
> and the "remove the middleware ⇒ won't compile" guarantee is the compiler's, from the
> projection type-check — not asserted by the macro. The plugin generates the capability
> *forwarding* conformances for the specialisations the folds surface. Concrete and
> generic-dep-free middleware rest on generic `@Provides` factories with no Core change. The fold is
> **witness-local concrete** codegen, *not* a `BuilderKey`/opaque fold —
> [spike-15](../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/) found the opaque
> graph-binding form isn't expressible (`Middleware` can't partial-bind its two primary associated
> types), so there is nothing opaque to build. The one Core-codegen item the design reduces to is
> the **generic-with-deps** tier: the middleware is declared `@Factory(key) @MiddlewareFactory` and
> referenced `@Middleware(key)`; the plugin synthesises one factory per consumed key — generic over
> the *injected* axis (threaded by ordinary graph specialisation) with a `create` generic over the
> *assisted* box roles (metatype parameters) — and injects it onto the controller via the consumer-side
> `.injectsFactoryOnArgument` capability, *not* a graph back-reference. See
> [Notes/WireMVCMiddleware.md](Notes/WireMVCMiddleware.md), *Generic middleware: the `@Factory`
> template + `@MiddlewareFactory` mapping*. The derivation below records how each decision was reached.

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
  over `RoutableHTTPServerBuilder` (M5.0) now; the proposal's `Middleware`/`HTTPAPIs` are
  already the core's direct dependency, but `Middleware` is `@available(…26.2)` above the
  core's `26.0` floor, so it stays the **substrate under** the decoded layer (adopted per-route
  *and* global once the deployment floor reaches it), not a replacement. The
  god-object-critique differentiator holds either way.
- Validate `@Middleware` exprs against WireMVC's chosen middleware protocol; a
  type-thread mismatch gets a diagnostic that names the producing middleware, the
  expected input, and the offending stage.

**Why now:** middleware is the first thing that makes the codegen more than a
route-registration convenience. It precedes request scope only nominally — see M5.4.
(The per-route chain is a **witness-local concrete** fold, not the `BuilderKey`→opaque-member fold —
[spike-15](../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/) found the opaque form
isn't expressible for `Middleware` and isn't needed here; see
[Notes/WireMVCMiddleware.md](Notes/WireMVCMiddleware.md), *What this rests on*. The `BuilderKey`
opaque/erased fold remains relevant only to M5.5's *global* context-free aggregation.)

**Validation gate:** `open-telemetry` ports (pure-interception tracing,
`Input == NextInput`). The *type-transforming* property is proven at the **type level** by
[spike-15](../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/) /
[spike-21](../../swift-wire-spikes/spike-21-wiremvc-transforming-rawroute/) (a middleware
transforming the box — `Box<Ctx>` → `Box<AuthCtx>` — read by a *raw* terminal off the final
box), **not** by a typed handler projecting a middleware-produced value off its parameters:
the shipped terminal discards the `RequestContext` (`contextName: "_"`), so **handler-parameter
projection ("B-typed") is not a shipped mechanism** — see the M5.4 decision below. The `auth-*`
cluster's real gate is **M5.4**, where the principal is a request-scoped *injected* value
(A-inject) and "remove the producer ⇒ won't compile" holds at the scope-entry/graph seam.

## Remaining work (in completion order)

M5.0–M5.3 are shipped (above). The iterations below are the remaining work, top-to-bottom in
completion order: **M5.4** is next; **M5.4E** interleaves with it (not a later step); **M5.4R** is
a conditional raw-track follow-on that lands when a transformed-slot example forces it; then
**M5.5** and **M5.6**. The `E`/`R` suffixes mark items that hang off the M5.4 phase rather than
being sequential milestones with their own gate-between.

## Iteration M5.4 — request-scoped controllers — ▶ NEXT

> **Build plan: [M5_4_PLAN.md](M5_4_PLAN.md)** — the sub-step breakdown (M5.4.1–M5.4.6), the
> shipped shapes it embeds into, and the central mechanism decision (the injected scope-entry
> thunk that replaces the design-text's weak back-reference, since the shipped `_WireGraph` is a
> value type). This section carries the *why*; that file carries the *how*.

Interleaved with M5.3 in practice — auth *identity* is the canonical request-scoped
value a type-transforming middleware produces and a request-scoped controller consumes.

**How a middleware-produced / request-scoped value reaches a handler — decided: A-inject
(request-scope injection), not B-typed (handler-parameter projection).** Three positions were
weighed against the auth cluster:
- **A-inject** — a `@Scoped(seed:)` controller `@Inject`s the value (principal, session) as an
  ordinary request-scoped binding built from the seed; the handler reads `self.principal`.
  **Committed** — it covers the whole `auth-*`/`sessions`/`todos-auth-fluent` set.
- **B-raw** — a `@RawRoute` handler takes a transformed box slot (context/reader/sender) by its
  *generic* type. Works today for plain slots; the *concrete* spelling is a deferred M5.2 follow-on.
- **B-typed** — a typed handler declares `@Principal user: User` and the terminal decomposes the
  enriched box. **Retired from M5's committed scope** — the shipped terminal discards the
  `RequestContext`, and building it is the full decomposition-transformer subsystem
  ([Notes/DecompositionTransformers.md](Notes/DecompositionTransformers.md)), which nothing in the
  auth cluster forces.

The **"remove the producer ⇒ won't compile"** guarantee is **not lost** under A-inject, it
**relocates**: the handler requires the request-scoped binding, so removing its producer — or,
when the scope is seeded from an enriched context, the middleware that produces that context —
fails at the scope-entry / graph-validation seam, build-time as before. **Auth-failure division
of labor** (settled with the route-error-handling iteration): gates/middleware own *pre-handler
policy* failures (401/403) by *writing* the response and short-circuiting to `.responded` before
the terminal constructs the request scope; handler-thrown *domain* errors (404/409/422) are mapped
by the terminal error map. One producer per status, no overlap.

**Scope:**
- A `@Scoped(seed: RequestSeed.self)` controller becomes an **app-scoped proxy
  contributor** whose *generated* `registerWireRoutes` embeds per-request scope entry
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
  Layering keeps the two from colliding: the server delivers **one** `RequestContext`
  per request (carried through the middleware chain in the `Input` box); WireMVC **seeds
  its request scope from it**; per-controller reachability roots are a DI-scope layer
  *above* that single context. This is now concrete, not prospective: `RoutableHTTPServerBuilder`
  already carries `associatedtype RequestContext: HTTPServerCapability.RequestContext`, so the
  seed maps onto the builder's request context directly and capability requirements interop
  with the middleware type-thread.
- The shared **"adapter replaces the binding"** primitive (the same shape
  `@Configuration` needs — swap a binding for a synthesized provider) is built here and
  reused, not reinvented.
- App-scoped (`@Singleton`) and request-scoped (`@Scoped`) controllers coexist in one
  app; the user picks per-controller.

**Why now:** request scope is why WireMVC exists rather than staying Tier-1 native
controllers (M2's *Deferred to M5* reasoning: embedding scope entry needs routing Wire
*generates*). It builds directly on M5.1's generated witness and M5.3's typed
middleware.

**Validation gate:** `sessions` or `todos-auth-fluent` ports on **A-inject** — a request-scoped
controller injects a request-scoped principal/session, constructed fresh per request, with a
`@Singleton` controller alongside in the same app; auth failures return 401/403 from a gate, and a
domain failure (a missing record) returns 404 via the terminal error map (route-error-handling
iteration, interleaved).

## Iteration M5.4E — route error handling (interleaved with M5.4)

New in this plan; resolves the "Response surface beyond `@JSONResponse`" open decision below.
Interleaved with M5.4 because the auth/CRUD examples that gate M5.4 throw domain errors that must
map to real statuses — the shipped terminal catches only `WireMVCBindingError`, so every other
throw is a 500 today (`getUser`'s `try store.find(id)` already returns 500, not 404, for a missing
id). Full design record: [Notes/RouteErrorHandling.md](Notes/RouteErrorHandling.md).

**Scope:**
- **Terminal-scoped, not global.** Error→response mapping lives at the **terminal**, because that
  is the only place still holding the sender when the handler throws: an outer middleware has
  already consumed the box (and its sender) into `next`, so it can *observe* a throw but cannot
  write a response to it. This is a *consequence* of the Model-B box shape — the same root as the
  short-circuit model, not a separate choice.
- **`@ErrorMap` at controller and route scope**, composed controller-outer → route-inner
  (most-specific wins), consulted inside the terminal's existing `catch` — extending the shipped
  `WireMVCBindingError` → status path, not a new runtime layer.
- **The global sliver is thin:** an unmapped throw propagates out of the chain to the
  router/server default (500). A default error map is the outermost tier, *not* a global
  middleware (which structurally can't respond to a throw).
- **Scope boundary — raw handlers own their errors.** Once a raw handler starts streaming the
  response is committed (the box's no-post-processing property), so a mid-stream throw can't be
  remapped. Error maps are a typed-terminal concern.

**Why now:** forced by M5.4's own gate (a `todos-auth` port returning 500 for a missing todo isn't
a faithful port), and its design settles the auth-failure division of labor M5.4 depends on. It
extends shipped M5.1 terminal codegen, so it does **not** wait on M5.5.

**Validation gate:** a handler throwing a domain error (`NotFound` → 404, a validation error → 422)
returns the mapped status; a controller-scope `@ErrorMap` covers every route and a route-scope one
overrides it for a single route; an unmapped throw still reaches the router's 500.

## Iteration M5.4R — concrete `@RawRoute` roles (raw-track follow-on, when forced)

A contained follow-on to M5.2, positioned here because it lands *after* M5.4 — when the first
transformed-slot streaming example is ported — not on the M5.4→M5.5 spine. Pulled out of M5.2 (now
complete) so a shipped iteration doesn't carry unbuilt work.

**Scope:**
- The shipped raw handler identifies its context/reader/sender by *generic* constraint substring
  (`rawGenericRoles`), so a **concrete** transformed slot — `responseSender: consuming
  JsonMultiPartSender` off a sender-transforming middleware — falls through to
  `unsupportedRawParameter`. The generic form is a poor substitute: it forces the middleware author
  to hoist the whole capability into a refinement protocol, and there is **no `as?` rescue for a
  `consuming` `~Copyable` value**, so anything the protocol didn't surface is unreachable.
- The fix is **explicit positional roles** — `@RawRoute(.requestContext, .responseSender)` — a
  contained feature in the `@MiddlewareFactory` mould, separable from the full
  decomposition-transformer subsystem, that also restores a compile-time coupling (naming the
  concrete sender forces the producing middleware present). Full record:
  [Notes/DecompositionTransformers.md](Notes/DecompositionTransformers.md) (item 1c).

**Why now (conditional):** a transformed-slot example (`response-body-processing` multipart,
`proxy-server`) effectively *demands* the concrete spelling, so this lands **with** that example. It
is independent of M5.5 (the composition macro doesn't depend on it), so it can slot in whenever the
transformed-streaming examples are prioritised.

**Validation gate:** a `response-body-processing`/multipart example ports with a handler taking a
concrete transformed sender (`consuming JsonMultiPartSender`) via `@RawRoute(.responseSender)`, and
removing the sender-transforming middleware fails to compile at the handler.

## Iteration M5.5 — Tier-2 `@WireHummingbird` composition-root macro

The M2.6 deferral, un-gated now that the routing/middleware shape is settled.

**Scope:**
- The `@main @WireHummingbird` macro codifying `bootstrap → router → WireMVCServerTransport.apply →
  Application → run` — pure sugar over the working two-call `bootstrap()` + `apply()` path
  (Hummingbird reaches WireMVC through the `ServerTransport` adapter). A sibling proposal-server
  composition root is thinner still — `bootstrap → RoutableHTTPServerBuilder → WireMVC.apply →
  serve(on:)`, no framework `Application`. Either macro absorbs the request-scope proxy assembly
  (M5.4) and the **global-middleware application point**, which is exactly why it's built last:
  those settle the shape it codifies.
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
controllers contributing to *different* collated keys (`WireMVCKeys.routeContributors` and
`TransportKeys.handlers`), both applied to the same runtime. On a `ServerTransport` framework
that means both land on one transport (WireOpenAPI directly, WireMVC via
`WireMVCServerTransport.apply`); on the proposal server, WireMVC applies natively while a
transport-only contributor mounts through its own adapter.

## Open decisions to pin

- **Target protocol** (M5.0) — **decided (reconciled): standardise on `RoutableHTTPServerBuilder`
  over the proposal server**, with `some ServerTransport` retained as the opt-in
  `WireMVCServerTransport` adapter (behind a `ServerTransport` trait). Route descriptors stay
  the portability layer. The original `some ServerTransport` core decision was inverted once
  macOS-26 deployment made the proposal server usable now; the core no longer depends on
  OpenAPIRuntime. No longer open.
- **Dispatch model** (M5.0) — **decided: dynamic registration now**, static generated
  dispatch a deferred opt-in perf backend off the same route-descriptor table.
- **Raw-handler spelling** (M5.2) — **decided: `@RawRoute`** (func-level marker; raw params
  type-identified, typed params annotated). See [Notes/WireMVCMiddleware.md](Notes/WireMVCMiddleware.md).
- **Per-route middleware protocol** (M5.3) — **decided: the proposal's `Middleware<Input, NextInput>`
  itself**, composed as a per-route `MiddlewareBuilder` fold whose final box the compiler infers;
  the terminal projects handler params off the box via `withContents`, and the type-transformation
  compile-error property is the compiler's (the projection type-check). The plugin generates
  capability forwarding for the specialisations the folds surface. The fold is **witness-local
  concrete** codegen (spike-15): the opaque `BuilderKey` graph-binding fold isn't expressible for
  `Middleware` (two primary associated types can't partial-bind), so nothing opaque is built. The
  one Core-codegen item is the **generic-with-deps** tier: declared `@Factory(key) @MiddlewareFactory`,
  referenced `@Middleware(key)`, the plugin synthesises one factory per consumed key (generic over the
  injected axis, `create` metatypes over the box roles) and injects it via `.injectsFactoryOnArgument`
  — not a back-reference; concrete and generic-dep-free middleware work today. `Middleware` is `26.2`-gated
  above the core's `26.0` floor, so per-route middleware lands when the deployment floor reaches it.
  Hummingbird's `RouterMiddleware` is incompatible (bidirectional, context-typed). Full record:
  [Notes/WireMVCMiddleware.md](Notes/WireMVCMiddleware.md).
- **Global middleware** (M5.5) — committed to **(i) framework concern now, (iii)
  context-free responder/transport decorator when forced, never (ii) collated
  `RouterMiddleware`s**.
- **Response surface beyond `@JSONResponse`** — status/headers control, error→response mapping.
  **error→response mapping decided: terminal-scoped `@ErrorMap` at controller/route scope**
  (iteration M5.4E, interleaved with M5.4), with a thin default/router-500 global sliver, *not*
  global middleware — see [Notes/RouteErrorHandling.md](Notes/RouteErrorHandling.md).
  Status/headers control stays narrow (status + JSON); grow only when an example forces it.

## When M5 is "done"

- `WireMVC` ships: `@Controller`/verb/param/`@JSONResponse` controllers generating
  `RouteContributor` witnesses onto `RoutableHTTPServerBuilder` (the proposal server surface),
  cross-runtime by construction — natively on the proposal server and, through the opt-in
  `WireMVCServerTransport` adapter, on Hummingbird/Vapor; `@Middleware` folded into the
  generated routing (type-transforming middleware surfacing as compile errors); the raw
  escape-hatch handler; request-scoped controllers; the Tier-2 `@WireHummingbird`
  composition-root macro; and terminal-scoped `@ErrorMap` route error handling. Request-scoped
  controllers consume middleware-produced values via **A-inject** (request-scope injection);
  handler-parameter projection off an enriched box (**B-typed**) and the general
  decomposition-transformer surface (`@Configuration`, pluggable bindings) are **deferred** — see
  [Notes/DecompositionTransformers.md](Notes/DecompositionTransformers.md); the contained
  **concrete `@RawRoute` role** slice lands with the first transformed-slot streaming example.
- Wire Core's adapter contract gains a capability axis — `WireAdapterAnnotationV1`'s
  unified `capability:` adds two **input-edge** cases alongside the shipped
  `.contributes(to:)` **output-edge** case: `.injectsDependencyOnArgument` (inject an
  existing binding by type — Increment 1) and `.injectsFactoryOnArgument` (synthesise a `@Factory`
  template and inject it, the capability `@Middleware` declares — Increment 2), plus the
  reserved `.rewritesInjection`. Otherwise M5 rides shipped machinery — graph-conformance
  emission, the `@Contributes` alias, the `BuilderKey`→opaque-member fold — plus the factory
  synthesis the factory edge carries: a native `@Factory(key)`/`FactoryKey` plus WireMVC's
  `@MiddlewareFactory` role mapping, whose *injected* axis reuses demand-driven generic
  specialisation and whose *assisted* box-role axis is the one new `create`-metatype codegen. The
  shared "adapter replaces the binding" primitive is reserved for M5.4's request scope (also serving
  `@Configuration`).
- The external **WireMVC repo** builds + serves against pushed swift-wire main on macOS
  and Linux (its own CI); the **example repo** ports through the M5.1–M5.4 gate set.
- task-cluster demonstrates WireMVC + WireOpenAPI coexisting on one graph/transport.
- `WireMVCAbstraction.md` is rewritten onto the collation model.
- No public 0.x tag yet — pre-alpha stays loud.
