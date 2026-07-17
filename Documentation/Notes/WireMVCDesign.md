# WireMVC design — M5.0 decision record

> **Status:** the settled M5.0 surface for `WireMVC` (the cross-framework
> declarative-routing adapter). Supersedes the older
> [WireMVCAbstraction.md](WireMVCAbstraction.md) (built on the retired
> `_wireRegister` model — its full rewrite is M5.6). The milestone sits in
> [ROADMAP.md](../../ROADMAP.md); the iteration plan is [M5_PLAN.md](../M5_PLAN.md).
>
> **Update — proposal-native pivot (reconciled below).** M5.0 originally standardised on
> `some ServerTransport` (OpenAPIRuntime) as the core target, with the
> `swift-http-api-proposal` server surface named the *tracked successor* behind the same
> seam. That successor is now the **core**, ahead of the planned timeline: deploying against
> macOS 26 makes `anyAppleOS 26.0` unconditional, so Wire's ungated generated code compiles
> against the proposal's server API today. WireMVC registers routes on
> `RoutableHTTPServerBuilder` (over the proposal's `HTTPServer`/`HTTPServerRequestHandler`);
> `some ServerTransport` is **retained as an opt-in adapter** (`WireMVCServerTransport`,
> behind a `ServerTransport` package trait) so Hummingbird/Vapor still mount the same
> controllers. The inversion is proven by
> [spike-12](../../../swift-wire-spikes/spike-12-wiremvc-proposal-native/) (routing over
> `HTTPServer.serve`), [spike-13](../../../swift-wire-spikes/spike-13-wiremvc-servertransport-bridge/)
> (the `ServerTransport` bridge), and
> [spike-14](../../../swift-wire-spikes/spike-14-wiremvc-streaming/) (streaming through both).
> [spike-11](../../../swift-wire-spikes/spike-11-wiremvc-servertransport/) remains the
> proof of the decoded-witness *shape* (decode → call → encode); only its registration
> target moved from `transport.register` to `builder.register`.
>
> **Update — codegen mechanism (M5.3, reconciled below).** Two things were refined after M5.0.
> (1) Route-witness **generation moved from the `@Controller` macro to the build plugin** — where this
> record says "the macro emits/generates," that codegen is now plugin-owned (`@Controller` is a marker;
> WireGen emits the route-contributor proxy struct and WireMVC's `WireMVCRouteGen` emits the witness).
> (2) The `@Controller` alias became **`.contributesProxy(to:)`** — the controller stays a plain binding
> and the plugin contributes a generated proxy in its place, so the "no new contract" note under
> *Controller & scope* no longer holds. Both are recorded in
> [Archive/WireMVCCodegen.md](../Archive/WireMVCCodegen.md); the M5.0 **surface** decisions below are
> otherwise unchanged.

The headline, unchanged: WireMVC is a **spec-free, annotation-driven analogue of the OpenAPI
generator's registration codegen**. `@Controller`/verb/param/response annotations fold into a
Wire collation surface (`WireMVCKeys.routeContributors`); because the target is the proposal's
**routing-surface protocol** rather than any one framework, controllers mount cross-runtime
unchanged — natively on the proposal server, and on Hummingbird/Vapor through the
`ServerTransport` adapter.

## Decisions

### Target protocol — `RoutableHTTPServerBuilder` over the proposal server (adapter for `ServerTransport`)

WireMVC registers routes on **`RoutableHTTPServerBuilder`** — a small WireMVC-owned
per-route registration surface parameterised over the proposal server's associated
`RequestContext` / `Reader` / `ResponseSender`, so a *Router* built on the proposal's
`HTTPServer.serve(handler:)` conforms to it and WireMVC never reimplements routing. The
genericity is on the **contributor's method** (`registerWireRoutes<Builder: RoutableHTTPServerBuilder>`),
not the contributor type, so `any RouteContributor` still boxes and collates through Wire's
`CollectedKey` (below), while the builder keeps the server's `~Copyable` streaming
associated types and is never boxed. (Superseded decision: M5.0 first standardised on
`some ServerTransport`; see the pivot banner. The core no longer depends on `OpenAPIRuntime`
at all — that dependency moved to the opt-in adapter.)

**`some ServerTransport` is retained as an opt-in adapter.** `WireMVCServerTransport` (a
separate module behind the `ServerTransport` package trait, off by default so the core
resolves proposal-only) bridges the same proposal-native controllers onto a
`some ServerTransport`, so Hummingbird/Vapor mount them via `swift-openapi-hummingbird` /
`swift-openapi-vapor` unchanged. The `ServerTransport` register closure is
`request → (HTTPResponse, HTTPBody?)`; the bridge fabricates a proposal `Reader` from the
request `HTTPBody?` and a `ResponseSender` that feeds the response `HTTPBody` (streaming —
see [spike-14](../../../swift-wire-spikes/spike-14-wiremvc-streaming/)). This inverts the
original cost: OpenAPIRuntime is now a dependency only of the adapter a consumer explicitly
opts into, not of the core.

**Not a permanent wedding either way:** the route-descriptor table (below) stays the
portability layer, so the registration backend (`builder.register` for the proposal server,
`transport.register` inside the adapter) is swappable off the same descriptors.

### Dispatch — dynamic registration now; static-capable by construction

Register routes on a runtime router/transport (dynamic dispatch) — the proven norm
(swift-openapi-generator, axum, Hummingbird, …; genuine compile-time *dispatch* is rare —
essentially only Go's `ogen` and Play). Route-conflict/exhaustiveness detection comes from
the **build plugin's global view**, not from generated dispatch, and WireMVC's plugin
already has that. **Design rule:** the macro's source-of-truth artifact is the **route
descriptor table** (method, path, param decode, handler ref, middleware chain); a *dynamic
backend* (emit `register` calls) ships now, an optional *static backend* (one generated
dispatch) and **content-type routing between handlers** are future capabilities derivable
off the same table. Do not make "emit `register` calls" the macro's only output.

### Controller & scope

- `@Controller` — the annotation name (generic, per Spring/Micronaut/NestJS prior art;
  the framework-specific adapters keep their qualified `@HummingbirdController` /
  `@OpenAPIController` names — the portable surface earns the plain one).
- It is a `@Contributes(to: WireMVCKeys.routeContributors)` **alias** — no new contract.
  (WireMVC uses its own collated key rather than re-homing into M3's `TransportKeys.handlers`,
  because its witness registers on `RoutableHTTPServerBuilder`, not `some ServerTransport`;
  the two surfaces still coexist on one graph — see the plan's *task-cluster* note.)
- **Requires an explicit scope** (`@Singleton` → app-scope, M5.1; `@Scoped(seed:)` →
  request-scope, M5.4). Bare `@Controller` with no scope is a diagnostic.
- **Optional path prefix:** `@Controller("/users")` groups and verb subpaths append; bare
  `@Controller` with the full path on each verb is also allowed.

### Routes & methods

- Verbs: `@Get` / `@Post` / `@Put` / `@Patch` / `@Delete`; one verb per func.
- Path templates use `{name}` placeholders (matches `ServerTransport`/OpenAPI path
  strings). Wildcards/catch-alls deferred (the raw handler covers them).

### Handler params (request inputs)

- Every handler param carries a **source** annotation — `@Path` / `@Query` / `@JSONBody` /
  `@Header`; an unannotated param is a diagnostic. Only the **name string** is inferred
  from the parameter, never the source (guessing path-vs-query is unsafe): `@Path id`
  binds `{id}`, `@Path("user_id") id` overrides. Dependencies come via controller
  `@Inject` properties, not handler params.
- **Optionality & defaults via Swift-native** optionals/defaults, not annotation args:
  `@Query page: Int = 1`, `@Query filter: String?`.
- **String → typed conversion via `LosslessStringConvertible`**, with WireMVC adding
  conformances for common non-conformers (`UUID`, …); a custom type conforms to
  participate. (Matches Vapor; no converter registry — a language feature, not framework
  magic.)
- `@JSONBody` — the request-body annotation names the codec, symmetric with
  `@JSONResponse`. Rationale: WireMVC fixes the decoder at codegen (no runtime content
  negotiation), so a generic `@Body` would falsely imply negotiation; the statically-typed
  prior art (axum/Rocket `Json<T>`) names the codec too, just in the type. At most one
  `@JSONBody` per handler. Future `@FormBody` / `@MultipartBody` are siblings.

### `@JSONBody` content-type handling (the validate model)

Naming the codec on the param gives the **axum/validate model** (one handler, validated),
not the JAX-RS/Rocket route-between-handlers model — which also yields the *correct* status
(Rocket's routing model collapses "wrong type" into 404):

- Contradictory `Content-Type` → **415 Unsupported Media Type**.
- **Missing** `Content-Type` → **lenient**: attempt the JSON decode anyway (only a
  *contradictory* type is rejected — greenfield-friendly, avoids axum's 415-on-missing).
- Malformed / undeserializable JSON → **422 Unprocessable Content**.

Multi-content-type on one route, if ever wanted, is the future capability above: sibling
handlers by codec, routed by the plugin with **compile-time** collision detection and the
correct 415/406 (better than Rocket's launch-time / 404).

### Responses — one annotation per route, validated against the return type

Every route declares **exactly one** response annotation; the macro validates it against
the signature. No route relies on an implicit status.

- `@JSONResponse[(status:)]` — has an `Encodable` body, JSON-encoded, default `200`.
  Error on a `Void` func.
- `@ResponseStatus(_)` — no body, status only, for `Void` funcs. **The status argument is
  always required for now** (no bare default); this can be relaxed after feedback —
  loosening a rule is non-breaking, tightening isn't. Error on a body-returning func.
- A `Void` func with no response annotation is a diagnostic ("add `@ResponseStatus`").

This makes every route's response mode a visible, greppable annotation (the reason
explicit `@JSONResponse` was chosen over JSON-by-default), and dissolves the 200-vs-204
*silent-default* debate — nothing is implicit. (Prior art: the required-annotation
discipline is JAX-RS/OpenAPI-flavored; `@ResponseStatus` is the Spring name.)

### Handler shape & errors

- `async` / `throws` / sync / non-throwing handlers all supported; the generated witness
  awaits / `try`s as needed.
- Thrown error → **500** baseline in M5 core; typed error→response mapping deferred.

### Middleware (spelling here; full model settled in M5.3)

- `@Middleware(expr)` repeatable at controller + route scope; composed source-order,
  controller-outer → route-inner → handler. The middleware *is* the proposal's `Middleware`
  (a Wire component referenced from the graph); each route's chain is a `MiddlewareBuilder` fold
  and every handler is its terminal, projecting params off the fold's final box. The full
  record — box projection, capabilities, folds, `@RawRoute`, plugin-generated forwarding — is
  [WireMVCMiddleware.md](WireMVCMiddleware.md).

## Deferred (explicitly not M5.0)

- Raw escape-hatch handler spelling → **M5.2, decided: `@RawRoute`** (see
  [WireMVCMiddleware.md](WireMVCMiddleware.md)).
- Content negotiation beyond JSON, and content-type routing between handlers → future
  capability off the route-descriptor table.
- **Streaming / SSE → raw handler (M5.2).** The `RoutableHTTPServerBuilder` handler already
  hands the raw proposal primitives (`consuming sending Reader` / `ResponseSender`) to the
  closure, so the raw escape hatch *is* that signature with decode/encode skipped —
  [spike-14](../../../swift-wire-spikes/spike-14-wiremvc-streaming/) streams SSE end-to-end
  both natively and through the `ServerTransport` adapter (with real backpressure), so
  streaming needs **no** framework-specific adapter.
- **WebSocket → escape-to-framework, not a WireMVC route.** An upgrade is not a
  request→response body; neither the proposal server's handler model nor `ServerTransport`'s
  `register → (HTTPResponse, HTTPBody?)` expresses it, so no transport-level adapter (generic
  or framework-specific) carries it. WebSocket routes are registered directly on the
  framework and WireMVC coexists — unless/until the proposal *and* OpenAPIRuntime both grow
  upgrade support.
- Typed error→response mapping, response header/cookie control → later.
- `@Head` / `@Options` verbs → later or via the raw handler.

## The generated shape (from spike-12)

Per route, the macro emits one `builder.register(method:path:handler:)` call with a thin
closure; decode/encode/status logic lives in a WireMVC runtime support layer the closure
calls. The handler receives the matched path parameters plus the proposal's `~Copyable`
streaming reader and response sender:

```swift
// @Get("/{id}") @JSONResponse  →  200, JSON body
builder.register(
    method: .get,
    path: "/users/{id}",                                              // prefix + subpath
    handler: { _, pathParameters, _, responseSender in
        let id = String(pathParameters["id"] ?? "")                   // @Path id
        let result = try await self.getUser(id: id)
        try await WireMVCResponse.json(result, status: .ok, on: responseSender)  // @JSONResponse
    }
)
```

The witness that carries these registrations is `registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on:)`
— generic over the builder, with the `~Copyable` inverse requirements restated at the generic
boundary (they don't propagate; the proposal's own `serve` does the same). See
[spike-12](../../../swift-wire-spikes/spike-12-wiremvc-proposal-native/) for the full
hand-written witness served on a real `NIOHTTPServer`, and
[spike-13](../../../swift-wire-spikes/spike-13-wiremvc-servertransport-bridge/) for the same
witness driven through `some ServerTransport`. spike-11's decode/encode logic is unchanged;
only the registration target moved from `transport.register` to `builder.register`.
