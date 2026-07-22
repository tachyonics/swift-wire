# M5.5 — the WireMVC-native composition root (`@WireMVCBootstrap`)

> **Status:** Phases 1–4 shipped; Phase 5 (global `@Middleware`, the front layer) built and validated in
> the design spikes (24/25) + the swift-wire `LiftsPeersToProxy` tests; the wire-mvc codegen (the global
> proxy's `wrap` method) and end-to-end example are gated on the swift-wire `.liftsPeersToProxy` merge.
> Iteration **M5.5** in [M5_PLAN.md](M5_PLAN.md); this file is the detailed plan (same relation
> M5_4_PLAN.md has to M5.4). Rests on M5.1–M5.4E/M5.4R (shipped). Depends on the error model in
> [Notes/LinearSenderErrorModel.md](Notes/LinearSenderErrorModel.md) and the `@ErrorResponse` surface in
> [Notes/RouteErrorHandling.md](Notes/RouteErrorHandling.md).

## Rescope

M5.5 was framed as an `@WireHummingbird` composition-root macro. **That framing is retired.** The
Hummingbird and Vapor integrations are idiomatic *in their own ecosystems* — you use their
`Application`/`@main`, and their own middleware owns global concerns. A macro there fights the grain. M5.5
is now the **WireMVC-native bootstrap**: the proposal-server path where WireMVC owns the composition root,
and therefore the one place that needs a home for global middleware, default error handling, and
introspection mounting.

## The model in one paragraph

`@WireMVCBootstrap` marks a **graph-constructed composition root** — a struct whose `@Inject` properties
resolve from the graph and whose factory methods build the concrete server and router — and generates
`@main`. Its two global tiers land in **two different places**, because they have different shapes:

- The global **`@ErrorResponse`** tier is **folded into every route's terminal** as the default `catch`
  tier (route → controller → global), by reference to the maps defined once on the Bootstrap (Phase 3).
- The global **`@Middleware`** tier is a **front layer** — the generated `@main` wraps the finalized router
  once in a `GlobalMiddlewareHandler`, folding the composed chain around `router.handle` (Phase 5). Because
  the wrapper sits *above* the router, it covers matched routes **and** the unmatched case (the router's
  `@NotFound` fallback) for free — no per-route replication, no synthetic route.

The result stays inside the linear-sender box model: middleware respond by *writing* (holding the sender),
never by an out-of-band control-flow path, and the terminal owns the 500.

## The surface

```swift
@Singleton                                            // required — makes it a graph binding
@WireMVCBootstrap                                     // marker; the @main entry is *generated*, not written
@Middleware(LoggingKeys.accessLog)                    // global tier — front-layer wrapper (Phase 5), factory-form
@ErrorResponse(TenantMissing.self, .badRequest)       // global tier — default error map (Phase 3)
@ErrorResponse({ (e: Swift.Error) in .status(.internalServerError) })
struct AppBootstrap {
    @Inject let config: ServerConfig                  // resolved from the graph

    func createServer() throws -> NIOHTTPServer {     // the CONCRETE server — see note
        NIOHTTPServer(logger: Logger(label: "app"), configuration: try .init(
            bindTarget: .hostAndPort(host: config.host, port: config.port),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext))
    }

    func createRouteBuilder<Server: HTTPServer>(      // generic over the server it is handed
        for server: borrowing Server
    ) -> some FinalizableHTTPServerRouteBuilder<Server.RequestContext, Server.Reader, Server.ResponseSender>
    where
        Server.RequestContext: ~Copyable, Server.Reader: ~Copyable,
        Server.ResponseSender: ~Copyable, Server.ResponseSender.Writer: ~Copyable
    {
        TrieRouteBuilder(for: server)                 // WireMVCRouter — build → freeze → serve
    }

    @NotFound @RawRoute                               // the fallback for unmatched requests (Phase 4)
    func handleNotFound<Sender: HTTPResponseSender & ~Copyable & SendableMetatype>(
        responseSender: consuming Sender
    ) async throws where Sender.Writer: ~Copyable { … }
}
```

Refinements (corrected during implementation):

- **`createServer` returns the *concrete* server, not `some HTTPServer`.** The proposal's
  `Reader`/`ResponseSender` are `~Copyable`, and a bare `some HTTPServer` opaque return can't express that —
  it forces the associated types `Copyable` (a real compile error). So the factory returns e.g.
  `NIOHTTPServer`; the generated `main()` binds to whatever concrete type it returns.
- **`createRouteBuilder(for:)` returns `some FinalizableHTTPServerRouteBuilder<…>`** — the native-path
  refinement of the router-agnostic core `HTTPServerRouteBuilder` (adds `registerNotFound(handler:)` and
  `finalize() -> some HTTPServerRequestHandler`), restating the `~Copyable` requirements on `Server`'s
  associated types (they don't propagate — same as `WireMVC.apply`). **build → freeze → serve**:
  `WireMVC.apply` registers routes onto the mutable builder; the generated `main()` `finalize()`s it into
  the immutable handler the server serves. The refinement carries `registerNotFound`/`finalize` (not the
  core) because the `ServerTransport` adapter's builder conforms to the core but doesn't serve via
  `HTTPServerRequestHandler`. `WireMVCRouter`'s `TrieRouteBuilder`/`FrozenTrieRouter` (a segment trie, with
  a non-generic `RouteTrie` core) is what the native path returns.
- **`@Singleton` is required, `@main` is generated.** No swift-wire capability makes a type a binding on its
  own, so `@WireMVCBootstrap` rides `@Singleton` (as `@Singleton @Controller` does); the `@main` entry
  (`_WireMVCBootstrapEntry`) is emitted by `WireMVCRouteGen`, reading the binding as `graph.<lowerCamelType>`
  and serving via the `WireMVC.serve` helper.
- **Global `@Middleware` / `@ErrorResponse` live on the type, declared once** — never duplicated across
  controllers. The plugin (whole-program view) reads them and folds them in.

## The two global tiers

### Error tier — folded into every route (Phase 3)

`WireMVCRouteGen` reads the Bootstrap's `@ErrorResponse` once and threads it (`globalErrorMappings`) into
every route's terminal `catch`, composed most-specific first:

```
route @ErrorResponse → controller @ErrorResponse → global @ErrorResponse (Bootstrap)
  → built-in WireMVCBindingError → .status
  → Swift.Error catch-all, if declared
  → built-in 500 write            // terminal owns the 500 — never rethrow
```

The terminus is a **500 write, not a rethrow** — because the target server *aborts* (drops the connection)
on an escaped throw rather than producing a 500. See
[LinearSenderErrorModel.md § Correction](Notes/LinearSenderErrorModel.md#correction-wiremvc-must-synthesise-its-own-terminal-500).
This supersedes RouteErrorHandling.md's rethrow terminus for handler errors.

### Middleware tier — the front layer (Phase 5)

Global middleware are **not** folded into each route. The `@main` wraps the finalized router once:

```
GlobalMiddlewareHandler(global mw)  →  router (match)  →  [ controller mw → route mw → terminal(handler) ]
```

`GlobalMiddlewareHandler<Inner: HTTPServerRequestHandler, Chain: Middleware>` builds a
`RequestResponseMiddlewareBox` from the request, folds the composed `Chain` (`chain.intercept`), and its
terminal calls `inner.handle` — the router.

**The obstacle this had to clear, and how.** The wrapper's terminal must hand the router `consuming sending`
reader/sender (the `HTTPServerRequestHandler` contract), but the box laundered `sending` off its linear
reader/sender on extraction (`withPendingContents` yielded `consuming`). Fixed by holding them in
``WireDisconnected`` — WireMVC's vendored subset of [SE-0538](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0538-disconnected.md)
`Disconnected<Value>` (`nonisolated(unsafe)` storage; `init(consuming sending)` / `take() -> sending`),
riding only stable features. The box became a `struct` over an internal `Storage` enum whose `.pending`
holds `WireDisconnected<Reader>`/`<ResponseSender>`; the public `pending(…)` factory wraps the raw `sending`
values (so the generated `.pending(reader: reader, …)` call site is unchanged) and `withPendingContents` /
`withContents` unwrap via `take()`. `WireDisconnected` never appears in the box's public surface. (Validated
end-to-end against the real proposal protocols in `swift-wire-spikes/spike-24`.)

**Factory-form, folded through a global-middleware proxy.** Global middleware are folded exactly as
controller-scope middleware are: WireGen synthesises a **proxy** for the Bootstrap that lifts its
`@Middleware` factories onto itself, and `WireMVCRouteGen` emits a generic `wrapGlobalMiddleware<Handler>`
method on it (the analogue of a controller's `registerWireRoutes<Builder>`):

```swift
extension _WireGlobalMiddleware_<Bootstrap> {
    func wrapGlobalMiddleware<Handler: HTTPServerRequestHandler>(_ inner: Handler)
        -> some HTTPServerRequestHandler<Handler.RequestContext, Handler.Reader, Handler.ResponseSender>
    { GlobalMiddlewareHandler(inner: inner, chain: wireCompose {
        self._wireFactory_<key>.create(Handler.RequestContext.self, Handler.Reader.self, Handler.ResponseSender.self)
    }) }
}
```

The `@main` reads the proxy directly (`graph._WireGlobalMiddleware_<Bootstrap>`, an addressable binding) and
serves `proxy.wrapGlobalMiddleware(handler)`. `.create(Handler box)` produces the middleware **directly over
`Box<Handler>`**, so the chain is non-transforming end-to-end (the router is fixed on its box type) with no
transforming bridge. (Validated in `swift-wire-spikes/spike-25` + the `LiftsPeersToProxy` unit tests.)

**Factory (generic) only — by-type is impossible here.** A global `@Middleware` must be **factory-form**
(`@Middleware(Key)`, generic over the box). A by-type `@Middleware(T.self)` is a concrete `Box<Fixed>`
middleware, which cannot appear in the non-transforming generic chain (`Box<Handler> → Box<Handler>`) — it
would need a transforming middleware in front to reach `Box<Fixed>`, and global scope forbids that (the
router's fixed box). So by-type at global scope is diagnosed
(`WireMVCDiagnostic.globalMiddlewareUnsupportedArgument`, inverted from the by-type-only sketch). Transforming
middleware stay controller/route-scope, where the terminal is shaped for the transformed box.

**`@Middleware` at the root needs swift-wire (the one cross-repo dependency): `.liftsPeersToProxy`.**
`@Middleware` is a WireGen `.injectsFromGraph` annotation — on any binding it lifts the middleware as a
dependency; on the plain composition root that would inject a `_wireFactory_<key>` field the root doesn't
have. So `@WireMVCBootstrap` carries swift-wire's **`.liftsPeersToProxy(proxyTypePrefix: "_WireGlobalMiddleware_")`**
capability: WireGen synthesises a proxy that **reattributes** the root's `@Middleware` onto itself (factory
synthesis lands `_wireFactory_<key>` on the proxy, not the root) but contributes to **no** multibinding — a
standalone, directly-addressable binding. This is the controller-proxy machinery with `contributions: []`;
it lets `@Middleware` mean one thing at route, controller, and global scope, the scope set by *placement* —
exactly as `@ErrorResponse` already is — with no distinct `@GlobalMiddleware` spelling. Free-degrade: the
proxy is always synthesised, and `wrapGlobalMiddleware` degrades to `{ inner }` (identity) when the Bootstrap
declares no `@Middleware`, so the `@main` always calls it uniformly with no dead binding.

## The `@NotFound` fallback handler (Phase 4)

"No route matched" runs a **fallback handler**, not a faked error (the axum `.fallback` / chi `.NotFound` /
ASP.NET `MapFallback` / Flask `@errorhandler(404)` lineage). A `@NotFound` **method on the Bootstrap** —
DI-capable, in practice `@RawRoute` so it writes the response directly — is registered via
`builder.registerNotFound(...)` before `finalize()`; the frozen router dispatches to it on a miss. When no
`@NotFound` is declared, the `@main` registers a synthesised plain-404. `@Path` on a `@NotFound` is
diagnosed (no matched template). The former "synthesise a `WireMVCRouteNotFound` and map it through
`@ErrorResponse`" design is **dropped** — a routing miss isn't an error, and the front layer already covers
the miss with the global middleware tier (the wrapper is above the router, so it wraps the 404/fallback
without the fallback needing to be a fold target).

`registerNotFound(handler:)` (same handler shape as `register`, no template) is on the
`FinalizableHTTPServerRouteBuilder` refinement, not the router-agnostic core, so the `WireMVCServerTransport`
adapter (whose fallback stays framework-owned) is unaffected.

## Two consequences accepted deliberately

- **Global middleware runs pre-routing but can't affect routing.** The wrapper folds the global tier before
  `router.handle`. Every normal global concern is fine — access logging, auth rejects by *writing* (holding
  the sender), CORS preflight answers, rate-limiting runs. What it *can't* do is **routing-affecting** work —
  path rewrite / normalization / method-override — because it's non-transforming and can't mutate the request
  the router matches on. That is a **pre-router concern, not a `@Middleware`**: a future `wrapHandler` seam on
  the Bootstrap (graph-injectable, default identity) would wrap the router with a request-rewriting
  `HTTPServerRequestHandler`, mirroring nginx `rewrite` / ASP.NET `UseRewriter` *before* `UseRouting`.
  **Deferred** until an example forces routing-affecting behavior (see Deferred).
- **A middleware throw is not mapped — it aborts.** Deferred entirely to
  [LinearSenderErrorModel.md](Notes/LinearSenderErrorModel.md): middleware express intentional responses by
  *writing*; an escaped middleware throw drops the sender and the server aborts the connection. WireMVC owns
  the 500 only for the *handler* throw (terminal holds the sender).

## What the generated `@main` does

1. `let graph = try await Wire.bootstrap()`.
2. `let bootstrap = graph.<lowerCamelType>` — the graph-constructed composition root.
3. `let server = try bootstrap.createServer()` (`try` only when the factory is `throws`).
4. `var builder = bootstrap.createRouteBuilder(for: server)`.
5. `let services = try WireMVC.apply(graph, to: &builder)` — register the collated route contributors.
6. `builder.registerNotFound { … }` — the `@NotFound` handler, or a synthesised 404 when none is declared.
7. `let handler = builder.finalize()` — freeze the builder into the immutable servable handler.
8. **Serve.** `let served = graph._WireGlobalMiddleware_<Bootstrap>.wrapGlobalMiddleware(handler)` — the global
   proxy folds its `@Middleware` factories around the router (identity when none), served via `WireMVC.serve`.
   `WireMVC.serve` runs the serve loop in the task-group *body* with only the `Sendable` services in a child
   task — the shape that satisfies region isolation under `NonisolatedNonsendingByDefault`.

## Scope boundary

- **Native path only.** `@WireMVCBootstrap` is the proposal-server composition root. The `ServerTransport`
  adapter path (Hummingbird/Vapor) keeps its own `@main`; the host framework owns global concerns, so no
  front layer is emitted there. The global tiers are emitted **only when a `@WireMVCBootstrap` type is
  present**.
- **Terminal-owns-500 is broader than M5.5.** It benefits every route on the native path, Bootstrap or not —
  but it's introduced here (Phase 2) because M5.5 is where the native serve loop is codified.
- **Phase 5 is the one cross-repo phase.** Phases 1–4 are wire-mvc-only; Phase 5's `@Middleware`-at-the-root
  needs swift-wire's `.liftsPeersToProxy` (Phases 1–4 needed nothing from swift-wire).

## Implementation plan

Phased so each step ships and is validated independently; the example repo is the gate
([M5_PLAN.md § The example repo as the progressive gate](M5_PLAN.md)).

- **Phase 1 — `@WireMVCBootstrap` surface + generated `@main`, no global tiers. — ✅ DONE.**
  `@WireMVCBootstrap` is a peer marker (reuses `RouteMarkerMacro`); `WireMVCCodegen`'s `BootstrapGeneration`
  emits a top-level `@main struct _WireMVCBootstrapEntry` into `_WireRoutes.swift` doing steps 1–5 +
  `builder.finalize()` + serve via `WireMVC.serve(on:handler:services:)`. Ships alongside the **`WireMVCRouter`**
  target — the `FinalizableHTTPServerRouteBuilder` refinement + a segment-trie router
  (`TrieRouteBuilder`/`FrozenTrieRouter`, non-generic `RouteTrie` core, 11 tests). A thin
  `WireMVCBootstrapExample` proves it; `WireMVCExample` is the full-matrix self-checker (same trie router).
  **Note:** `swift build --target X` skips the build-tool plugin — a full `swift build` is required.
- **Phase 2 — terminal owns the 500. — ✅ DONE.** Every typed terminal wraps its body in a `do`, and the
  `catch` always ends the chain in a non-optional terminal — a declared catch-all, or the built-in
  `WireMVCOutcome.status(.internalServerError)` — so it never rethrows. Benefits all native routes; only raw
  routes (which own their sender) are exempt.
- **Phase 3 — global `@ErrorResponse` tier. — ✅ DONE.** `WireMVCRouteGen` reads the Bootstrap's
  `@ErrorResponse` once (with its scope diagnostics) and threads `globalErrorMappings` into every route's
  terminal — composed `route + controller + global`, before the binding-error built-in, before the 500.
- **Phase 4 — `@NotFound` fallback handler. — ✅ DONE.** A fallback *handler* on the Bootstrap (the axum
  `.fallback` lineage), registered via `FinalizableHTTPServerRouteBuilder.registerNotFound` before
  `finalize()`; `FrozenTrieRouter` dispatches to it on a miss, its built-in 404 demoted to the
  never-registered safety net. Synth-404 when absent; `@Path` diagnosed. `WireMVCRouteNotFound` dropped.
- **Phase 5 — global `@Middleware` tier, the front layer. — designed + prototyped; wire-mvc codegen + example
  gated on the swift-wire merge.** Runtime (shipped in wire-mvc): `WireDisconnected` (vendored SE-0538 subset)
  + the box `struct`/`Storage`/`withContents` refactor + `GlobalMiddlewareHandler`. swift-wire (this milestone):
  `.liftsPeersToProxy` synthesises the keyless global-middleware proxy that reattributes the root's
  `@Middleware` factories onto itself. wire-mvc codegen (next): `WireMVCRouteGen` emits `wrapGlobalMiddleware`
  on the proxy, the `@main` calls `graph._WireGlobalMiddleware_<Bootstrap>.wrapGlobalMiddleware(handler)`, and
  the by-type diagnostic. *Prototyped:* spikes 24/25 (runtime + generic wrap) + `LiftsPeersToProxy` tests
  (keyless synthesis + reattribution + factory injection). *Validation gate:* a global factory middleware
  runs on a matched route **and** the miss (CI boot-probe), after the swift-wire merge + `swift package update
  swift-wire`.

## Deferred

- **Retire `WireDisconnected` for the stdlib `Disconnected`, when SE-0538 ships.** The front layer runs on
  WireMVC's vendored `WireDisconnected` today (stable features only, independent of the proposal's fate).
  When [SE-0538](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0538-disconnected.md) lands
  in a usable toolchain, swap the ~20-line vendored type for the stdlib `Disconnected<Value>`. A cleanup, not
  a prerequisite. Tracked as **ROADMAP M6e**.
- **By-type global middleware — not supported, and can't be (kept as a diagnostic, not a follow-up).** The
  supported global form is **factory** (`@Middleware(Key)`, generic over the box), folded through the proxy's
  generic `wrapGlobalMiddleware<Handler>`. A by-type `@Middleware(T.self)` is a concrete `Box<Fixed>`
  middleware, which is *impossible* in the non-transforming generic chain (`Box<Handler> → Box<Handler>`): it
  would need a transforming middleware in front to reach `Box<Fixed>`, and global scope forbids that (the
  router is fixed on its box type). So this isn't a deferred feature — it's diagnosed
  (`WireMVCDiagnostic.globalMiddlewareUnsupportedArgument`, inverted from the earlier by-type-only sketch),
  directing the author to write the middleware generic (factory-form), which is the idiomatic shape anyway
  (all of `WireMVCExample`'s reusable middleware are factories).
- **`wrapHandler` pre-router seam** — a Bootstrap method wrapping the router with a request-rewriting handler
  for routing-affecting work (path rewrite / normalization). Sketched above; surfaced when an example forces it.
- **Introspection mount** — a Bootstrap method returning an optional path, its route guarded by a
  `@Middleware`. Not yet implemented; lands with the introspection surface work.
- **Transform-only middleware** (throw ⇒ 500 instead of abort) — the escape hatch in
  [LinearSenderErrorModel.md § escape hatch](Notes/LinearSenderErrorModel.md#the-one-escape-hatch-deferred).
- **Graph-injected `@ErrorResponse` handler** — the dependency-bearing error tier
  ([RouteErrorHandling.md](Notes/RouteErrorHandling.md)); lands when an example forces injected deps in a mapping.

## Validation gate (overall)

`WireMVCExample`'s hand-written `main` collapses to `@WireMVCBootstrap` and serves identically; then,
exercised end-to-end on `NIOHTTPServer`: an unmapped handler throw → 500 (Phase 2), a Bootstrap global
`@ErrorResponse` map (Phase 3), an unmatched route → the `@NotFound` fallback / mapped 404 (Phase 4), and a
global `@Middleware` running on both a matched and an unmatched route (Phase 5).
