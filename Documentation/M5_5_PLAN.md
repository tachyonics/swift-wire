# M5.5 — the WireMVC-native composition root (`@WireMVCBootstrap`)

> **Status:** Phases 1–4 shipped; Phase 5 (global `@Middleware`) designed, not yet implemented.
> Iteration **M5.5** in
> [M5_PLAN.md](M5_PLAN.md); this file is the detailed plan (same relation M5_4_PLAN.md has to
> M5.4). Rests on M5.1–M5.4E/M5.4R (shipped). Depends on the error model in
> [Notes/LinearSenderErrorModel.md](Notes/LinearSenderErrorModel.md) and the `@ErrorResponse`
> surface in [Notes/RouteErrorHandling.md](Notes/RouteErrorHandling.md).

## Rescope

M5.5 was framed as an `@WireHummingbird` composition-root macro. **That framing is
retired.** The Hummingbird and Vapor integrations are idiomatic *in their own ecosystems* —
you use their `Application`/`@main`, and their own middleware owns global concerns. A macro
there fights the grain. M5.5 is now the **WireMVC-native bootstrap**: the proposal-server
path where WireMVC owns the composition root, and therefore the one place that needs a home
for global middleware, default error handling, and introspection mounting.

## The model in one paragraph

`@WireMVCBootstrap` marks a **graph-constructed composition root** — a struct whose `@Inject`
properties resolve from the graph and whose factory methods build the concrete server and
router — and generates `@main`. Its global `@Middleware` and `@ErrorResponse` become a single
**global tier folded onto the same per-route fold** ([WireMVCMiddleware.md](Notes/WireMVCMiddleware.md)),
applied identically to real routes and to the **`@NotFound` fallback handler** that owns the
unmatched-request case. The result is a clean invariant: **the router is pure dispatch, and
every response comes from a route that holds the sender** — a real match, or the fallback.
Nothing responds without holding the sender, so the whole surface stays inside the
linear-sender box model with no new response machinery.

## The surface

```swift
@Singleton                                            // required — makes it a graph binding
@WireMVCBootstrap                                     // marker; the @main entry is *generated*, not written
@Middleware(GlobalMiddleware.requestLogging)          // global tier — outermost middleware (Phase 5)
@Middleware(GlobalMiddleware.cors)
@ErrorResponse(NotFound.self, .notFound)              // global tier — default error map (Phase 3)
@ErrorResponse({ (e: Swift.Error) in .status(.internalServerError) })
struct Bootstrap {
    @Inject let config: ServerConfig                  // resolved from the graph

    func createServer() throws -> NIOHTTPServer {     // the CONCRETE server — see note
        NIOHTTPServer(logger: Logger(label: "app"), configuration: try .init(
            bindTarget: .hostAndPort(host: config.host, port: config.port),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext))
    }

    func createRoutableBuilder<Server: HTTPServer>(   // generic over the server it is handed
        for server: borrowing Server
    ) -> some ServableRoutableHTTPServerBuilder<Server.RequestContext, Server.Reader, Server.ResponseSender>
    where
        Server.RequestContext: ~Copyable, Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable, Server.ResponseSender.Writer: ~Copyable
    {
        TrieRouteBuilder(for: server)                 // WireMVCRouter — build → freeze → serve
    }

    // Optional pre-router seam (default identity). Home for routing-affecting logic —
    // path rewrite / normalization / method-override — which runs BEFORE the match.
    func wrapHandler<H: HTTPServerRequestHandler>(_ router: consuming H)
        -> some HTTPServerRequestHandler<H.RequestContext, H.Reader, H.ResponseSender> { router }

    @Middleware(IntrospectionMiddleware.admin)        // guards the introspection route
    func mountIntrospectionAt() -> String? { "/wiring" }
}
```

Refinements (some **corrected during Phase 1 implementation**):

