# M5.5 — the WireMVC-native composition root (`@WireMVCBootstrap`)

> **Status:** settled design, not yet implemented. Iteration **M5.5** in
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
applied identically to real routes and to one **synthetic fallback route** that owns the
unmatched-request case. The result is a clean invariant: **the router is pure dispatch, and
every response comes from a route that holds the sender** — a real match, or the synthetic
fallback. Nothing responds without holding the sender, so the whole surface stays inside the
linear-sender box model with no new response machinery.

## The surface

```swift
@main
@WireMVCBootstrap
@Middleware(GlobalMiddleware.requestLogging)          // global tier — outermost middleware
@Middleware(GlobalMiddleware.cors)
@ErrorResponse(NotFound.self, .notFound)              // global tier — default error map
@ErrorResponse({ (e: Swift.Error) in .status(.internalServerError) })
struct Bootstrap {
    @Inject(Logger.application) let logger: Logger    // resolved from the graph
    @Inject let config: ConfigReader

    func createServer() -> some HTTPServer {          // concrete server defines its own assoc types
        NIOHTTPServer(logger: logger, configuration: try .init(
            bindTarget: .hostAndPort(host: config.string("host"), port: config.int("port")),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext))
    }

    func createRoutableBuilder<Server: HTTPServer>(   // generic over the server it is handed
        for server: borrowing Server
    ) -> some RoutableHTTPServerBuilder<Server.RequestContext, Server.Reader, Server.ResponseSender> {
        WireRouter(for: server)
    }

    // Optional pre-router seam (default identity). Home for routing-affecting logic —
    // path rewrite / normalization / method-override — which runs BEFORE the match.
    func wrapHandler<H: HTTPServerRequestHandler>(_ router: consuming H)
        -> some HTTPServerRequestHandler<H.RequestContext, H.Reader, H.ResponseSender> { router }

    @Middleware(IntrospectionMiddleware.admin)        // guards the introspection route
    func mountIntrospectionAt() -> String? { "/wiring" }
}
```

Refinements over the initial sketch:

- **`createServer` is not generic over the associated types.** A concrete `NIOHTTPServer`
  *defines* its `RequestContext`/`Reader`/`ResponseSender`; the caller doesn't choose them.
  It returns `some HTTPServer` and the types **flow from** it. `createRoutableBuilder(for:)`
  is generic over the server it receives — mirroring `WireRouter(for:)`'s inference. The
  generated `main()` threads `Server` through both.
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

## The synthetic fallback route (unmatched requests)

"No route matched" becomes literally a route. The router — pure dispatch — hands the sender
to a generated **synthetic fallback route** when nothing matches. That route folds in the
same global tier and its terminal throws `WireMVCRouteNotFound`, which the folded global
error maps catch (built-in 404 if unmapped). So:

