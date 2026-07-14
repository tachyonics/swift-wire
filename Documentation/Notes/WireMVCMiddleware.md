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

## Short-circuit & the box shape (Model B) — a *consequence* of the middleware shape

The single most load-bearing fact about the whole middleware model is that it is **entailed by the
proposal's `Middleware.intercept<Return>(input:, next:) -> Return` signature**, not chosen against
HTTP-middleware precedent. The entailment (each step forced by the previous, proven with the compiler
in [spike-17](../../../swift-wire-spikes/spike-17-wiremvc-poison-box/)):

1. `Return` is universally generic — the middleware is compiled once for *all* `Return`, so it can't
   assume it's `Void` or construct one (a literal `return ()` fails: *cannot convert '()' to `Return`*).
2. ⟹ the only value of type `Return` reachable inside `intercept` is what `next` hands back.
3. ⟹ control flow must reach `next` to return at all → **every middleware runs the continuation**; there
   is no control-flow short-circuit (throwing is the only non-`next` exit, and that's the error channel).
4. ⟹ a middleware can't produce the response *as a value* → the response is only ever a **sender
   side-channel effect**.
5. ⟹ since the chain always completes, "who responded / stop handling" can't be control flow — it must
   be **state carried forward** in the box.

So "everyone always runs," "the decision is state in the box," and "a middleware that responds *writes*
via the sender" are one consequence with one cause. The upside is deliberate and matches Wire's
philosophy: participation is **structural, not positional** — an audit/metrics/tracing middleware can't
be silently skipped by an upstream gate. To get classic control-flow short-circuit (inner middleware
skipped) you would have to **change the middleware shape** (pin `Return` to a concrete/associated type
so a middleware can `return` one) — i.e. stop being the proposal's `Middleware`. Staying proposal-native
and this model are the same decision. (Prior art for data-flow short-circuit: Envoy filter-status
enums, railway-oriented / `Either`, http4s `OptionT` — the streaming-first stacks land here too.)

**The box is therefore a `~Copyable` enum, not a struct** (`Sources/WireMVC/Middleware.swift`):

```swift
public enum RequestResponseMiddlewareBox<RequestContext, Reader, ResponseSender>: ~Copyable where … {
    case pending(request: HTTPRequest, requestContext: RequestContext, reader: Reader, responseSender: ResponseSender)
    case responded(request: HTTPRequest)                 // sender consumed & gone; request kept for observation

    public var peekedRequest: HTTPRequest { … }          // borrowing, both states
    public var isPending: Bool { … }
    public consuming func responding(_ write: (consuming ResponseSender) async throws -> Void) async throws -> Self
    public consuming func withPendingContents(_ handler: (HTTPRequest, consuming RequestContext, consuming Reader, consuming ResponseSender) async throws -> Void) async throws
}
```

- A gate that rejects calls `input.responding { sender in … write 403 … }` — it *is* handling the
  request; the sender is consumed, the box becomes `.responded`, and it still calls `next`.
- The generated terminal calls `withPendingContents { … bind → handler → send … }`, which **no-ops when
  the box is `.responded`** — the handler is skipped, exactly once, without any control-flow branch in
  the chain.
- **Single-write and first-wins are enforced by the type**: `.responded` has no sender, so nothing can
  write again or override an earlier decision. No discipline required.
- **Sender is *not* reachable after a write** (the reason for the enum over a struct-with-optional-flag):
  a middleware that responds owns the write and can even stream it; afterward there is structurally no
  sender to hand out. What survives in `.responded` is only the Copyable `request` (add `status` if a
  downstream metrics middleware needs it).
- **No response post-processing** — once the terminal (or a gate) streams via the sender, outer
  middleware can't touch the response. That's inherent to a streaming, sender-based response, and it's
  the same root as `Return` being vestigial; it is not a limitation this shape adds.

## The box & projection

- **The box is WireMVC-owned `RequestResponseMiddlewareBox`** — the `pending`/`responded` `~Copyable`
  enum above (see *Short-circuit & the box shape*). **Grounding (4a):** the proposal's own
  `RequestResponseMiddlewareBox` lives *only* in the `HTTPClientConformance` **test module** (under
  `HTTPServerForTesting`), is referenced by nothing, and drags in the whole NIO server stack — not a
  viable dependency for WireMVC's framework-agnostic core. WireMVC ships its own (initially the struct
  spike-15 vendored; now the Model-B enum). Middleware stay the proposal's `Middleware` (the shippable
  `Middleware` module — protocol + `MiddlewareBuilder` + `ChainedMiddleware`); only the
  `Input`/`NextInput` box type is WireMVC's, and the box being unused upstream is why owning it is free.
  [spike-16](../../../swift-wire-spikes/spike-16-wiremvc-generic-fold/) confirms the fold compiles over a
  *generic* builder's associated types; [spike-17](../../../swift-wire-spikes/spike-17-wiremvc-poison-box/)
  confirms the enum + `responding`/`withPendingContents` and the always-run short-circuit.
