# WireMVC middleware & the raw handler — M5.2 / M5.3 design record

> **Status:** the settled design for M5.2 (the raw escape-hatch handler) and M5.3
> (middleware). Extends [WireMVCDesign.md](WireMVCDesign.md) (the M5.0 record) and refines the
> M5.2/M5.3 sections of [M5_PLAN.md](../M5_PLAN.md). Proven substrate:
> [spike-12](../../../swift-wire-spikes/spike-12-wiremvc-proposal-native/) (proposal-native
> routing), [spike-13](../../../swift-wire-spikes/spike-13-wiremvc-servertransport-bridge/)
> (the `ServerTransport` bridge), [spike-14](../../../swift-wire-spikes/spike-14-wiremvc-streaming/)
> (streaming). Rests on **shipped** Wire primitives — the `BuilderKey` result-builder fold and
> generic `@Provides` factories — plus one deferred piece (the type-preserving opaque fold; see
> *What this rests on*).

## The model in one paragraph

Every handler — typed or raw — is the **terminal of a middleware chain that projects attributes
off the chain's final box**. Middleware transform the box (`Input → NextInput`); the terminal
reads what it needs out of the final box. `@Path`/`@Query`/`@JSONBody`/`@Header` are *annotated
sub-part* projections; `@JSONResponse`/`@ResponseStatus` write the response via the box's sender;
a raw handler is the *type-identified whole-slot* projection of the reader/sender plus any
capability the chain added. So typed and raw are one mechanism differing only in **which**
attributes they bind, and "type-transforming middleware ⇒ compile error" falls out of the
terminal passing the projected values into the handler's typed parameters — nothing asserts it,
the compiler enforces it.

## The box & projection

- **The box is the proposal's `RequestResponseMiddlewareBox<RequestContext, Reader, ResponseSender>`.**
  It bundles a fixed `request: HTTPRequest`, the capability-typed `RequestContext`, the
  `~Copyable` `Reader`, and the `~Copyable` `ResponseSender`. We reuse it — nothing to invent.
- **Explode = the box's `withContents`.** `consuming func withContents { request, context, reader, sender in … }`
  is the one-shot consuming destructure; the generated terminal calls it. (`@Explode` is only
  for a *custom* box — e.g. one that retypes `request` — where the author supplies the
  destructure; the standard path never writes it.)
- **Enrichment rides `RequestContext`.** A capability is a child protocol of
  `HTTPServerCapability.RequestContext` (e.g. `protocol AuthenticatedContext: RequestContext { var principal: User { get } }`);
  a middleware's output context conforms to the ones it adds. The `request`/`reader`/`sender`
  slots are structural on the standard box; retyping *them* means a custom box (`@Explode`).
- **A projection type-checks against the final box.** The terminal binds each handler param
  from the box; if the folded final box doesn't provide an attribute at the declared type, the
  bind fails to compile. Nothing in the macro resolves middleware output types — it emits
  type-directed projections and defers to the type-checker.

## Middleware = proposal `Middleware` **and** a Wire component

- A WireMVC middleware *is* the proposal's `Middleware<Input, NextInput>` **and** a normal Wire
  component (its own `@Singleton`/`@Scoped` scope, its own `@Inject` deps). `@Middleware(T.self)`
  is a graph reference — nothing new for the binding. Request-scoped middleware come from M5.4
  for free.
- Three graph forms, all folded uniformly:
  1. **Concrete, single instance** — an ordinary concrete binding; its concrete `Input`/`NextInput`
     pin what may precede it, and it can conform its output context by hand (it knows its input).
  2. **Generic, self-producing** — a middleware generic over its input. If it varies per use it
     is a `@Provides` factory in Wire's model (an unconstrained generic `@Singleton` is a
     diagnostic that redirects to `@Provides`).
  3. **Generic `@Provides` factory** — a parameterised factory the fold specialises per position;
     "multiple instances via specialisation."

## Chains = per-route folds

- `@Middleware` at **controller scope** wraps every route; at **route scope** wraps one route;
  composed **controller-outer → route-inner → handler**.
- Each route's chain is a `MiddlewareBuilder` result-builder **fold** over its middleware,
  terminating in the generated terminal. The final box type is **compiler-inferred** from the
  fold (`MiddlewareBuilder`'s `First.NextInput == Second.Input` thread) — the macro never names
  it; the terminal just explodes it via `withContents`.
- This is Wire's shipped **`BuilderKey`** result-builder-fold mechanism (its doc example is
  literally `BuilderKey<MiddlewareBuilder>`), applied per route rather than to one global key,
  with middleware pulled from the graph (concrete binding / specialised factory).

## The compile-time guarantee & forwarding

