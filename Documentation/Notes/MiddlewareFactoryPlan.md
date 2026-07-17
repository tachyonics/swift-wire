# `@MiddlewareFactory` build plan — generic-with-deps middleware (M5.3, step 3)

The sequencing plan for finishing the generic-with-deps middleware tier. The **design record** is
[WireMVCMiddleware.md](WireMVCMiddleware.md), *Generic middleware: the `@Factory` template +
`@MiddlewareFactory` mapping*; the milestone context is [M5_PLAN.md](../M5_PLAN.md), M5.3. Same
discipline as the archived plans: each increment runs end-to-end, is risk-ordered, and has a
validation gate. Standing rule: swift-wire changes land + push; the external WireMVC adapter repo
picks them up; the framework-agnostic core is validated *in* swift-wire's tests, the end-to-end in
the wire-mvc repo and the example set.

## Where this starts (shipped baseline)

Increment 2, steps 1–2, are built and merged:

- **`@Factory(key)`** (macro, generates the init from `@Inject` members), **`FactoryKey`**, and
  factory-template discovery (`DiscoveredFactoryTemplate`: generic params + constraints + deps).
- **`.injectsFactoryOnArgument`** capability (runtime + discovered form + parser).
- **`applyFactorySynthesis`**: collates `@Middleware(key)` use-sites, dedupes by key, synthesises a
  **non-generic** factory with a **positional** `create` over *all* the template's generic parameters,
  registers it as a binding, and appends the factory input edge onto each consumer.
- `renderFactoryDeclaration` emits that factory; the deterministic names `_WireFactory_<key>` /
  `_wireFactory_<key>` (sanitised key) are the naming contract the `@Controller` macro re-derives.

That baseline is already *correct* for the common case — a generic middleware whose only generic
parameters are the box roles and whose deps are **concrete** (`@Inject var store: SessionStore`),
with the box roles written in canonical order. What it can't yet do: read a role mapping (reorder /
subset the box roles), or handle the **injected axis** (a generic dep). Those are the gap.

## What's left (the gap)

1. The **`@Controller` macro side** — nothing consumes the synthesised factory yet, so nothing
   compiles end-to-end.
2. **`@MiddlewareFactory` + the role mapping** — explicit, validated box-role ordering; reorder /
   subset support.
3. **The injected axis** — a middleware generic over an `@Inject`-typed dependency (the factory
   becomes a generic binding), and the proxy-field type-naming that entails.

## Increments

### 3.1 — `@Controller` factory wiring → first end-to-end — **DONE**

