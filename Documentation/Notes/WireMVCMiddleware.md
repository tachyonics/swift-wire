# WireMVC middleware & the raw handler — M5.2 / M5.3 design record

> **Status:** the settled design for M5.2 (the raw escape-hatch handler) and M5.3
> (middleware). Extends [WireMVCDesign.md](WireMVCDesign.md) (the M5.0 record) and refines the
> M5.2/M5.3 sections of [M5_PLAN.md](../M5_PLAN.md). Proven substrate:
> [spike-12](../../../swift-wire-spikes/spike-12-wiremvc-proposal-native/) (proposal-native
> routing), [spike-13](../../../swift-wire-spikes/spike-13-wiremvc-servertransport-bridge/)
> (the `ServerTransport` bridge), [spike-14](../../../swift-wire-spikes/spike-14-wiremvc-streaming/)
> (streaming), and [spike-15](../../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/)
> (the fold + capability forwarding). The middleware fold is **witness-local concrete** codegen over
> the proposal's `Middleware`/`MiddlewareBuilder`, resting on generic `@Provides` factories; spike-15
> corrected an earlier draft that expected a `BuilderKey` *opaque* fold (not expressible — see
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

- **The box is `RequestResponseMiddlewareBox<RequestContext, Reader, ResponseSender>`, WireMVC-owned
  but structurally the proposal's.** It bundles a fixed `request: HTTPRequest`, the capability-typed
  `RequestContext`, the `~Copyable` `Reader`, and the `~Copyable` `ResponseSender`. **Correction
  (grounding for 4a):** the proposal's own `RequestResponseMiddlewareBox` lives *only* in the
  `HTTPClientConformance` **test module** (under `HTTPServerForTesting`) and is referenced by nothing
  — not the test server, not any example; that module also drags in the whole NIO server stack, so it
  is not a viable runtime dependency for WireMVC's framework-agnostic core. WireMVC therefore ships an
  **identical** box in its own runtime module (the exact shape spike-15 vendored: `init` +
  `withContents<T>`). Middleware stay the proposal's `Middleware` (the shippable `Middleware` module —
  protocol + `MiddlewareBuilder` + `ChainedMiddleware`); only the `Input`/`NextInput` box type is
  WireMVC's. There is no proposal-native middleware pipeline to be incompatible with (the box is
  unused upstream), so owning it is free. [spike-16](../../../swift-wire-spikes/spike-16-wiremvc-generic-fold/)
  confirms the fold over this box compiles when parameterised on a *generic* builder's associated types.
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
  component (its own `@Singleton`/`@Scoped` scope, its own `@Inject` deps). `@Middleware(…)` names a
  middleware *type* (see the naming record below — a generic type can't be named `T.self`, so it takes
  placeholder type args). Request-scoped middleware come from M5.4 for free.
- Three forms (revised — see *`@Middleware` naming, dispatch & the fold* below for what actually
  type-checks):
  1. **Concrete** — `@Middleware(Concrete.self)`, constructed inline. A fully concrete middleware pins
     its box, so it fits *only downstream of an erasing middleware* (one whose `NextInput` is a concrete
     box); it can never unify with the generic base box. Real, but a niche position.
  2. **Generic** — `@Middleware(Generic<WireContext, WireReader, WireSender>.self)`. The common form;
     dep-free ones construct inline (no graph). Both non-transforming and context-transforming.
  3. **Generic with `@Inject` deps** — same spelling, but the plugin synthesises a hidden factory (the
     metatype-parameter form below) and lifts it onto the controller. The one form needing a swift-wire
     change; deferred past 4a.

## Chains = per-route folds

- `@Middleware` at **controller scope** wraps every route; at **route scope** wraps one route;
  composed **controller-outer → route-inner → handler**.