- **The guarantee is the compiler's.** The terminal calls the handler with the projected values
  (`getUser(request: AuthHttpRequest)`); that call type-checks only if the folded box provides
  the projected capability. Remove the middleware that supplies it → the final box no longer
  conforms → compile error at the handler. Neither the macro nor the plugin asserts this.
- **Forwarding is the plugin's, and it's bounded.** A generic wrapping middleware can't
  enumerate the open set of upstream capabilities to forward — but the **build plugin's global
  view** sees every specialisation the folds actually produce, so it emits exactly the
  conditional-conformance forwarding those need
  (`extension SessionWrap: AuthenticatedContext where Base: AuthenticatedContext { … }`),
  bounded by real co-occurrences. This is the one thing only a global-view plugin can do that a
  plain library can't — watch cross-module conformance coherence (retroactive conformance on
  wrapper types).

## Spelling (pinned)

- **`@RawRoute`** — a func-level marker: greppable, stands in for the "exactly one response
  annotation per route" invariant (raw = the handler writes its own response), and flips param
  binding from annotation-required to type-identified.
- **Separate destructured params**, not one box param. The macro proves the `consuming`
  projections are disjoint.
- **Raw params are type-identified** (`reader`/`sender` by their `~Copyable` types; a capability
  by its protocol type); **typed params keep their annotations** (`@Path`/`@JSONBody` — decoded
  sub-parts are genuinely ambiguous, so they must be annotated). Unified: "type-identified vs
  annotated projections of the same box." (Not pure signature-detection — a bare "has a sender
  param ⇒ raw" would leave the route with no greppable response annotation, which the design
  rule forbids.)
- Residual: "whole-slot by type" is really "by type *spelling*" for a syntactic macro; an
  aliased `ResponseSender` is where a minimal marker (or requiring the canonical spelling) might
  return.

## Who does what

For a controller with two controller-scope and two route-scope middleware on a typed route:

- **You** — declare the controller + scope, the route, the response mode, and the two tiers of
  `@Middleware`.
- **`@Singleton` / Wire graph** — makes the controller (and each middleware) a graph binding /
  factory and constructs them (lift-the-minimum).
- **`@Controller` macro** — aliases to `@Contributes(to: WireMVCKeys.routeContributors)`,
  generates the `RouteContributor` witness, and reads the controller-scope `@Middleware` as the
  outer wrapping for every route.
- **`@Get`/`@JSONResponse`/route `@Middleware`** — synthesise this route's fold
  (`[ctrl-outer…, route-inner…]` through `MiddlewareBuilder` → terminal) and the terminal
  (explode → project → call handler → encode the return via the sender).
- **Wire build plugin** — emits the graph + folds, specialises generic middleware, and emits the
  forwarding conformances for the specialisations the folds surface.
- **Swift compiler** — threads the fold, infers the final box, and enforces the projection
  type-check (the guarantee).
- **Proposal runtime (per request)** — the server hands the base-box ingredients; the fold's
  `intercept` runs the middleware in order; the terminal explodes, projects, calls the handler,
  and writes the response.

Request flow: `base box → ctrl-mw… → route-mw… → [ explode → project → handler → encode ] → response`.

## What this rests on

- **Shipped Wire:** generic `@Provides` factories (demand-driven specialisation, dedup,
  ambiguity diagnostics) and the [`BuilderKey`](BuilderKeyDesign.md) result-builder fold. The
  adapter contract stays `@Contributes` — WireMVC does **not** need a new "inject arbitrary
  bindings" power; the fold is Wire-generated from a contribution, and the middleware are
  ordinary user-declared bindings.
- **Shipped proposal:** `Middleware`/`ChainedMiddleware`/`MiddlewareBuilder`,
  `RequestResponseMiddlewareBox` + `withContents`, `HTTPServerCapability.RequestContext`.
- **The one unbuilt piece:** the type-preserving **opaque** `BuilderKey` fold — a per-chain
  `some Middleware<BaseBox, FinalBox>` where `FinalBox` varies. The shipped fold produces a
  *fixed* result; a fixed/erased `[any Middleware]` fold would throw away the type-thread the
  guarantee depends on. `BuilderKey`'s own doc defers exactly this ("the parameterised-opaque
  case … is deferred to [OpaqueTypesSupport](OpaqueTypesSupport.md)"); it's de-risked (spike-7
  Proof 2 proved parameterised-opaque lifting) but not yet emitted — the M5.5-earmarked
  "`BuilderKey`→opaque-member fold," now pulled forward as M5.3's dependency. **This is the
  single build item this design adds beyond shipped machinery.**

## Open sub-decisions

- `@Explode` vs `@Explode` + a capability-declaration attribute — one attribute or two (the
  write-side sugar for custom boxes; the common path uses neither).
- The whole-slot type-spelling fragility above (canonical spelling vs a minimal marker).
- Per-route folds vs a small number of deduplicated chain bindings (an optimisation, not a
  correctness question).