**Scope.** The `@Controller` macro, for each `@Middleware(key)` on the controller: derive the factory
name from the key (`_wireFactory_<sanitisedKey>` / `_WireFactory_<sanitisedKey>`, matching swift-wire);
add a stored factory property; generate a **wrapping init** that receives it (a macro-generated wrapping
init is peer-invisible to `@Singleton`, so `@Singleton` doesn't reject it, and invisible to the plugin's
pre-expansion scan, so the plugin's construction call resolves to it); and, in the route witness, call the
**uniform** `self._wireFactory_<key>.create(Builder.RequestContext.self, Builder.Reader.self,
Builder.ResponseSender.self)`, folding the result into the chain. Also on the WireMVC side: a
`@Middleware(_ key: FactoryKey)` overload, the `wireMVCMiddlewareFactoryAlias`
(`.injectsFactoryOnArgument`) so the plugin drives synthesis off `@Middleware(key)`, and the
`contributesTo:` → `capability:` migration the swift-wire main pickup forces. The middleware is
declared `@Factory(key)` only — the required `@MiddlewareFactory` marker arrives in 3.2.

**It needed a swift-wire change after all — the plan was wrong.** "WireMVC only" assumed the shipped
step-2 synthesis was complete. It wasn't: a realistic middleware carries a `where` clause
(associated-type + `~Copyable` requirements from the proposal's box), and step-2 **dropped it** — the
synthesised `create` failed to compile (`Builder.ResponseSender.Writer` reverting to `Copyable`). So
3.1 landed a small swift-wire fix: capture the template's `where` clause (`DiscoveredFactoryTemplate.
genericWhereClause`) and restate it on `create` after the per-parameter constraints. This surfaces
only with a real middleware, which is why it slipped the plan. Everything else was WireMVC-only.

**Gate — met.** The wire-mvc `WireMVCExample` self-test builds *and serves* a generic-with-deps
middleware (`SessionMiddleware`, concrete `@Inject` dep) on `UsersController`, driven end-to-end with
real HTTP requests; the mechanism is de-risked by
[spike-18](../../../swift-wire-spikes/spike-18-wiremvc-factory-lift/). Box roles are assumed written in
canonical order (the compiler catches a wrong order at the witness call) — the **convention 3.2
removes**: the box-role order is implicit here, not yet declared.

> **Ships as two commits, ordered:** the swift-wire `where`-clause fix (new PR) first, then wire-mvc
> after a `swift package update swift-wire` — the adapter validates against *pushed* main.

### 3.1b — Factory-lift across module boundaries — **DONE**

**The gap 3.1 missed.** 3.1 validated a controller in the *same module* as the graph consumer. A
controller in a **library** couldn't compile: the `@Controller` wrapping init references
`_WireFactory_<key>`, which 3.1's synthesis emitted in the graph consumer (executable) — a
library→executable reference the library can't resolve. It surfaced immediately on wire-mvc-examples'
shared `Controllers` library.

**The solve — the factory type is owned by its `@Factory` template's module.** Not the consumer's
(a factory can have many consumers, in many packages; the *template* is the single home). Synthesis
split into: (a) **type emission** — template-driven, at the template's visibility (`Sendable`;
`public`/`package`/`internal` per the template), rendered by the template's module so every consumer
references that one declaration; (b) **construction + injection** — consumer-driven in the graph
consumer, which declares only *its own* module's factory types and imports the rest. WireGen gained a
`--library` mode (owned factory types, no graph). Two **explicit** build plugins, because
contributor-vs-graph-consumer is an architectural choice (who calls `bootstrap`), not a target-kind
property: `WireBuildPlugin` (graph consumer) and `WireContributorPlugin` (contributor / library
mode). A contributor applies the latter *only* when it declares `@Factory` templates; forgetting it
is a loud, local compile error (`cannot find type '_WireFactory_<key>'`).

**Visibility mirrors bindings.** An internal `@Factory` with no in-module consumer warns
(`deadFactoryDiagnostics`, fired in both full and library mode); a `public`/`package` one stays silent
(may be consumed in another package). Cross-module consumption therefore requires a `public`/`package`
template. Consumption is judged name-agnostically (any use-site referencing the key), because a
contributor built in library mode doesn't compose the adapter package — the safe direction for a
warning.

**Gate — met.** The shared `Controllers` library compiles (factory type emitted there via
`WireContributorPlugin`) and **all three runtimes build** — proposal-native, Hummingbird, Vapor —
constructing + injecting the library-owned factory. The `RequireAPIKey`-with-`APIKeyStore` example is
the driver.

> **Not the `_WireExports.swift` marker's problem.** The marker (Wire-awareness detection) is
> pre-existing and orthogonal — 3.1b only *adds* the contributor plugin alongside it. Retiring the
> marker (manifest-derived detection + reachability) is M6/M5.4 — see
> [MultiModuleComposition.md](MultiModuleComposition.md), *The marker is detection-only*.

### 3.1c — Route-contributor proxy; retire the wrapping-init footgun (swift-wire + WireMVC) — **DONE**

**The property being restored.** Everywhere else in Wire a binding is an ordinary Swift type: annotate
it, and it's still constructible the normal way with no wrong way to hold it. The 3.1/3.1b factory-lift
broke that for controllers. `@Controller` makes the controller *itself* the `RouteContributor`, but the
conformance silently depends on the macro-generated **wrapping init** having populated the IUO factory
ivar. Build the controller its natural way (`TodosController(repository:)`) and the first route that
folds the factory traps at runtime — `Unexpectedly found nil` (the exact crash 3.1b's fix chased). It's
the one binding in the framework with a footgun initialiser.

**The solve — a generated proxy is the `RouteContributor`; the controller stays pure.** `@Controller`
stops touching the controller's storage and init entirely (the member role is dropped). Instead it
generates a **peer proxy type** that holds the controller (built through its ordinary `@Singleton`
init) plus the lifted factories, conforms to `RouteContributor`, and carries `registerWireRoutes`. The
controller is a plain `@Singleton` again — no IUO, no wrapping init, no wrong way to build it. The
footgun is now structurally impossible: the only type that needs the factories is the proxy, and the
proxy has no initialiser that omits them.

**Shape.**

- Controller: `@Singleton @Controller("/todos") struct TodosController<R: TodoRepository>` — `@Singleton`
  generates the normal `init(repository:)`; `@Controller` adds **no members**.
- Proxy (peer): `struct _WireRouteContributor_TodosController<R: TodoRepository>: RouteContributor,
  Sendable { let controller: TodosController<R>; let _wireFactory_<key>: _WireFactory_<key>;
  init(controller:, _wireFactory_<key>:) {…}; func registerWireRoutes<Builder>(…) {…} }`. The witness
  body is 3.1's, rebased: handler calls `self.controller.method(…)`, the fold keeps
  `self._wireFactory_<key>.create(…)` (now a proxy field). The proxy restates the controller's generic
  parameter + `where` clauses; it's Sendable because both fields are.
- Graph: construct the controller normally, construct `proxy(controller, factory)`, contribute the
  **proxy** into `[any RouteContributor]` — the two lines 3.1b emitted (wrapping-init construction,
  then `[controller] as [any RouteContributor]`) become (normal construction, proxy construction,
  `[proxy] as …`).

**Scope, swift-wire.** A new adapter capability `.contributesProxy(to:)` — the adapter declares the
proxy type-name prefix, keeping the plugin framework-agnostic (as `.contributes(to:)` carries the
multibinding key rather than hardcoding `routeContributors`). It replaces `.contributes(to:)` on the
controller and means: synthesise a proxy binding named `<prefix><T>` that depends on `<T>` plus the
factory demands `<T>`'s `@Middleware(key)` use-sites raise, and contribute the **proxy**, not `<T>`.
The factory-lift target therefore flips from the annotated binding to its proxy — `@Middleware`'s
`.injectsFactoryOnArgument` is unchanged; only where the plugin lands the factory edge moves. The proxy
binding is a lift node whenever the controller is generic (same demand-driven specialisation the
controller gets today).

**Scope, WireMVC.** Drop `ControllerMacro`'s `MemberMacro` role (the IUO ivar + wrapping init). The
`ExtensionMacro` stops emitting `extension <Controller>: RouteContributor` and instead emits the peer
proxy `struct` with the rebased witness. `@Controller`'s adapter alias switches its output edge from
`.contributes(to:)` to `.contributesProxy(to:)` carrying the `_WireRouteContributor_` prefix.

**Unconditional — decision.** Every `@Controller` gets a proxy, even one with zero factories (uniform
generated surface, per [[feedback_consistent_api_over_conditional_shape]] — the contributor shape
doesn't shift the first time a middleware factory appears). It is also the shape request-scoped
controllers need *universally*: a request-scoped controller can't be a held singleton, so its proxy
**builds** the controller (and its request scope) per request instead of holding it. So this isn't a
wrapper-when-a-feature-appears — it's the end-state contributor, and request scope becomes a different
proxy body, not the introduction of proxies. That's the reason to land it now rather than at request
scope.

**What it retires / preserves.** Retires [spike-18](../../../swift-wire-spikes/spike-18-wiremvc-factory-lift/)'s
premise — the IUO-ivar + wrapping-init peer-coexistence with `@Singleton`. The controller is untouched
now, so there is no `@Singleton`/`@Controller` member coordination left to prove; the whole
peer-invisibility gymnastic is gone (the proxy is a separate type with its own fully-visible init).
Preserves 3.1/3.1b's factory **type** synthesis and cross-module ownership wholesale — the proxy
references `_WireFactory_<key>` exactly as the wrapping init did; the hard part (3.1b) does not move.

**Gate.** wire-mvc self-test + all three example runtimes build and **serve identically** — behaviour
is unchanged (DELETE with `x-api-key: secret` succeeds, without → 401). A regression test constructs a
controller its plain `@Singleton` way and confirms it's a valid, footgun-free binding (no route path
can fold a nil factory). swift-wire unit tests: `.contributesProxy` synthesis — the derived proxy
binding, factory demands retargeted onto it, and the generic lift-node proxy.

> **Ships as:** swift-wire (capability + proxy synthesis) first, pushed; then wire-mvc (`@Controller`
> → proxy) after a `swift package update swift-wire`; then wire-mvc-examples re-validated with **no
> source change** — the same controllers regenerate through the proxy.

**Gate — met.** swift-wire: the transitive-lift extension is unit-tested (determination + bridge) and
the emission is proven by a `renderWireGraph` test that produces the exact proxy graph (`_WireGraph<T0>`
with `_WireRouteContributor_<C><T0>` threaded through its dependency on `C<T0>`); contributor-proxy
synthesis is unit-tested (proxy binding, factory re-attribution). The generated-graph shape is
de-risked by [spike-19](../../../swift-wire-spikes/spike-19-wiremvc-contributor-proxy/). wire-mvc: the
`@Controller` peer macro emits the proxy (macro tests updated), and `WireMVCExample` serves every route
through it. wire-mvc-examples: `SwiftHttpServerExample`'s `servesTodosCRUDOverCouchDB` passes over a
real CouchDB — the generic `TodosController<Repository>` served with `RequireAPIKey` lifted onto its
proxy, the DELETE gate intact. The controller is now built `TodosController(repository:)` — plainly, no
factory argument — so the former `Unexpectedly found nil` is structurally impossible (the factory is a
non-optional `let` on the proxy). The injected axis and box-role subsetting (3.2/3.3) are unchanged by
this pivot.

### 3.2 — `@MiddlewareFactory` + the role-mapping contract (swift-wire + WireMVC)

**The default-mapping dial — resolved: positional.** A bare `@MiddlewareFactory` maps the assisted
parameters to the canonical roles *by order* (`param[i] → canonicalRole[i]`), so the common
`<Ctx, Reader, Sender>` middleware works with a bare marker, unchanged. Subsetting or reordering needs
the explicit list — a bare marker can't subset. (The rejected alternative, name-based, would map by
parameter name and handle subset bare, but forces the verbose names `RequestContext`/`Reader`/
`ResponseSender` on every middleware.)

**Scope, swift-wire.** A producer-side "factory role mapping" adapter capability (a new
`WireAdapterCapability` case declared by `@MiddlewareFactory`); extend use-site capture to carry the
**full** argument list (today `ContributionAliasUseSite.argument` holds only the first); join the
mapping to the `@Factory` template by type identity (the `@MiddlewareFactory` use-site sits on the same
type — the hash-join `injectAliasContributions` uses); and drive **canonical-role-ordered** `create`
emission. The mapping is **optional**: a template with no joined mapping keeps today's
positional-declaration-order `create` (backward compatible), so the canonical case is unchanged.

*Library composition of adapter annotations.* The factory type (with its `create`) is emitted by the
template's **owning** module (3.1b) — for a middleware in a shared library, that's library mode
(`WireContributorPlugin`). Library mode must therefore see the `.mapsFactoryRoles` vocabulary to order
the `create`, but it currently parses own sources only. So `WireContributorPlugin` gains the same
Wire-aware dependency-source collection `WireBuildPlugin` already does, and `runLibraryMode` reads the
adapter annotations from them. It stays a pure type-emitter (still emits only its own module's factory
types — `renderOwnedFactoryTypes` filters by `originModule`); it just gains the vocabulary. This means
**reorder/subset middleware work in a shared library** (the idiomatic form) — no full-mode-only
limitation. A canonical middleware needs no vocabulary (positional == canonical) and works either way.

*The emission.* Because the macro always calls `create(Builder.RequestContext.self, Builder.Reader
.self, Builder.ResponseSender.self)` — the fixed triple — the synthesised `create` is **always** generic
over the three canonical role names in that order, each taken as a metatype. The middleware's own
parameter names are **substituted → role names** (reusing the transitive-lift token substituter)
throughout the return type *and the constraints*: a parameter named `Ctx` carrying role requestContext
means `create`'s `RequestContext` generic restates `Ctx`'s constraint, and the return threads it into
that middleware slot. An assisted role the middleware doesn't use stays a phantom `_: Role.Type`
parameter (inferred from the call's metatype, absent from the return) — no separate adapter type; the
reordering/subsetting *is* `create`'s signature. Validation: every assisted (non-`@Inject`-typed)
parameter must be assigned a role; a parameter that is neither role-mapped nor injected is an error.
(The **injected axis** — a factory generic over an `@Inject`-typed parameter — stays 3.3; 3.2's deps are
concrete, so every generic parameter is assisted.)

**Scope, WireMVC.** The `@MiddlewareFactory` macro + its `WireAdapterAnnotationV1` declaration carrying
the new capability; the role vocabulary (`.requestContext` / `.reader` / `.responseSender`); the bare
(positional-default) form and the custom form (an ordered role list positional over the assisted
parameters, e.g. `@MiddlewareFactory(.requestContext, .responseSender)`); and the
`@MiddlewareFactory`-without-`@Factory` diagnostic.

**Why now.** Makes the box-role order explicit and validated (retiring 3.1's convention) and admits
reordered / subsetting middleware — the first thing 3.1 can't express.

**De-risk first (spike).** The subset/reorder `create` shape — a generic function with *phantom* role
parameters (`<RequestContext, Reader, ResponseSender>` where only one appears in the return) called
uniformly with the three metatypes, folded through the real box — is the one "does it compile + infer"
question. A spike proves it before the emission changes land.

**Gate.** swift-wire unit tests: mapping read from a stand-in adapter annotation, reorder/subset
emission, validation diagnostics. wire-mvc: a middleware that pins its own reader (subset) and one that
reorders its parameters both serve; the 3.1 default case is unchanged.

### 3.3 — The injected axis (swift-wire + WireMVC) — **PARKED, pending the codegen foundation**

**Scope.** Partition a template's generic parameters into **injected** (appear as the type of an
`@Inject` member) vs **assisted** (the rest); emit the factory **struct generic over the injected
parameters**, storing the injected deps typed by them, and **register it as a generic binding** so
demand-driven specialisation threads the injected type through the dependency edge; keep `create`
generic over the assisted roles only. This is the tier where a generic controller and the middleware
share a backend through the graph.

**Why parked.** The hard sub-problem is **proxy factory-field type naming**: with a generic factory the
field is `_WireFactory_<key><InjectedType>`, which the **`@Controller` macro can't spell** — it's blind
to the template's injected axis (*which* generic parameter is injected) and to the graph-resolved
backend (*where* it threads). The macro workaround (thread the controller's own single generic
parameter, diagnostic-gate multi-generic) is exactly the code the
[codegen foundation](WireMVCCodegenFoundation.md) replaces: once the **plugin** generates the proxy, it
has both — the injected axis (it discovers the template) and the backend (it threads it through the
graph's lift parameter, the 3.1c transitive-lift machinery). So 3.3's field-naming problem *dissolves*
under the foundation, single- and multi-generic alike. Building the macro workaround now would be
throwaway, so 3.3 **rides Phase A** of the foundation as its validation case rather than shipping ahead
of it.

**Gate (when it resumes, on the foundation).** A generic controller + generic factory + shared
`@Inject` backend compiles and serves end-to-end with the real proposal types; a wire-mvc example where
a controller and its middleware share a repository injected by type-erased generic. The Phase-A
feasibility spike (a plugin-emitted proxy holding `_WireFactory_<key><T0>`, `create` threading the
resolved backend) de-risks exactly this shape.

### 3.4 — Collapse every `@Middleware` to a graph injection (swift-wire DONE)

Both `.self` forms constructed the middleware **inline** (`Concrete()` / `Generic<Builder…>()`), which
silently assumes a no-arg init / no graph dependencies — unverifiable without auditing every referenced
type. So every `@Middleware` becomes a **graph injection lifted onto the proxy**, and its deps are wired
by the graph rather than assumed away.

**swift-wire (done, 621 tests).** `.injectsFactoryOnArgument` and `.injectsDependencyOnArgument` collapse
into one `.injectsFromGraph` capability, **dispatched on the argument's kind**: a `FactoryKey` (matches a
`@Factory` template) → factory-lift (`create<box roles>` + injected axis); a `BindingKey<T>` → a keyed
dependency on `T`; `T.self` → a by-type dependency. Factory-synthesis takes the factory-key use-sites;
`SynthesizedDependencies` takes the `.self` / binding-key ones (now keyed-aware). Field-name handshake:
`_wireFactory_<key>` / `_wire<Type>` / `_wire<sanitisedKey>`. Gains concrete **keyed** bindings for free.

**WireMVC (next).** `@Middleware` → `.injectsFromGraph`. The witness is **mixed (Option A)**:
`middlewareConstructions` classifies each use-site against the `@Factory` template keys the tool collects —
factory key → `self._wireFactory_<key>.create(…)`; `.self` → `self._wire<Type>`; binding key →
`self._wire<key>`. The inline construction and `MiddlewarePlaceholders.swift` (the `Wire*` placeholder
types) retire; box-role-generic middleware become `@Factory` templates, concrete middleware become graph
bindings. Examples: `LogRequests` → `@Factory` (no injected axis), any concrete middleware → a binding.

## Cross-cutting concerns

- **The macro call is uniform across every increment** — always the canonical box-role triple. The
  injected axis and box-role subsetting are absorbed producer-side. After 3.1c the proxy's
  `registerWireRoutes` is the stable witness: 3.2 changes only the `create` call's metatypes on it, and
  3.3 changes only the proxy's factory-field *type*. Nothing else in the controller wiring moves.
- **Naming is the handshake.** `_WireFactory_<sanitisedKey>` / `_wireFactory_<sanitisedKey>` must be
  derived identically by swift-wire's synthesis and the `@Controller` macro. It already is on the
  swift-wire side (`factoryTypeName(forKey:)` / `factoryDependencyName(forKey:)`); the macro re-derives
  it syntactically from the written key.
- **Mapping literal must be plugin-readable pre-expansion** — the custom role list is a literal on the
  `@MiddlewareFactory` attribute, not a value the macro computes (macro output is invisible to the
  plugin's scan). That constrains the syntax (an enum-case list, not parameter references).
- **Diagnostics** (M1 standard, fix-its): `@MiddlewareFactory` without `@Factory`; a generic
  parameter that is neither role-mapped nor injected; a multi-generic controller consuming an
  injected-axis middleware (3.3 gate).

## Validation vehicles

- **swift-wire (framework-agnostic):** unit tests over the synthesis + emission, using stand-in
  adapter-annotation declarations in test source (the `ContributionAliasTests` pattern) — no WireMVC
  dependency.
- **wire-mvc repo:** the real end-to-end, built + served against **pushed** swift-wire main on macOS
  and Linux (validated against pushed main via `swift package update`, not a local path override).
- **example set:** each increment un-gates when its target middleware express cleanly on WireMVC — the
  side-by-side content piece M5 wants.