- Each route's chain is a `MiddlewareBuilder` result-builder **fold** over its middleware,
  terminating in the generated terminal. The final box type is **compiler-inferred** from the
  fold (`MiddlewareBuilder`'s `First.NextInput == Second.Input` thread) — the macro never names
  it; the terminal just explodes it via `withContents`.
- **The fold is witness-local concrete codegen, not a graph binding** — proven by
  [spike-15](../../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/). It is *not* a
  `BuilderKey` fold: `BuilderKey` yields a binding whose type must be nameable/opaque, but
  `Middleware` has two primary associated types (`Input`, `NextInput`) that can't be partially
  bound, so "pinned input, opaque output" is not expressible. So the chain is built inline in the
  route witness (where the final box stays concrete-inferred and `withContents` works), with the
  *middleware* pulled from the graph (concrete binding / specialised factory).

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

## `@Middleware` naming, dispatch & the fold — 4a implementation record

Building 4a surfaced constraints the conceptual design didn't anticipate. All findings validated by
[spike-16](../../../swift-wire-spikes/spike-16-wiremvc-generic-fold/) and the wire-mvc implementation.

**The naming problem.** A composable middleware must be generic over the box (`<Ctx, Reader, Sender>`)
to sit at any position — the reader/sender are irreducibly the *server's* associated types (the live
body stream and connection writer; not concretizable without buffering + an existential `~Copyable`
sender, which isn't expressible). But a **generic type can't be named `Generic.self`** — no metatype
without type arguments. Two rescue attempts also failed: a factory *method* can't be explicitly
specialized (`Factory.make<…>()` → "cannot explicitly specialize static method"), and a wrapping
`around(next:)` observer can't capture-and-consume the `~Copyable` box values in its nested closure.

**The dispatch (what the `@Controller` macro emits), by argument syntax:**
- `@Middleware(Concrete.self)` — no generic args → construct inline `Concrete()`. A concrete middleware
  pins its box, so it only unifies **downstream of an erasing middleware** (a generic middleware whose
  `NextInput` is a *concrete* box: it buffers/adapts the server's reader+sender, runs the concrete
  downstream chain, then flushes the result into the real sender on return — trading streaming for
  concreteness, by choice). Proven end-to-end.
- `@Middleware(Generic<WireContext, WireReader, WireSender>.self)` — generic args → strip them, re-spell
  as `Generic<Builder.RequestContext, Builder.Reader, Builder.ResponseSender>()`. Inference does **not**
  flow backward through the fold, so the type args must be spelled; and the placeholder types
  (`WireContext`/`WireReader`/`WireSender`, shipped by WireMVC, never instantiated) exist only so the
  annotation's metatype type-checks. This is the common form. Dep-free → inline construction, **no
  swift-wire change**.
- `@Middleware(someKey)` — not `.self` → diagnosed. Referencing a bound middleware by key needs graph
  injection into the witness; deferred (see below).

**The fold, per route** (built inline in `registerWireRoutes`, witness-local concrete): build the base
`RequestResponseMiddlewareBox` from the register closure's `(request, requestContext, reader,
responseSender)`, `wireCompose { … }` the middleware (controller-outer → route-inner), then
`intercept(input: baseBox) { finalBox in finalBox.withContents { … terminal … } }`. Routes with no
`@Middleware` keep the direct path (conditional emission — internal witness shape, not user surface).

**The `sending` relaxation (load-bearing correctness fix).** The box's `withContents` can only yield
plain `consuming` values (its stored fields aren't provably in a disconnected region — the proposal's
box yields `consuming` for exactly this reason). But `RoutableHTTPServerBuilder.register` hands the
witness `consuming sending` reader/sender at the boundary, and the terminal's consumers were declared
`consuming sending` to match. Through a fold the sender/reader arrive from `withContents` as plain
`consuming`, so those consumers must **not require `sending`**. Fix: `WireMVCOutcome.send(on:)` and
`WireMVCRequest.collectBody` take `consuming` (not `consuming sending`), and **`@RawRoute` handlers take
`consuming` too** (a raw handler streams within its own region; `consuming` works both directly and
through a fold). A `sending` value still passes fine to a `consuming` parameter, so the no-middleware
and raw-direct paths are unaffected. This refines the M5.2 raw-handler contract: `consuming`, not
`consuming sending`.

**Generic-with-deps: the metatype-parameter factory.** The deferred piece. The factory's `make` takes
the box types as **metatype parameters** — `make(_: Ctx.Type, _: R.Type, _: S.Type) -> Mw<Ctx,R,S>` —
so the specialization is *inferred from arguments*, sidestepping the forbidden explicit method
specialization. This also **fixes the design's own factory** (whose `make<In>()` would not have
compiled). The developer never writes a factory: the plugin reads the middleware's `@Inject` deps,
emits the factory, lifts it onto the controller (macro-generated `@Inject` is invisible to Wire's
plugin, so the plugin must do the lift), and the witness calls `self._factory.make(Builder.RequestContext.self, …)`.
This is the one swift-wire Core change; everything above ships as 4a with no swift-wire change.

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
  ambiguity diagnostics). The adapter contract stays `@Contributes` — WireMVC does **not** need a
  new "inject arbitrary bindings" power; the middleware are ordinary user-declared bindings, and
  the chain fold is witness-local codegen that references them (not a contributed binding).
- **Shipped proposal:** `Middleware`/`ChainedMiddleware`/`MiddlewareBuilder`,
  `RequestResponseMiddlewareBox` + `withContents`, `HTTPServerCapability.RequestContext`.
- **No opaque fold to build — corrected by
  [spike-15](../../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/).** An earlier
  draft named the type-preserving *opaque `BuilderKey` fold* as the one unbuilt piece. spike-15
  found it is **not expressible**: `Middleware`'s two primary associated types can't be partially
  bound, so a fold can't be returned through a `some Middleware`-with-pinned-input boundary. The
  fold is therefore **witness-local concrete** (which spike-15 proves works end-to-end with the
  real proposal types), so it is *not* a `BuilderKey`/opaque-member fold and there is nothing
  opaque to emit. The one Core-codegen item the design reduces to is the **generic-middleware
  factory object** — see the next section.
- **Codegen detail (spike-15):** every plugin-generated forwarding conformance must restate
  `& ~Copyable` in its `where` clause (`extension …: Cap where Base: Cap & ~Copyable`) or Swift
  silently re-imposes `Copyable` and it fails to compile.

## Generic middleware: the factory-object extension

For multi-stage chains, middleware are generally **generic over their input box** (a middleware
pinned to one concrete input can only sit where that exact box appears). How the witness obtains
such a middleware splits by whether it has dependencies:

- **Works today, no Core change:** *concrete* middleware (an ordinary binding, lifted onto the
  controller) and *generic dep-free* middleware (the witness constructs `Mw<In>()` inline — proven
  in [spike-15](../../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/)). Covers the
  logging/timing tier.
- **Needs one extension:** *generic middleware with `@Inject` deps* (auth-with-a-verifier,
  session-with-a-store). The reason it doesn't fit shipped Wire: the `_WireGraph` is a struct of
  **pre-constructed stored properties, one per binding**, and generic bindings are only ever
  *specialised into concrete stored properties, demand-driven by written dependency types*. A
  middleware in a fold is specialised at the **compiler-inferred** box type — never written — so it
  can be neither a stored property nor demand-specialised. (Wire does already emit some helper
  *methods* on the graph — the `BuilderKey` `_wireFold…`, `@Inject func` setters — so method
  emission itself isn't new; a *generic* one is.)

**The extension is a factory *object*, not a graph back-reference.** The plugin generates, per
generic-with-deps middleware, a small concrete type holding the middleware's deps and exposing a
generic `make`:

```swift
// plugin-generated — an ordinary binding: concrete struct, concrete deps resolved like any binding
struct _WireSessionMiddlewareFactory {
    let store: SessionStore
    func make<In>() -> SessionMiddleware<In> { SessionMiddleware<In>(store: store) }
}
```

The controller lifts this factory as a hidden dependency and the macro-witness calls it in the
fold — `self._sessionMiddlewareFactory.make()`, with `In` inferred from the fold position. This
splits exactly along the macro/plugin line: only the **plugin** (global view) sees the middleware's
`@Inject` deps and writes its construction, into the factory; the **macro-witness** (syntactic)
only *names* the factory and calls `.make()`, never touching the deps. It's therefore an ordinary
lifted binding — constructed once, deduped across controllers that use the same middleware — **not**
a whole-graph reference. (A back-reference is reserved for M5.4's request-scope proxy, which
genuinely must re-enter the graph; middleware construction doesn't.) The generic method lives on a
*concrete* struct, so it's liftable, sidestepping the "a bare generic function isn't a first-class
value" problem.

Scope of the extension: a new plugin emission (recognise a generic `@Middleware(X.self)`, read
`X`'s `@Inject` deps, emit the factory + its conformance) that **composes shipped pieces** — ordinary
binding resolution for the factory's deps, the existing method-emission capability, and lift-the-
minimum for the factory itself. Not a new binding kind; no change to how deps resolve.

## Open sub-decisions

- `@Explode` vs `@Explode` + a capability-declaration attribute — one attribute or two (the
  write-side sugar for custom boxes; the common path uses neither).
- The whole-slot type-spelling fragility above (canonical spelling vs a minimal marker).
- Per-route folds vs a small number of deduplicated chain bindings (an optimisation, not a
  correctness question).