- **Explode = the box's `withPendingContents`.** `consuming func withPendingContents { request, context, reader, sender in … }`
  runs the terminal on a `.pending` box and no-ops on `.responded`; the generated terminal calls it.
  (`@Explode` is only for a *custom* box — e.g. one that retypes `request` — where the author supplies
  the destructure; the standard path never writes it.)
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
  2. **Generic, dep-free** — `@Middleware(Generic<WireContext, WireReader, WireSender>.self)`. The
     common logging/timing form; constructs inline (no graph). Both non-transforming and
     context-transforming.
  3. **Generic with `@Inject` deps** — declared as a `@Factory(key)` template and referenced
     `@Middleware(key)`; the plugin synthesises one concrete factory per consumed key and injects it
     onto the controller. The one form needing a swift-wire change (Increment 1's input edge +
     Increment 2's synthesis); see *Generic middleware: the `@Factory` template*.

## Chains = per-route folds

- `@Middleware` at **controller scope** wraps every route; at **route scope** wraps one route;
  composed **controller-outer → route-inner → handler**.
- Each route's chain is a `MiddlewareBuilder` result-builder **fold** over its middleware,
  terminating in the generated terminal. The final box type is **compiler-inferred** from the
  fold (`MiddlewareBuilder`'s `First.NextInput == Second.Input` thread) — the macro never names
  it; the terminal just explodes it via `withPendingContents`.
- **The fold is witness-local concrete codegen, not a graph binding** — proven by
  [spike-15](../../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/). It is *not* a
  `BuilderKey` fold: `BuilderKey` yields a binding whose type must be nameable/opaque, but
  `Middleware` has two primary associated types (`Input`, `NextInput`) that can't be partially
  bound, so "pinned input, opaque output" is not expressible. So the chain is built inline in the
  route witness (where the final box stays concrete-inferred and `withPendingContents` works), with the
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
- `@Middleware(someKey)` — a `FactoryKey`, not `.self` → the factory case. The key references a
  `@Factory` template; the plugin injects the synthesised factory and the witness calls `.create(…)`
  (Increment 2 — see *Generic middleware: the `@Factory` template*).

**The fold, per route** (built inline in `registerWireRoutes`, witness-local concrete): build the base
`RequestResponseMiddlewareBox` from the register closure's `(request, requestContext, reader,
responseSender)`, `wireCompose { … }` the middleware (controller-outer → route-inner), then
`intercept(input: baseBox) { finalBox in finalBox.withPendingContents { … terminal … } }`. Routes with no
`@Middleware` keep the direct path (conditional emission — internal witness shape, not user surface).

**The `sending` relaxation (load-bearing correctness fix).** The box's `withPendingContents` can only
yield plain `consuming` values (its payload isn't provably in a disconnected region — the proposal's
box yields `consuming` for exactly this reason). But `RoutableHTTPServerBuilder.register` hands the
witness `consuming sending` reader/sender at the boundary, and the terminal's consumers were declared
`consuming sending` to match. Through a fold the sender/reader arrive from `withPendingContents` as plain
`consuming`, so those consumers must **not require `sending`**. Fix: `WireMVCOutcome.send(on:)` and
`WireMVCRequest.collectBody` take `consuming` (not `consuming sending`), and **`@RawRoute` handlers take
`consuming` too** (a raw handler streams within its own region; `consuming` works both directly and
through a fold). A `sending` value still passes fine to a `consuming` parameter, so the no-middleware
and raw-direct paths are unaffected. This refines the M5.2 raw-handler contract: `consuming`, not
`consuming sending`.

**Generic-with-deps: the `@Factory` template (Increment 2).** The deferred piece. The developer
declares the middleware `@Factory(key)` and references it `@Middleware(key)`; the plugin synthesises
one concrete factory struct per consumed key whose `create` takes the box types as **metatype
parameters** — `create(_: Ctx.Type, _: R.Type, _: S.Type) -> Mw<Ctx,R,S>` — so the specialisation is
*inferred from arguments*, sidestepping the forbidden explicit method specialisation. The developer
never writes the factory struct: the plugin reads the template's `@Inject` deps, synthesises the
factory, and injects it onto the controller via the input-edge capability (macro-generated `@Inject`
is invisible to Wire's plugin, so the plugin must do the injection); the witness calls
`self._factory_session.create(Builder.RequestContext.self, …)`. This is the swift-wire Core change
(Increment 1's input edge + Increment 2's synthesis); everything above ships as 4a with no swift-wire
change. See *Generic middleware: the `@Factory` template* for the full record.

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
  ambiguity diagnostics). Dep-free and concrete middleware need nothing more — the chain fold is
  witness-local codegen that references ordinary bindings. The **generic-with-deps** tier is the one
  exception: it needs the adapter contract's input-edge capability
  (`.injectsDependencyOnArgument`, Increment 1) plus the `@Factory` template synthesis (Increment 2)
  to deliver a specialisable factory the fold can call. Both stay domain-free in Wire — it injects a
  synthesised binding onto a decorated binding; it never learns "middleware".
- **Shipped proposal:** `Middleware`/`ChainedMiddleware`/`MiddlewareBuilder`,
  `RequestResponseMiddlewareBox` + `withContents`, `HTTPServerCapability.RequestContext`.
- **No opaque fold to build — corrected by
  [spike-15](../../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/).** An earlier
  draft named the type-preserving *opaque `BuilderKey` fold* as the one unbuilt piece. spike-15
  found it is **not expressible**: `Middleware`'s two primary associated types can't be partially
  bound, so a fold can't be returned through a `some Middleware`-with-pinned-input boundary. The
  fold is therefore **witness-local concrete** (which spike-15 proves works end-to-end with the
  real proposal types), so it is *not* a `BuilderKey`/opaque-member fold and there is nothing
  opaque to emit. The one Core-codegen item the design reduces to is the **generic-with-deps
  `@Factory` template** — see the next section.
- **Codegen detail (spike-15):** every plugin-generated forwarding conformance must restate
  `& ~Copyable` in its `where` clause (`extension …: Cap where Base: Cap & ~Copyable`) or Swift
  silently re-imposes `Copyable` and it fails to compile.

## Generic middleware: the `@Factory` template

> **Status:** settled Increment 2 design. Supersedes the earlier "metatype-parameter factory" /
> "factory-object extension" model (a hidden `make<In>()` object the plugin lifted onto the
> controller). That model worked but read as a *non-binding* injectable type — the developer
> couldn't see, name, or reason about the factory as a graph citizen. The settled model makes the
> template **a binding that looks like a binding**, referenced by key, parallel to `@Singleton`.

For multi-stage chains, middleware are generally **generic over their input box** (a middleware
pinned to one concrete input can only sit where that exact box appears). How the witness obtains
such a middleware splits by whether it has dependencies:

- **Works today, no Core change:** *concrete* middleware (an ordinary binding, injected onto the
  controller) and *generic dep-free* middleware (the witness constructs `Mw<In>()` inline — proven
  in [spike-15](../../../swift-wire-spikes/spike-15-wiremvc-opaque-middleware-fold/)). Covers the
  logging/timing tier.
- **Needs the `@Factory` template:** *generic middleware with `@Inject` deps*
  (auth-with-a-verifier, session-with-a-store). The reason it doesn't fit as a plain binding: the
  `_WireGraph` is a struct of **pre-constructed stored properties, one per binding**, and generic
  bindings are only ever *specialised into concrete stored properties, demand-driven by written
  dependency types*. A middleware in a fold is specialised at the **compiler-inferred** box type —
  never written — so it can be neither a stored property nor demand-specialised.

### The template: `@Factory(key)`, a factory binding

The developer declares the middleware as a **factory template** — a binding, spelled parallel to
`@Singleton`, that is referenced by key rather than by type:

```swift
@Factory(MyMiddleware.session)                       // FactoryKey — a namespace identifier
struct SessionMiddleware<Ctx, Reader, Sender>: Middleware where … {
    @Inject var store: SessionStore                  // injected dep — resolved from the graph
    // Ctx, Reader, Sender are the *assisted* params — supplied per fold position, as metatypes
}

extension MyMiddleware {
    static let session = FactoryKey()                // the key: identity is its written text
}
```

`@Factory` is to a factory what `@Singleton` is to a singleton: it marks the type a Wire component
and reads its `@Inject` members as construction deps. The split between the two axes is what makes
it a factory rather than a singleton (prior art: Koin `single` vs `factory` for the lifetime axis;
Dagger `@AssistedInject`/`@Assisted` for the injected-vs-call-time-params axis):

- **`@Inject` members = injected deps** — resolved from the graph, once, when the factory object is
  constructed (Koin's/Dagger's injected axis).
- **generic parameters = assisted params** — supplied at the *`create` call*, per fold position, as
  metatype arguments (`SessionMiddleware<Ctx, Reader, Sender>`). Cleaner than Dagger's `@Assisted`:
  the generic parameters *are* the assisted params, so nothing needs marking.

The function form `@Provides(key) func …` is the secondary spelling (a generic `@Provides` is
already a factory in this sense); `@Factory` on the type is the primary form because the middleware
*is* a type with its own deps.

### `FactoryKey` — a namespace identifier

`FactoryKey` joins Wire's key family (`BindingKey` / `CollectedKey` / `MappedKey` / `BuilderKey`).
Unlike those, it is **not** typed to the produced value — the produced type is generic and varies
per consumer, so no single `Value` could be fixed. It is a **namespace identifier**: its identity
is the canonical text of its declaring reference (`MyMiddleware.session`), and the synthesised
factory type name derives from it (`_WireFactory_<key>`). This is a lighter compile-time check than
a typed key; the real type safety lands at the `create` call, where the compiler unifies the
assisted metatypes against the template's generic signature.

### Consumer-driven synthesis

Like a generic `@Provides` factory, the template *defines* a factory but synthesises nothing on its
own. Synthesis is **consumer-driven** — the consumer is `@Middleware(key)`:

1. Collate every `@Middleware(key)` use-site across the module.
2. Dedupe by key — one factory object per consumed key, shared across every controller that uses it.
3. For each consumed key, synthesise **one** concrete factory struct, register it as an ordinary
   binding (its `@Inject` deps resolve like any binding's), and inject it into the consuming
   controllers via the adapter input-edge capability (`.injectsDependencyOnArgument`, Increment 1).

The synthesised factory:

```swift
// plugin-generated — an ordinary binding: concrete struct, concrete deps resolved like any binding
struct _WireFactory_session {
    let store: SessionStore
    func create<Ctx, Reader, Sender>(_: Ctx.Type, _: Reader.Type, _: Sender.Type)
        -> SessionMiddleware<Ctx, Reader, Sender> where … {
        SessionMiddleware(store: store)
    }
}
```

The `create` method takes the box types as **metatype parameters**, so the specialisation is
*inferred from arguments* — sidestepping the forbidden explicit method specialisation
(`Factory.make<…>()` → "cannot explicitly specialize static method"). The `@Controller` macro's
witness calls `self._factory_session.create(Builder.RequestContext.self, Builder.Reader.self,
Builder.ResponseSender.self)`, with the assisted types spelled from the fold's builder.

This splits exactly along the macro/plugin line: only the **plugin** (global view) sees the
template's `@Inject` deps and writes the factory's construction; the **macro-witness** (syntactic)
only *names* the factory and calls `.create(…)`, never touching the deps. It's an ordinary binding —
constructed once, deduped — **not** a whole-graph reference. (A back-reference is reserved for
M5.4's request-scope proxy, which genuinely must re-enter the graph; middleware construction
doesn't.) The generic method lives on a *concrete* struct, so it's liftable, sidestepping the "a
bare generic function isn't a first-class value" problem.

### The two consumer cases

- **`@Middleware(key)` — the factory case.** The key references a `@Factory` template; the plugin
  injects the synthesised factory and the witness calls `.create(…)`.
- **`@Middleware(ConcreteType.self)` — the concrete case.** `.self`, not a key: there is an ordinary
  binding in the graph we want to inject and use directly. It may still be wrapped in a trivial
  factory that returns the already-created instance, but there is no template to specialise. `.self`
  is reserved for this concrete case; a generic middleware always moves to a keyed `@Factory`
  template (retiring the earlier `@Middleware(Generic<WireContext, WireReader, WireSender>.self)`
  placeholder-generic spelling).

Scope of the work: `FactoryKey` + the `@Factory` macro + template discovery (swift-wire); consumer
collation + factory synthesis + emission (swift-wire, riding Increment 1's input-edge capability);
and the WireMVC `@Controller` macro side (factory ivars + wrapping init + the `create` witness call,
deriving the factory type name from the key). It **composes shipped pieces** — ordinary binding
resolution for the factory's deps, the existing method-emission capability, and the input-edge
primitive — not a new binding kind, and no change to how deps resolve.

## Open sub-decisions

- `@Explode` vs `@Explode` + a capability-declaration attribute — one attribute or two (the
  write-side sugar for custom boxes; the common path uses neither).
- The whole-slot type-spelling fragility above (canonical spelling vs a minimal marker).
- Per-route folds vs a small number of deduplicated chain bindings (an optimisation, not a
  correctness question).