- **Global middleware runs on unmatched requests too** (via the synthetic route's fold) —
  recovering the pre-routing/unmatched coverage a front-layer wrapper would have given.
- **The Bootstrap's `@ErrorResponse` can shape the miss** — an
  `@ErrorResponse(WireMVCRouteNotFound.self, .notFound)` (or the wildcard) customises it;
  otherwise a plain 404.

Requires one new seam: `RoutableHTTPServerBuilder.registerNotFound(handler:)`, mapping to
each backend's not-found responder (`WireRouter` gets a default-handler field; the
`WireMVCServerTransport` adapter maps to Hummingbird/Vapor's existing not-found responder —
but the adapter path doesn't use `@WireMVCBootstrap`, so its fallback stays framework-owned).

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
6. Register the synthetic fallback route via `builder.registerNotFound(...)`.
7. If `bootstrap.mountIntrospectionAt()` is non-nil, mount introspection there, guarded by
   that method's `@Middleware`.
8. Wrap the router with the pre-router seam: `let handler = bootstrap.wrapHandler(builder)`
   (default identity — no-op unless overridden for routing-affecting logic).
9. Run `services` (collated `@BackgroundService`s) **and** `server.serve(handler: handler)`
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

- **Phase 1 — `@WireMVCBootstrap` surface + generated `@main`, no global tiers.** The macro
  makes `Bootstrap` a graph binding; the plugin emits `main()` doing steps 1–5, 8–9 above
  (server/builder factories, apply, `wrapHandler` identity seam, ServiceLifecycle serve;
  fallback registration + introspection land in later phases). Global `@Middleware`/
  `@ErrorResponse` on the type are parsed but not yet folded. *Validation:*
  `WireMVCExample`'s hand-written `main.swift` collapses to the macro and serves identically
  (same requests green before/after).
- **Phase 2 — terminal owns the 500.** Change the terminal's outermost tier from rethrow to
  a built-in 500 write ([RouteCodegen](../../wire-mvc/Sources/WireMVCCodegen/RouteCodegen.swift)).
  Small, independent, benefits all native routes. *Validation:* an unmapped handler throw
  yields a clean `500` (not a dropped connection) — a new `WireMVCExample` check hitting a
  route that throws an unmapped error.
- **Phase 3 — global `@ErrorResponse` tier.** The plugin reads the Bootstrap's
  `@ErrorResponse` and folds them as the default tier of every route's `catch` (by
  reference; the maps are defined once on the Bootstrap). *Validation:* a Bootstrap
  `@ErrorResponse(SomeError.self, .status)` maps an otherwise-unmapped throw from a route
  that declares no local map.
- **Phase 4 — synthetic fallback route + router fallback seam.**
  `RoutableHTTPServerBuilder.registerNotFound`, `WireRouter` default-handler field, the
  `WireMVCRouteNotFound` type, and the generated synthetic route (global tier + terminal
  throwing `WireMVCRouteNotFound`). *Validation:* an unmatched path returns a
  Bootstrap-mapped 404 (and a plain 404 with no Bootstrap map).
- **Phase 5 — global `@Middleware` tier.** Fold the Bootstrap's `@Middleware` as the outer
  tier of every route *and* the synthetic route. Prefer a single generated
  `applyGlobalLayers(box, terminal)` helper both call, over inlining N copies. *Validation:*
  a global middleware runs on a matched route **and** on an unmatched route (the M5.5 gate
  from M5_PLAN.md, now via the synthetic route rather than a front layer).

### Spikes / open items

- **Shared global-fold helper typing.** If a global middleware is *sender-transforming*
  (M5.4R), the box's sender type changes across the global tier, so `applyGlobalLayers`'
  signature must express that transformation generically — possibly not expressible, in
  which case Phase 5 inlines per route. **Spike this before committing to the shared helper.**
- **Route codegen ↔ Bootstrap coupling.** Folding the global tier makes each route's output
  depend on the Bootstrap's global declarations, so touching the Bootstrap invalidates route
  codegen. Inherent to a cross-cutting concern; note the incremental-build cost, accept it.
- **Introspection method spelling.** `@Middleware` on a config-returning method
  (`mountIntrospectionAt`) is a novel placement (the middleware guards the *route* the path
  names). Keep the method form (it lets the path come from injected `config`); be deliberate
  in docs that the `@Middleware` there guards the introspection route.

## Deferred

- **Transform-only middleware** (throw ⇒ 500 instead of abort) — the escape hatch in
  [LinearSenderErrorModel.md § escape hatch](Notes/LinearSenderErrorModel.md#the-one-escape-hatch-deferred).
  Not built speculatively.
- **Graph-injected `@ErrorResponse` handler** — the dependency-bearing error tier
  ([RouteErrorHandling.md](Notes/RouteErrorHandling.md)); lands when an example forces
  injected deps in a mapping, orthogonal to M5.5.

## Validation gate (overall)

`WireMVCExample`'s hand-written `main` collapses to `@WireMVCBootstrap` and serves
identically; then, exercised end-to-end on `NIOHTTPServer`: an unmapped handler throw → 500
(Phase 2), a Bootstrap global `@ErrorResponse` map (Phase 3), an unmatched route → mapped 404
(Phase 4), and a global `@Middleware` running on both a matched and an unmatched route
(Phase 5).
