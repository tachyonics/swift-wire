# WireMVC design — M5.0 decision record

> **Status:** the settled M5.0 surface for `WireMVC` (the cross-framework
> declarative-routing adapter). Supersedes the older
> [WireMVCAbstraction.md](WireMVCAbstraction.md) (built on the retired
> `_wireRegister` model — its full rewrite is M5.6). The milestone sits in
> [ROADMAP.md](../../ROADMAP.md); the iteration plan is [M5_PLAN.md](../M5_PLAN.md).
> The shape here is proven by
> [spike-11](../../../swift-wire-spikes/spike-11-wiremvc-servertransport/) — a
> hand-written `@Controller` witness registering decoded handlers on real
> `ServerTransport`, served in-process.

The headline, unchanged from the plan: WireMVC is a **spec-free, annotation-driven
analogue of the OpenAPI generator's registration codegen**. `@Controller`/verb/param/
response annotations fold into M3's `ServerTransport` collation surface; because the
target is `some ServerTransport`, controllers mount cross-runtime unchanged.

## Decisions

### Target protocol — `some ServerTransport` (standardised)

WireMVC registers routes on `some ServerTransport` (`swift-openapi-runtime`). It's the
proven Swift shape (swift-openapi-generator targets exactly it), cross-runtime for free,
already Wire's shipped collation primitive (M3's `TransportContributor`), and
dispatch-agnostic. **Not a permanent wedding:** the route-descriptor table (below) is the
portability layer, so the transport is a swappable backend (the `TransportContributor`
witness parameter swaps). The `swift-http-api-proposal` server surface (`HTTPServer` /
`HTTPServerRequestHandler`, `anyAppleOS 26.0` / Swift 6.4) is the **tracked successor**
behind the same seam — a *Router* sits on top of `serve` in that world too, so WireMVC
still does per-route registration, never reimplements routing. Cost accepted: a light,
stable, OpenAPI-*branded* dependency (`OpenAPIRuntime`) for a non-OpenAPI adapter.

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
- It is a `@Contributes(to: TransportKeys.handlers)` **alias** — no new contract.
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

### Middleware (spelling only — protocol is M5.3)

- `@Middleware(expr)` repeatable at controller + route scope; composed source-order,
  controller-outer → route-inner → handler. The concrete middleware *protocol* is the M5.3
  decision (a WireMVC-defined decoded shape modeled on the proposal's forward-transform +
  terminal pattern).

## Deferred (explicitly not M5.0)

- Raw escape-hatch handler spelling (`@RawRoute` vs signature-detected) → **M5.2**.
- Content negotiation beyond JSON, and content-type routing between handlers → future
  capability off the route-descriptor table.
- Streaming / SSE / WebSocket → raw handler (M5.2).
- Typed error→response mapping, response header/cookie control → later.
- `@Head` / `@Options` verbs → later or via the raw handler.

## The generated shape (from spike-11)

Per route, the macro emits one `transport.register` call with a thin closure; decode/
encode/status logic lives in a WireMVC runtime support layer the closure calls:

```swift
// @Get("/{id}") @JSONResponse  →  200, JSON body
try transport.register(
    { _, _, metadata in
        let id = String(metadata.pathParameters["id"] ?? "")          // @Path id
        let result = try await self.getUser(id: id)
        return try WireMVCResponse.json(result, status: .ok)          // @JSONResponse
    },
    method: .get,
    path: "/users/{id}"                                               // prefix + subpath
)
```

See [spike-11](../../../swift-wire-spikes/spike-11-wiremvc-servertransport/) for the full
hand-written witness (all six surface behaviors served in-process).
