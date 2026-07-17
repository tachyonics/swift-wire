# Route error handling — terminal-scoped `@ErrorMap` (M5.4E design record)

> **Status:** settled design, not yet implemented. Iteration **M5.4E** in
> [../M5_PLAN.md](../M5_PLAN.md), interleaved with M5.4. Extends the middleware/box model in
> [WireMVCMiddleware.md](WireMVCMiddleware.md) and the M5.0 surface in
> [WireMVCDesign.md](WireMVCDesign.md). Resolves the plan's "Response surface beyond
> `@JSONResponse` — error→response mapping" open decision.

## The model in one paragraph

Error→response mapping is a **terminal (route/controller) concern**, not a global-middleware one.
A route declares `@ErrorMap`s at controller scope (covering every route) and route scope (one
route), composed **controller-outer → route-inner**, most-specific-wins. They are consulted inside
the terminal's existing `catch` — the same place the shipped witness already turns a
`WireMVCBindingError` into a status (`RouteCodegen.closureBody`) — so a handler that throws a typed
domain error (`NotFound`, a validation failure) has that error mapped to a response written on the
sender the terminal still holds. An **unmapped** throw propagates out of the middleware chain to the
router/server, which produces the default 500. A "global" error map is just the outermost tier of
the same terminal mechanism (a default consulted last), **not** a global middleware.

## Why terminal-scoped, not global middleware — the box forces it

The single load-bearing fact: in the Model-B box, **the sender lives *inside* the box**
(`.pending(request, requestContext, reader, responseSender)`), and calling `next` **consumes the
box**. So an outer middleware that wraps `try await next(input)` in a `do/catch` no longer has the
box — or its sender — on the catch path: the value was moved into `next`, which threw. It can
*observe* the error (log, metric) and rethrow, but it **cannot write a response to it** — there is
structurally no sender in hand.

The **terminal** is the one place that still holds the sender when the handler runs (inside
`withPendingContents { … responseSender … }`), so it is the only place that can convert a thrown
error into a written response. This is the same root as the short-circuit model (a middleware
responds by *writing* via the sender, never by returning a response value): the response is a sender
side-effect, and errors ride the throw channel, which only the sender-holder can turn back into a
response.

The lone exception is a **buffering (erasing) middleware**: one that hands `next` a box with a
*concrete* sender it owns, buffers the downstream response, and flushes on return. Because it kept
the real sender, it *could* respond to a downstream throw — but only by giving up streaming for that
subtree. That is a deliberate, heavy opt-in (already described in
[WireMVCMiddleware.md](WireMVCMiddleware.md)), not the default path, so it doesn't change the rule.

## The `@ErrorMap` surface

- **`@ErrorMap(expr)` at controller and route scope**, mirroring `@Middleware`'s two tiers and
  composition order (controller-outer → route-inner). An error map is a Wire component (its own
  scope/`@Inject` deps), referenced the same way `@Middleware` references its middleware.
- **Consulted in the terminal's `catch`.** The generated terminal already has the shape:

  ```swift
  do {
      // collect body, bind params, call handler, encode
  } catch let wireMVCBindingError as WireMVCBindingError {
      wireMVCOutcome = .status(wireMVCBindingError.status)
  }
  ```

  M5.4E generalises the `catch` to consult the route's composed error maps first (innermost route
  map, then controller map, then the default), each offered the thrown error and yielding an
  optional `WireMVCOutcome`; the binding-error path stays as the built-in innermost map.
- **Type-directed.** An error map matches on the concrete error type it declares (the ecosystem
  precedent — see prior art), so mapping is by Swift type, not string. An unmatched error falls
  through to the next tier and ultimately to the router 500.
- **Most-specific-wins, single producer per status.** Route map overrides controller map overrides
  default; combined with the M5.4 **auth-failure division of labor** (gates write 401/403
  *pre-handler*; error maps map handler-thrown 404/409/422), each status has exactly one producer.

## Scope boundary

- **Raw handlers own their errors.** Once a `@RawRoute` handler starts streaming, the response is
  committed (the box's *no response post-processing* property), so a mid-stream throw cannot be
  remapped. `@ErrorMap` is a typed-terminal concern; a raw handler that wants error responses writes
  them itself before it starts streaming.
- **Not global middleware.** Cross-cutting *observation* of errors (logging, tracing a failure) is a
  normal `@Middleware` that catches-and-rethrows around `next` — it just can't produce the response.
- **Header/status control beyond the mapped status** stays out of M5.4E (the plan's narrow
  status+JSON response surface); grows only when an example forces it.

## Prior art

The design space splits cleanly on **how a framework's handler/middleware yields a response**, which
decides where error handling can live:

- **Return-based stacks** — Vapor `ErrorMiddleware` (global), Spring MVC `@ExceptionHandler`
  (controller) + `@ControllerAdvice` (global), ASP.NET Core exception filters (action/controller/
  global) — can map errors in *outer middleware* **because their response is a returned value**, so
  an outer layer can synthesise one. Their scoping (route/controller/global, most-specific-wins) is
  the model `@ErrorMap` copies; their *placement freedom* (outer middleware) is what our box model
  removes.
- **Effect/sender-based streaming stacks** (ours) push response-writing to where the sender is held.
  The closest precedents are **Rust axum** (`Result<impl IntoResponse, E: IntoResponse>` — a
  type-directed error→response conversion at the handler) and **tapir** (`errorOut` — a typed error
  output declared per endpoint). Both are terminal/route-scoped and type-directed — exactly
  `@ErrorMap`'s shape. http4s' `OptionT`/`Either` error channels are the same lineage.

Takeaway: adopt the **return-based stacks' scoping model** (controller/route/global tiers,
most-specific-wins) but the **effect-based stacks' placement** (at the handler/terminal, type-directed),
because the box model makes the terminal the only sender-holder.

## What this rests on

- **Shipped terminal codegen** — the `do/catch` that already maps `WireMVCBindingError` to a status
  and sends one `WireMVCOutcome` (`Sources/WireMVCCodegen/RouteCodegen.swift`). M5.4E generalises the
  `catch`, it does not add a runtime layer.
- **The Model-B box** — `RequestResponseMiddlewareBox` (`Sources/WireMVC/Middleware.swift`): sender
  inside the box, consumed into `next`, so only the terminal can respond to a throw.
- **The adapter capability axis** — an error map is a graph binding injected onto the route-contributor
  proxy, the same input-edge mechanism `@Middleware` uses (`.injectsFromGraph`); no new Core capability
  is expected, but the exact injection shape is confirmed when M5.4E is built.

## Open questions

- **The error-map protocol surface** — sync/async, whether a map yields `WireMVCOutcome?` (fall
  through on `nil`) vs throws-to-next; how it names the error type it handles pre-expansion (the same
  "plugin-readable, not macro-computed" constraint the role mappings have).
- **Default/global map declaration** — a reserved key consulted last, vs a composition-root argument
  in the M5.5 macro. Interacts with M5.5 only at this thin sliver; the controller/route tiers are
  independent of M5.5.
- **Interaction with request-scope construction failures (M5.4)** — a throw from
  `bootstrap<Seed>Scope` at scope entry is inside the terminal, so it is mappable; confirm the
  generated scope-entry sits inside the `catch`'s `do` so a failed request-scoped binding maps like a
  handler throw rather than escaping to the router 500.
