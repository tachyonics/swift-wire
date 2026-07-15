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
   becomes a generic binding), and the wrapping-init type-naming that entails.

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

### 3.2 — `@MiddlewareFactory` + the role-mapping contract (swift-wire + WireMVC)

**Scope, swift-wire.** A producer-side "factory role mapping" adapter capability; extend use-site
capture to carry the **full** mapping (all attribute arguments, not just the first — today
`ContributionAliasUseSite.argument` holds one); join the mapping to the `@Factory` template by type
identity; and drive **canonical-role-ordered** `create` emission — emit `create`'s generic parameters
named by the canonical roles in fixed order, taking every role as a metatype, and map the used subset
into the middleware's actual generic slots in the return type (an unused role stays a `_: Role.Type`
parameter so it type-checks, absent from the return). No separate adapter type. Validation: every
non-injected parameter must be assigned a role; a parameter that is neither role-mapped nor injected
is an error.

**Scope, WireMVC.** The `@MiddlewareFactory` macro + its `WireAdapterAnnotationV1` declaration + the
role vocabulary (`RequestContext` / `Reader` / `ResponseSender`); the **default** form (bare — see the
default-mapping dial in the design record) and the **custom** form (an ordered role list positional
over the non-injected parameters, e.g. `@MiddlewareFactory(.requestContext, .responseSender)`); and the
`@MiddlewareFactory`-without-`@Factory` diagnostic.

**Why now.** Makes the box-role order explicit and validated (retiring 3.1's convention) and admits
reordered / subsetting middleware — the first thing 3.1 can't express.

**Gate.** swift-wire unit tests: mapping read from a stand-in adapter annotation, reorder/subset
emission, validation diagnostics. wire-mvc: a middleware that pins its own reader (subset) and one
with non-canonical parameter names (custom mapping) both serve; the 3.1 default case is unchanged.

### 3.3 — The injected axis (swift-wire + WireMVC, de-risked by a spike)

**Scope.** Partition a template's generic parameters into **injected** (appear as the type of an
`@Inject` member) vs **assisted** (the rest); emit the factory **struct generic over the injected
parameters**, storing the injected deps typed by them, and **register it as a generic binding** so
demand-driven specialisation threads the injected type through the dependency edge; keep `create`
generic over the assisted roles only. This is the tier where a generic controller and the middleware
share a backend through the graph.

**The hard sub-problem — wrapping-init type naming.** The `@Controller` macro must name the factory
property's type in the wrapping init, and for a generic factory that type is
`_WireFactory_<key><InjectedType>` — a specialisation the macro can't spell (it's blind to the
template's injected axis, and the concrete backend is graph-resolved). The likely resolution: the
injected-axis genericity is only meaningful when the **controller is itself generic over the shared
type** (`TodosController<R: TodoRepository>` — the lifted-generic pattern, and the primary reason a
controller is generic at all), so the macro threads the controller's own generic parameter into the
factory type. Single-generic controller first; a multi-generic controller (ambiguous which parameter
threads) is **gated with a diagnostic**, not resolved. The compiler backstops via the shared
constraint.

**Why last.** Rarer than 3.1/3.2, and it carries the one genuinely unresolved coordination detail —
so it's risk-ordered last and **de-risked by a spike** before committing to the factory shape.

**Gate.** A spike proving a generic controller + generic factory + shared `@Inject` backend compiles
and serves end-to-end with the real proposal types (the shape spike-15 played for the fold). Then the
real path: a wire-mvc example where a controller and its middleware share a repository injected by
type-erased generic.

### 3.4 — Concrete `.self` pass-through (deferred)

`@Middleware(ConcreteType.self)` — inject an existing binding wrapped in a trivial pass-through
factory so the witness call site stays uniform. Deferred until an example forces it; the design is in
the record (*The consumer* section).

## Cross-cutting concerns

- **The macro call is uniform across every increment** — always the canonical box-role triple. The
  injected axis and box-role subsetting are absorbed producer-side, so the `@Controller` wiring built
  in 3.1 does not change in 3.2/3.3 (except the wrapping-init *type* in 3.3).
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