- **`createServer` returns the *concrete* server, not `some HTTPServer`.** The proposal's
  `Reader`/`ResponseSender` are `~Copyable`, and a bare `some HTTPServer` opaque return can't
  express that — it forces the associated types `Copyable` (a real compile error). So the factory
  returns e.g. `NIOHTTPServer`; the generated `main()` binds to whatever concrete type it returns.
- **`createRoutableBuilder(for:)` returns `some ServableRoutableHTTPServerBuilder<…>`** — the
  native-path refinement of the core builder (adds `finalize() -> some HTTPServerRequestHandler`),
  restating the `~Copyable` requirements on `Server`'s associated types (they don't propagate — same
  as `WireMVC.apply`). The **build → freeze → serve** lifecycle: `WireMVC.apply` registers routes onto
  the mutable builder; the generated `main()` `finalize()`s it into the immutable handler the server
  serves. `finalize()` is on the *refinement*, not the router-agnostic core, because the
  `ServerTransport` adapter's builder conforms to the core but doesn't serve via
  `HTTPServerRequestHandler`. `WireMVCRouter`'s `TrieRouteBuilder` (a segment trie, ported from
  `wire-mvc-examples`) is what the native path returns; it's generic over the server it receives.
- **`@Singleton` is required, `@main` is generated.** No swift-wire capability makes a type a
  binding on its own, so `@WireMVCBootstrap` rides `@Singleton` (as `@Singleton @Controller` does);
  the `@main` entry (`_WireMVCBootstrapEntry`) is emitted by `WireMVCRouteGen`, reading the binding
  as `graph.<lowerCamelType>` and serving via the `WireMVC.serve` helper.
- **`Bootstrap` is a graph binding.** `@WireMVCBootstrap` makes it graph-constructed (its
  `@Inject`s resolve). No cycle: it depends on its own deps, not on the collated route
  contributors.
- **Global `@Middleware` / `@ErrorResponse` live on the type, declared once** — never
  duplicated across controllers. The plugin (global view) reads them and folds them in.

## The unified pipeline

Every route — real or synthetic — folds to the same shape:

```
global mw → controller mw → route mw → terminal(handler; catch tiers below)
```

Both middleware and error maps gain a global tier, and it is the outer/default one in each:

