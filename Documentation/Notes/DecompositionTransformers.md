# Decomposition transformers — pluggable parameter bindings, `@Configuration`, explicit `@RawRoute` roles

> **Status:** forward-looking design, not implemented. This is the "Phase B" of the WireMVC codegen
> foundation — the one thread that was designed but deliberately deferred while the macro→plugin move
> (Phase A) landed. Phase A is **done** (the completed sequencing is archived in
> [Archive/WireMVCCodegen.md](../Archive/WireMVCCodegen.md)); this builds directly on it, because the
> plugin now *owns* route-witness generation and so can consult a registered set of transformers. Design
> record for the routing surface it extends: [WireMVCMiddleware.md](WireMVCMiddleware.md),
> [WireMVCDesign.md](WireMVCDesign.md).

> **Scoping (M5 sequencing — decided).** This note covers **two separable efforts**, not one
> monolith:
> - **1c — explicit concrete `@RawRoute` roles** (`@RawRoute(.requestContext, .responseSender)`): a
>   **contained, near-term** feature in the `@MiddlewareFactory` positional-role mould. Forced by the
>   first *transformed-slot* streaming example (a sender-transforming middleware handing a handler a
>   concrete `JsonMultiPartSender`, or a concrete enriched context) — because the generic-constraint
>   substitute forces a complete refinement protocol and there is **no `as?` rescue for a `consuming`
>   `~Copyable` value**, so the concrete spelling is effectively demanded, not merely nicer. Ships
>   **with that example** (iteration M5.4R), independently of the rest, and restores a compile-time
>   coupling (naming the concrete slot forces the producing middleware present).
> - **1a/1b — the transformer registry + `@Configuration` + B-typed named projection**: the full
>   pluggable-decomposition subsystem. **Deferred** — the auth cluster does *not* force it, because
>   M5.4 routes middleware-produced / request-scoped values to handlers via **A-inject**
>   (request-scope injection), not handler-parameter projection off the box. Lands when
>   `@Configuration` forces it, or on a deliberate decision to buy the `@Principal`-style
>   typed-handler surface. See [../M5_PLAN.md](../M5_PLAN.md) (M5.4 decision) and
>   [RouteErrorHandling.md](RouteErrorHandling.md).
>
> The mechanism sketch below is the *unifying* design (all of these are one transformer protocol);
> the scoping above is which slice ships when.

## The idea in one line

A handler parameter binding — `@Path`, `@Query`, `@Header`, `@JSONBody`, and a future
`@Configuration(binding, "config.item.path")` — is really a **decomposition transformer**: a
`(input type, config) → value` step that pulls one handler argument out of whatever the route hands it.
Today these are **enumerated in the macro** (`bindingWrappers`); making them a **registered, discovered
set the plugin consults** is what turns "add a binding" from "edit the macro" into "declare a
transformer," and folds `@Configuration` into the same mechanism instead of bolting on a parallel path.

## Why it belongs to the plugin (and so, to now)

While generation lived in the `@Controller` macro, the binding set had to be hardcoded — the macro can't
see a registry. Phase A moved generation into the plugin, which already discovers adapter capabilities by
their annotation contract. A decomposition transformer is the same shape as the capabilities the plugin
already reads (contribute / inject / map-roles / contributes-proxy): a binding **registers** a
transformer; the generator **attaches** it as a parameter binding when it emits the witness. The
enumerated `@Path`/`@Query`/`@Header`/`@JSONBody` become the first four registered instances rather than
a closed list.

## Keyed by the input type the handler receives

The current bindings assume the input is a `RequestResponseMiddlewareBox` and decompose *that* (to a path
parameter, a header, a JSON body). But a **transforming** middleware can hand the terminal a *different*
final box — the terminal's requirement is only *structural* (a `withPendingContents(request, context,
reader, sender)` shape), **not** "the final box is a `RequestResponseMiddlewareBox`" (proven by
[spike-21](../../../swift-wire-spikes/spike-21-wiremvc-transforming-rawroute/): `Box<Ctx>` →
`Box<AuthContext>`, read by a raw terminal off the final box's `withPendingContents`). So the general
form is **decomposition keyed by the input type the handler actually receives** — a transformer declares
which input types it can decompose, and the generator dispatches on the handler's real input.

## The concrete case that forces this: `@RawRoute` roles

`@RawRoute` role detection **cannot be inferred for concrete parameters.** The macro identifies
context/reader/sender by *generic-constraint substring* (`rawGenericRoles`), so a concrete role parameter
falls through to `unsupportedRawParameter`, and no heuristic can rescue it — only **conformance** would,
which a syntactic macro can't check. Examples that fail today:

- `stream(requestContext: AuthRequestContext, responseSender: consuming Sender)` — a concrete enriched
  context (downstream of a transforming middleware);
- `jsonMultipart(responseSender: consuming JsonMultiPartSender)` — a concrete sender.

The robust answer is **explicit, positional roles** — `@RawRoute(.requestContext, .responseSender)` — i.e.
a decomposition-transformer instance naming which register-closure primitive each parameter takes.
`HTTPRequest` / `[String: Substring]` stay type-detected; roles only ever concern context / reader /
sender. This is the same "explicit ordered roles over a fragile heuristic" resolution `@MiddlewareFactory`
reached for the box roles (see [Archive/WireMVCCodegen.md](../Archive/WireMVCCodegen.md), *3.2*).

## Sketch of the mechanism

- A **transformer protocol** — a uniform `(input type, config) → value` decomposition — plus a
  registration/discovery path in the adapter-annotation style, so a binding opts in the way a capability
  does today.
- The generator, per handler parameter: find the transformer whose input type matches the handler's real
  input, hand it the parameter's config (the annotation's literal arguments), and emit its decomposition
  into the witness — exactly where `Path<T>.bind(…)` / `Query<T>.bindOptional(…)` are emitted now.
- `@RawRoute(.role, …)` and `@Configuration(binding, "path")` are two instances of the same protocol; the
  four existing wrappers are four more.

## Open questions

- The transformer protocol's exact surface (sync/async, throwing, how config literals are carried
  pre-expansion — the same "must be plugin-readable, not macro-computed" constraint the role mapping has).
- Whether `@Configuration` decomposition reads its source (config item path) at generation time or defers
  to a runtime resolver injected from the graph.
- Registration ergonomics — one adapter-capability case for "declares a decomposition transformer," vs a
  richer descriptor.