- **Middleware order:** `global` is outermost (first in, last out).
- **Error tiers** (in the terminal `catch`, most-specific first):

  ```
  route @ErrorResponse → controller @ErrorResponse → global @ErrorResponse (Bootstrap)
    → built-in WireMVCBindingError → .status
    → Swift.Error catch-all, if declared
    → built-in 500 write            // terminal owns the 500 — never rethrow
  ```

  The terminus is a **500 write, not a rethrow** — because the server *aborts* (drops the
  connection) on an escaped throw rather than producing a 500. See
  [LinearSenderErrorModel.md § Correction](Notes/LinearSenderErrorModel.md#correction-wiremvc-must-synthesise-its-own-terminal-500).
  This supersedes RouteErrorHandling.md's rethrow terminus for handler errors.

## The `@NotFound` fallback handler (unmatched requests)

"No route matched" runs a **fallback handler**, not a faked error (the axum `.fallback` / chi
`.NotFound` / ASP.NET `MapFallback` / Flask `@errorhandler(404)` lineage). A `@NotFound` **method on
the `@WireMVCBootstrap` type** — DI-capable, in practice `@RawRoute`, so it writes the response with
full capability (stream a 404 page, negotiate, log) — is the fallback; the generated `@main` registers
it via `registerNotFound` *before* `finalize()`. When no `@NotFound` is declared, the plugin
synthesises a plain-404 fallback. Either way it's a **real route**, so:

- **Global middleware runs on unmatched requests too** (Phase 5 folds it into the fallback like any
  route) — e.g. an access-log middleware wraps the 404. This is why the default *must* be a registered
  fallback route, not the router's bare 404 (which fires below the fold and would skip the middleware).

The seam is native-path only: `FinalizableHTTPServerRouteBuilder.registerNotFound(handler:)` (same
handler shape as `register`, no template). `TrieRouteBuilder` stores one optional handler;
`FrozenTrieRouter` dispatches to it on a miss, its built-in 404 demoted to a safety net for the
never-registered case. `registerNotFound` is on the refinement, not the router-agnostic core, so the
`WireMVCServerTransport` adapter (whose fallback stays framework-owned) is unaffected. `@Path` on a
`@NotFound` is diagnosed (no matched template). The former "synthesize a `WireMVCRouteNotFound` and map
it through `@ErrorResponse`" design is **dropped** — a routing miss isn't an error.

## Two consequences accepted deliberately

- **Global middleware is post-routing.** Folded, it runs *after* the match decision (inside
  the matched-or-synthetic route's fold), not before. Every normal global concern is fine —
  auth still rejects (by *writing*, holding the sender), CORS preflight still answers
  (synthetic route when unmatched), rate-limiting still runs, response transformation works
  (writer-wrap before `next`, M5.4R). What the *folded* tier can't do is **routing-affecting**
  work — path rewrite / normalization / method-override *before* the match. That is a
  **pre-router concern, not a `@Middleware`**: it belongs at the `wrapHandler` seam (below),
  which wraps the router with a request-rewriting `HTTPServerRequestHandler`. This is the
  ecosystem's own split (nginx `rewrite`, Rack middleware, ASP.NET `UseRewriter` *before*
  `UseRouting`) — rewriting is a pre-router layer, distinct from app middleware. Keeping it a
  separate seam preserves the pure-dispatch invariant (the wrap is *outside* the dispatch, not
  inside it) and doesn't force the common request/response-processing middleware onto a
  pre-routing tier that would lose response access. A *declarative* pre-router `@Middleware`
  tier stays deferred to the two-phase model, if ever wanted.

  ```
  wrapHandler (rewrite / normalize)  →  router (match)  →  [ global mw → controller mw → route mw → handler ]
  ```

  The `wrapHandler` seam (on the Bootstrap, default identity) is graph-injectable — the
  Bootstrap is graph-constructed, so a rewrite that needs a lookup (tenant → internal path) can
  `@Inject` its store. **Sketch it in M5.5; surface the actual hook when an example forces
  routing-affecting behavior.**
- **A middleware throw is not mapped — it aborts.** Deferred entirely to
  [LinearSenderErrorModel.md](Notes/LinearSenderErrorModel.md): middleware express
  intentional responses by *writing*; an escaped middleware throw drops the sender and the
  server aborts the connection. WireMVC owns the 500 only for the *handler* throw (terminal
  holds the sender).

## What the generated `@main` does

1. `let graph = try await Wire.bootstrap()`.
2. Construct the `Bootstrap` binding from the graph (its `@Inject`s resolved).
3. `let server = bootstrap.createServer()`.
4. `var builder = bootstrap.createRoutableBuilder(for: server)`.
5. `let services = try WireMVC.apply(graph, to: &builder)` — register collated route
   contributors (each now folding the global tier).
6. Register the `@NotFound` fallback handler — or a synthesized 404 when none is declared — via
   `builder.registerNotFound(...)`.
7. If `bootstrap.mountIntrospectionAt()` is non-nil, mount introspection there, guarded by
   that method's `@Middleware`.
8. `let handler = builder.finalize()` — freeze the builder into the immutable servable handler
   (build → freeze → serve).
9. Wrap the handler with the pre-router seam: `let served = bootstrap.wrapHandler(handler)`
   (default identity — no-op unless overridden for routing-affecting logic).
10. Run `services` (collated `@BackgroundService`s) **and** `server.serve(handler: served)`
    together under ServiceLifecycle — the orchestration the current hand-written `main.swift`
    spells out.

## Scope boundary

- **Native path only.** `@WireMVCBootstrap` is the proposal-server composition root. The
  `ServerTransport` adapter path (Hummingbird/Vapor) keeps its own `@main`; routes generated
  for it fold in **no** global tier (the host framework owns global concerns). The plugin
  folds the global tier **only when a `@WireMVCBootstrap` type is present**.
- **Terminal-owns-500 is broader than M5.5.** It benefits every route on the native path,
  Bootstrap or not — but it's introduced here (Phase 2) because M5.5 is where the native
  serve loop is codified.

## Implementation plan

Phased so each step ships and is validated independently; the example repo is the gate
([M5_PLAN.md § The example repo as the progressive gate](M5_PLAN.md)).

- **Phase 1 — `@WireMVCBootstrap` surface + generated `@main`, no global tiers. — ✅ DONE.**
  `@WireMVCBootstrap` is a peer marker (reuses `RouteMarkerMacro`); `WireMVCCodegen`'s
  `BootstrapGeneration` emits a top-level `@main struct _WireMVCBootstrapEntry` into `_WireRoutes.swift`
  that does steps 1–5 + `builder.finalize()` + serve via the new non-generic-at-the-callsite
  `WireMVC.serve(on:handler:services:)` helper (fallback registration + introspection + `wrapHandler`
  are later phases; global `@Middleware`/`@ErrorResponse` not yet folded). Ships alongside the
  **`WireMVCRouter`** target — the `ServableRoutableHTTPServerBuilder` refinement + a segment-trie
  router (`TrieRouteBuilder`/`FrozenTrieRouter`, ported from `wire-mvc-examples`; non-generic
  `RouteTrie` core, 11 tests) — so the native path has a router to return. A new thin
  `WireMVCBootstrapExample` target (`@Singleton @WireMVCBootstrap` + one controller) proves it;
  `WireMVCExample` stays the full-matrix self-checker (now on the same trie router). *Validation:* the package builds; the example serves end-to-end
  (`GET /hello/Ada` → `200 {"message":"Hello, Ada!"}`, unmatched → `404`); 3 golden tests in
  `WireMVCCodegenTests` pin the emitted entry (32 tests green). **Notes:** `swift build --target X`
  doesn't run the build-tool plugin — a full `swift build` (or building the example) is required;
  the `WireMVC.serve` helper runs serving in the task-group *body* (non-Sendable `server`/`builder`
  used directly, never captured into a `@Sendable` child task) with only the `Sendable` services in a
  child task — the shape that satisfies region isolation under `NonisolatedNonsendingByDefault`.
- **Phase 2 — terminal owns the 500. — ✅ DONE.** Every typed terminal now wraps its body (scope-entry
  prologue + binds + handler + encode) in a `do`, and `errorCatchClause` always ends the `??` chain in a
  non-optional terminal — a declared catch-all, or the built-in `WireMVCOutcome.status(.internalServerError)`
  — so it never re-throws ([RouteCodegen](../../wire-mvc/Sources/WireMVCCodegen/RouteCodegen.swift):
  `closureBody`/`errorCatchClause`). Unified the three former terminal shapes into one. *Validation:* a
  new `BoomController` throws an unmapped `Boom` → `GET /boom` returns `500` (not a dropped connection) in
  `WireMVCExample`; 32 `WireMVCCodegen` goldens updated + green. Benefits all native routes; only raw
  routes (which own their sender) are exempt.
- **Phase 3 — global `@ErrorResponse` tier. — ✅ DONE.** `WireMVCRouteGen` reads the
  `@WireMVCBootstrap` type's `@ErrorResponse` **once** (with its own scope diagnostics) and threads it
  as `[ErrorMapping]` into every route's terminal — composed `route + controller + global`, so the global
  tier is the default consulted after the controller's, before the binding-error built-in, before the
  built-in 500. Plumbing: `ErrorMapping` lifted to a top-level `public` type (so it can cross the render
  functions' signatures); `RouteBlockGenerator` gains a `globalErrorMappings` field; the macro path
  passes `[]` (no whole-graph view). *Validation:* golden `globalErrorResponseFoldsIntoEveryRoute`; and
  `WireMVCBootstrapExample`'s `AppBootstrap` gains `@ErrorResponse(TenantMissing.self, .badRequest)` with
  a `/hello/tenant` route that throws it (no local map) → the CI boot-probe asserts `400`. 33 codegen
  goldens green.
- **Phase 4 — `@NotFound` fallback handler + router seam. — ✅ DONE.** Reshaped from the
  "synthesize a `WireMVCRouteNotFound` error and route it through `@ErrorResponse`" sketch to a
  **fallback *handler*** (the axum `.fallback` / chi `.NotFound` / ASP.NET `MapFallback` /
  Flask `@errorhandler(404)` lineage) — cleaner, since "no route matched" is a routing decision, not a
  faked error, and the handler has full capability (stream via `@RawRoute`, etc.).
  `HTTPServerRouteBuilder`'s native-path refinement (`FinalizableHTTPServerRouteBuilder`) gains
  `registerNotFound(handler:)`; `TrieRouteBuilder` stores it, `FrozenTrieRouter` dispatches to it on a
  miss (its built-in 404 demoted to a safety net for the never-registered case). **`@NotFound` is a
  method on the `@WireMVCBootstrap` type** (DI-capable, in practice `@RawRoute`; `@Path` diagnosed —
  no template), rendered through the shared raw-route machinery, dispatched through the `@main`'s
  `bootstrap` local. The generated `@main` **always** calls `registerNotFound` — with the `@NotFound`
  handler, or a synthesized 404 when none is declared — *before* `finalize()`, so the fallback is a
  real fold-able route (Phase 5 folds the global `@Middleware` into it, so e.g. an access-log middleware
  wraps the 404). `WireMVCRouteNotFound` dropped. *Validation:* goldens
  `notFoundHandlerRegistersAsFallback` / `notFoundHandlerMustBeRaw` (35 codegen tests green); and
  `WireMVCBootstrapExample`'s `AppBootstrap` gains a `@NotFound @RawRoute` returning `404 "no route
  here"`, asserted by the CI boot-probe (`GET /nope`).
- **Phase 5 — global `@Middleware` tier, via a fan-out proxy-lift.** The global tier folds into
  every route (and the `@NotFound` fallback) as the **outer** middleware, by lifting the Bootstrap's
  `@Middleware` bindings onto **every route-contributor proxy** — so each route's witness reads them
  from `self` exactly as it reads a controller's own `@Middleware`, and the wire-mvc **contract stays
  frozen** (`RouteContributor`, `WireMVC.apply`, the generated `@main` all unchanged). *Rejected the
  front-layer wrapper:* the box fold hands its terminal `consuming` reader/sender, but
  `HTTPServerRequestHandler.handle` (the router) demands `consuming sending`, and the box can't prove
  `sending` — so a wrapper can't chain to `router.handle`. The fold must terminate in a route handler
  (`consuming`), which is exactly where lifting puts it.

  - **swift-wire — one capability + one rewrite pass.** A new `WireAdapterCapability` case,
    `injectsPeerFromGraphIntoAll(peer: String, collatingInto: Any)`: on the decl it sits on, peer
    use-sites named `peer` inject their argument onto **every proxy collating into `collatingInto`**,
    instead of the peer's own self-scope `.injectsFromGraph`. `@WireMVCBootstrap` — a pure marker today
    — is promoted to a `WireAdapterAnnotationV1` carrying
    `.injectsPeerFromGraphIntoAll(peer: "Middleware", collatingInto: WireMVCKeys.routeContributors)`, so
    WireGen begins scanning it. One new pass, slotted after `applyContributorProxies` (proxies + their
    collation keys known) and before `applyAdapterDependencies`, **rewrites** use-sites the way
    `reattributingInputEdges` already does: for each decl carrying the capability, it removes each peer
    `@Middleware(X)` use-site and re-emits one `@Middleware(X)` use-site *per proxy* collating into the
    key (targeting the proxy). Everything downstream — `applyAdapterDependencies` appending `_wire<X>`,
    factory synthesis, proxy-struct emission — runs **unchanged**; the rewrite deletes the root-targeting
    use-site, so no existing pass needs skip-logic, and because it re-emits `@Middleware`-labelled
    use-sites the argument-kind dispatch (`T.self` / `BindingKey` / `FactoryKey`) is inherited for free.
    Precedent for co-located annotations that combine: `.mapsFactoryRoles` already joins to a peer
    `@Factory` on the same type.
  - **wire-mvc codegen — thread the global fold like `globalErrorMappings`.** `WireMVCRouteGen` reads
    the `@WireMVCBootstrap` type's `@Middleware` **once** and threads the lifted-field constructions
    (`self._wire<G>`, via the existing `dependencyPropertyName(forType:)`, which already agrees with
    WireGen's `syntheticDependencyName(forType:)`) into every `renderRouteContributorExtension`, exactly
    as Phase 3 threads `globalErrorMappings`. `middlewareConstructions` prepends them, so each route's
    `wireCompose { self._wireG; <controller mw>; <route mw> }` gains the global tier outermost. **Plain
    routes now fold too** — a route with no middleware keeps today's direct shape absent a global tier,
    but under one it grows the box / `intercept` / `withPendingContents` scaffold (same body churn as any
    folded route).
  - **The `@NotFound` fallback folds the same tier via a different access path.** The fallback is a
    method on the Bootstrap, rendered into the generated `@main` (Phase 4) — *not* a route-contributor
    proxy, so the fan-out lift doesn't reach it and it can't read `self._wireG`. It doesn't need to: the
    `@main` holds `graph`, so its `registerNotFound` closure folds the same singleton bindings read as
    `graph.<g>` (the composition root's own graph-property access) instead of the `self._wireG` proxy
    fields the controller witnesses use. Same singletons, both wrapped — the lift covers the controller
    proxies (which see only `self`), the `@main` covers the fallback (which sees the graph). So middleware
    on the miss endpoint needs no swift-wire change, only the `@main`'s fallback rendering.
  - **Free-degrades.** No `@Middleware` on the Bootstrap → no capability directive → no synthetic
    use-sites → no `_wire<G>` fields → no fold → **byte-identical to today's output**. No conditional in
    the codegen, no per-request tax on apps without global middleware — the property the front-layer /
    always-thread-identity alternatives couldn't give.
  - **Non-transforming in practice, not by a special rule.** Folded onto every proxy, a global
    middleware is mechanically the *same tier* as a controller's — same `wireCompose`. What differs is
    **blast radius and locality**, not the fold: global is the *outermost* tier of *every* route, so a
    sender-*type* transform (S → T, M5.4R) there hands `T` to every inner controller/route middleware and
    every handler, app-wide, from a declaration none of them can see (a controller/route transform reshapes
    only its own routes' inner stack, co-located with the `@RawRoute(.role)` handler that opts in). And it
    is *not* a clean compile error: it flows through wherever the inner stack is sender-generic — typed
    routes (the codegen owns the sender via `send(on:)`, generic over `HTTPResponseSender`) and bare
    `@RawRoute` handlers (generic `<Sender: HTTPResponseSender>`) both bind `T` silently — and breaks only
    where some inner tier assumed the base sender `S` (a controller/route `@Middleware` whose `Input` is
    `Box<…,S>`, or a `@RawRoute(.role)` naming a concrete non-`T` slot). So a global sender-transform is
    either invisible action-at-a-distance or a compile error deep in generated code. The codegen can't even
    diagnose it — it holds only the type name (`AccessLog`), not the middleware's box associated types — so
    non-transforming is a **documented expectation** backed by "it won't compile where it doesn't fit," not
    an enforced constraint. The always-safe set is type-preserving: observe (log / metric),
    short-circuit-by-writing (auth reject, CORS preflight), response-processing that keeps the sender type.
    Threading a global transform into every handler slot (making it a *supported* effect) is deferred.
  - **Placement diagnostic.** `@Middleware` on a decl that is neither a `@Controller` nor the
    `@WireMVCBootstrap` root appends a `_wire<X>` field nothing folds — a silent no-op. The `@Middleware`
    marker macro sees its host's peer attributes, so it errors locally: *"`@Middleware` here is never
    folded — put it on a `@Controller` or the `@WireMVCBootstrap` composition root."* No whole-program
    scan, one spelling to guide toward (no "use the other annotation" redirect — there isn't one).

  *Validation:* a type-preserving global middleware (an access-log) declared `@Middleware(AccessLog.self)`
  on `AppBootstrap` runs on a **matched** route (`GET /hello/Ada`) **and** the **unmatched** fallback
  (`GET /nope`) — the CI boot-probe asserts the access line appears for both — the M5.5 gate from
  M5_PLAN.md. Plus goldens: a plain route folding only the global tier, a middleware route with the
  global tier prepended, and the free-degrade golden (no Bootstrap `@Middleware` → unchanged output). A
  WireGen unit test pins the fan-out (root `@Middleware(G.self)` → a `_wireG` field on every proxy
  collating into `routeContributors`, and none on a non-collating binding).

### Spikes / open items

- **Shared global-fold helper typing. — resolved.** No shared `applyGlobalLayers` helper: the fold is
  inlined per route as `wireCompose { self._wireG; … }`, reading the lifted proxy field, so there is no
  helper signature to express a cross-tier sender transform. The sender-transforming case is closed by
  the *non-transforming* constraint above (a transform fails to type-check), not by a helper — see
  Deferred for lifting that constraint.
- **Route codegen ↔ Bootstrap coupling.** Folding the global tier makes each route's output depend on
  the Bootstrap's global `@Middleware`, so touching the Bootstrap invalidates route codegen — and the
  fan-out adds a `_wire<G>` field to every route-contributor proxy, so it invalidates WireGen's proxy
  emission too. Inherent to a cross-cutting concern; note the incremental-build cost, accept it.
- **Introspection method spelling.** `@Middleware` on a config-returning method
  (`mountIntrospectionAt`) is a novel placement (the middleware guards the *route* the path
  names). Keep the method form (it lets the path come from injected `config`); be deliberate
  in docs that the `@Middleware` there guards the introspection route.

## Deferred

- **Transform-only middleware** (throw ⇒ 500 instead of abort) — the escape hatch in
  [LinearSenderErrorModel.md § escape hatch](Notes/LinearSenderErrorModel.md#the-one-escape-hatch-deferred).
  Not built speculatively.
- **Sender-type-transforming global middleware** (M5.4R at global scope) — would require the codegen to
  thread the global tier's box transform into *every* handler's slot type (each handler is shaped only
  for its own route chain today). Phase 5 leaves global middleware type-preserving as a documented
  expectation — a transform flows through where the inner stack is sender-generic and fails to compile
  where it isn't, but it's not cleanly diagnosable (the codegen sees only the type name). Lands as a
  *supported* effect only if an example forces a global sender transform.
- **Graph-injected `@ErrorResponse` handler** — the dependency-bearing error tier
  ([RouteErrorHandling.md](Notes/RouteErrorHandling.md)); lands when an example forces
  injected deps in a mapping, orthogonal to M5.5.

## Validation gate (overall)

`WireMVCExample`'s hand-written `main` collapses to `@WireMVCBootstrap` and serves
identically; then, exercised end-to-end on `NIOHTTPServer`: an unmapped handler throw → 500
(Phase 2), a Bootstrap global `@ErrorResponse` map (Phase 3), an unmatched route → mapped 404
(Phase 4), and a global `@Middleware` running on both a matched and an unmatched route
(Phase 5).
