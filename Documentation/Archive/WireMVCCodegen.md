# WireMVC route-witness codegen & the generic-with-deps middleware tier — archived

> **Archived — done.** This is the historical build record for two interleaving efforts that are now
> complete: the **generic-with-deps middleware tier** (`@Factory` / `@MiddlewareFactory`, planned as
> increments `3.1 → 3.4`) and the **codegen-foundation move** that relocated route-witness generation
> from the `@Controller` macro to the plugin (planned as `Phase A`, increments `A0 → A5`). They were
> written as three separate plans with three numbering schemes; this record folds them into one timeline
> so the relationships are legible. The **design records are still live**:
> [Notes/WireMVCMiddleware.md](../Notes/WireMVCMiddleware.md) (the middleware model + `@Factory` /
> `@MiddlewareFactory`) and [Notes/WireMVCDesign.md](../Notes/WireMVCDesign.md) (the M5.0 surface). The
> one thread that was *designed but not built* — pluggable parameter decomposition + `@Configuration` +
> explicit `@RawRoute` roles (the old "Phase B") — lives on in
> [Notes/DecompositionTransformers.md](../Notes/DecompositionTransformers.md). End state, in the code:
> route contributors are generated entirely under plugin orchestration in the consumer module (WireGen
> emits the proxy struct; the adapter's `WireMVCRouteGen` emits the witness extension), there is no
> library mode, and every `@Middleware` folds a graph binding.

## How the two efforts relate

The middleware tier and the codegen move were not sequential — they interleave, which is why the
numbering looks tangled read across the original plans:

- `3.1 → 3.1c` built the generic-with-deps factory and, at `3.1c`, a **route-contributor proxy** — but
  as a *macro-generated* peer type.
- `3.3` (the injected axis) hit a wall that only the plugin could clear (it must spell a **generic**
  factory field `_WireFactory_<key><Injected>`, which the macro can't), so `3.3` was **parked** and the
  codegen-foundation move was started to dissolve it.
- **Phase A** relocated proxy + witness generation into the plugin, **superseding `3.1c`'s macro
  codegen** and removing `3.1b`'s library mode. `3.3` then landed *inside* Phase A as **`A5`**.
- `3.4` (collapse every `@Middleware` to a graph injection) landed last, on the finished foundation.

So: `3.3 == A5`; `3.1c`'s macro proxy was replaced by the plugin proxy of `A1`/`A3`; `3.1b`'s library
mode was deleted by `A4`.

## Timeline

| Step | What shipped | Later |
| --- | --- | --- |
| **3.1** | `@Controller` consumes the synthesised factory; first end-to-end serve | witness rebased at 3.1c |
| **3.1b** | Factory type owned by its template's module; `--library` mode + `WireContributorPlugin` | **removed by A4** |
| **3.1c** | Route-contributor **proxy** (controller stays a pure `@Singleton`); `.contributesProxy` | macro codegen **superseded by Phase A** |
| **3.2** | `@MiddlewareFactory` role mapping; `.mapsFactoryRoles`; role-ordered `create` | — |
| **A0** | Orchestration decided: domain-free WireGen + adapter-owned plugin (spike-23) | — |
| **A1** | WireGen emits the structural proxy struct (body hole) | — |
| **A2** | Route codegen ported to a shared lib + `WireMVCRouteGen` tool | — |
| **A3** | Cutover: `@Controller` → marker; plugin live; `WireMVCBuildPlugin` | — |
| **A4** | Library mode removed; consumer emits every consumed factory type | — |
| **A5 (= 3.3)** | The injected axis: factory generic over its `@Inject` backend | — |
| **3.4** | Every `@Middleware` collapses to `.injectsFromGraph` | — |

## The middleware tier (3.1 → 3.2)

### 3.1 — `@Controller` factory wiring → first end-to-end

The `@Controller` macro, per `@Middleware(key)`: derived the factory name from the key
(`_wireFactory_<sanitisedKey>` / `_WireFactory_<sanitisedKey>`), added a stored factory property, and
generated a **wrapping init** receiving it (peer-invisible to `@Singleton` and to the plugin's
pre-expansion scan, so both tolerated it); the witness called the uniform
`self._wireFactory_<key>.create(Builder.RequestContext.self, Builder.Reader.self,
Builder.ResponseSender.self)`. WireMVC added the `@Middleware(_ key: FactoryKey)` overload and the
`.injectsFactoryOnArgument` alias. It also forced a small **swift-wire** fix the shipped synthesis had
missed: a realistic middleware carries a `where` clause (associated-type + `~Copyable` box
requirements), which step-2 synthesis dropped — captured as `DiscoveredFactoryTemplate.genericWhereClause`
and restated on `create`. Gate: `WireMVCExample` served `SessionMiddleware` (concrete `@Inject` dep) on
`UsersController`. De-risked by
[spike-18](../../../swift-wire-spikes/spike-18-wiremvc-factory-lift/). Box roles were assumed written in
canonical order — the convention `3.2` removed. *(The wrapping init was itself a footgun, retired at
3.1c.)*

### 3.1b — Factory-lift across module boundaries

A controller in a **library** couldn't compile: the wrapping init referenced `_WireFactory_<key>`, which
3.1 emitted in the graph consumer (executable) — an unresolvable library→executable reference. The solve:
the factory **type** is owned by its `@Factory` template's module (the single home; a factory has many
consumers), emitted at the template's visibility; **construction + injection** stay consumer-driven.
WireGen gained a `--library` mode (owned factory types, no graph) and a second explicit build plugin,
`WireContributorPlugin`, because contributor-vs-graph-consumer is an architectural choice, not a
target-kind property. Visibility mirrored bindings (an internal `@Factory` with no in-module consumer
warned). Gate: the shared `Controllers` library compiled and all three runtimes built, constructing the
library-owned factory (`RequireAPIKey` + `APIKeyStore`). **All of this — library mode, the contributor
plugin, the owned/consumed split — was removed by A4** once generation moved to the plugin.

### 3.1c — Route-contributor proxy; retire the wrapping-init footgun

The factory-lift had broken a Wire invariant: `@Controller` made the controller *itself* the
`RouteContributor`, but the conformance depended on the macro's wrapping init having populated an IUO
factory ivar — build the controller its natural way and the first folding route trapped
(`Unexpectedly found nil`). The solve: `@Controller` stopped touching the controller's storage and
generated a **peer proxy** (`_WireRouteContributor_<C>`) holding the controller (built through its
ordinary `@Singleton` init) plus the lifted factories, conforming to `RouteContributor` and carrying the
witness. The controller became a plain `@Singleton` again; the footgun was structurally impossible.

swift-wire gained the `.contributesProxy(to:)` capability (the adapter declares a proxy type-name
prefix; the plugin stays framework-agnostic): synthesise a proxy binding `<prefix><T>` depending on `<T>`
plus its `@Middleware(key)` factory demands, and contribute the **proxy**. The proxy is a **lift node**
whenever the controller is generic, threading `T0` through the existing transitive-lift machinery
(`_WireGraph<T0>` → `_WireRouteContributor_<C><T0>` → `C<T0>`). Made **unconditional** (every
`@Controller` gets a proxy, per [[feedback_consistent_api_over_conditional_shape]]) because it is also
the end-state shape request-scoped controllers need. Retired
[spike-18](../../../swift-wire-spikes/spike-18-wiremvc-factory-lift/)'s peer-invisibility premise;
de-risked by [spike-19](../../../swift-wire-spikes/spike-19-wiremvc-contributor-proxy/). Gate: all three
runtimes served identically; `SwiftHttpServerExample`'s CouchDB CRUD test passed with `RequireAPIKey`
lifted onto the generic controller's proxy. **The proxy stayed; its *macro* generation was superseded by
Phase A.**

### 3.2 — `@MiddlewareFactory` + the role-mapping contract

Made the box-role order explicit and validated (retiring 3.1's convention) and admitted
reorder/subset middleware. A bare `@MiddlewareFactory` maps assisted parameters to the canonical roles
**by order** (`param[i] → canonicalRole[i]`); the explicit form (`@MiddlewareFactory(.requestContext,
.responseSender)`) maps positionally over a chosen/ordered subset. swift-wire gained a
`.mapsFactoryRoles` capability, full use-site argument capture, and canonical-role-ordered `create`
emission (the middleware's parameter names substituted → role names throughout the return type *and*
constraints; an unused role stays a phantom `_: Role.Type`). The mapping is optional — a template with no
mapping keeps positional-declaration-order `create`. Diagnostic: `@MiddlewareFactory` without `@Factory`.

## The codegen foundation — macro → plugin (Phase A)

### Why the move

The `@Controller` macro is blind to everything outside the attached declaration — the graph, other
modules, the factory templates — so every coordination was forced through a deterministic-name
handshake, and the proxy (never anyone's public API) was macro-generated *in the controller's module*,
which is the only thing that forced **library mode**. Moving generation into the plugin (which already
parses the controller for the graph and synthesises the factories) dissolved all of it: library mode,
the contributor plugin, the double-parse, and the name handshake. Crucially it **dissolved 3.3**: the
injected-axis proxy field `_WireFactory_<key><Injected>` needs both *which* controller generic is the
injected backend (the plugin discovers the template) and *where* the graph resolves it (the plugin
threads it through the lift parameter) — exactly what the macro couldn't do. The macro workaround for
3.3 would have been throwaway, so 3.3 rode the move.

### A0 — orchestration (resolved; spike-23)

The route witness is WireMVC **domain** codegen (verbs → `builder.register`, bindings, response modes,
the `~Copyable` fold); WireGen is deliberately **domain-free**. So WireGen orchestrates domain codegen it
does not contain: **mechanism 1** — WireGen emits the *structural* half (proxy struct + generic factory
fields + `T0` threading + graph) with a **body hole**; a WireMVC codegen tool emits the *witness body* as
an `extension` on that struct, same consumer module, meeting it only on the deterministic field names.
The **build plugin moved to the adapter** (a WireMVC plugin running both tools); swift-wire's one change
was to **publish WireGen as an executable product**. De-risked by
[spike-23](../../../swift-wire-spikes/spike-23-two-tool-codegen/): two tools, one module, compiles +
serves, and the field-name handshake is compiler-enforced (a desync fails the build at the reference
site). Chosen over an extensible WireGen because orchestration is domain knowledge and belongs in the
adapter, keeping WireGen strictly structural.

### A1 — the structural half (WireGen, domain-free)

`renderContributorProxyDeclaration` (`WireGenCore/ContributorProxyEmission.swift`) emits the proxy
`struct` — `_wireSubject` + each `_wireFactory_<key>` field, the initialiser the graph's construction
call targets, `Sendable`, generic exactly as the subject — with a **body hole** (no conformance, no
witness). **No capability fork:** `.contributesProxy` already means "WireGen owns the structural proxy";
naming a domain-free capability `.contributesRoutes` would leak HTTP domain. Unit-tested directly
(11 tests: struct shape, the field-name contract, init-matches-construction).

### A2 — the domain half (WireMVC codegen tool)

`ControllerMacro`'s route codegen ported into a shared `WireMVCCodegen` library + a `WireMVCRouteGen`
tool that emits the witness `extension` via the A0 seam. Route-shape diagnostics (unannotated
parameter, path mismatch, raw-route roles) moved here, anchored at source locations. Unit-tested against
every route shape, originally asserting output parity with the macro to catch drift.

### A3 — cutover: `@Controller` → marker

`@Controller` became a marker (expands to nothing), staying on `.contributesProxy`. WireGen went live
emitting the structural half into the consumer graph file and was published as an executable product;
the adapter-owned `WireMVCBuildPlugin` runs WireGen + `WireMVCRouteGen`. A consumer applies
`WireMVCBuildPlugin` instead of `WireBuildPlugin`. **Synchronized across three repos** (swift-wire
go-live → wire-mvc marker + plugin → the three runtimes adopt the plugin). One defect the multi-module
examples caught: a `public` shared-library controller yielded a `public` proxy, but the consumer's
generated file imports `Controllers` *internally* (`InternalImportsByDefault`), so the proxy is emitted
**`internal`** (a consumer-local coordination type, never public API).

### A4 — remove library mode

The graph consumer now emits every *consumed* factory type (`renderConsumedFactoryTypes`, own- and
dependency-module templates alike), `internal` for the same `InternalImportsByDefault` reason.
`WireContributorPlugin`, the `--library` path, `runLibraryMode`, and
`renderOwnedFactoryTypes`/`renderFactoryModule` were removed; `WireBuildPlugin` is the only swift-wire
plugin. `_WireExports.swift` stays as the cross-module-composition marker (its full retirement is later).
Adapter side: `Controllers` dropped `WireContributorPlugin` (nothing references the factory types now
that `@Controller` is a marker). Gate: the shared library serves through the consumer-generated witness +
consumer-emitted factories, all three runtimes.

### A5 — the injected axis (= 3.3, un-parked)

A `@Factory` middleware that `@Inject`s a **generic** dependency makes that parameter *injected* (the
complement of `assistedParameters(of:)` — no new annotation; the axis follows from `@Inject`). The
synthesised factory becomes generic over it: `SynthesizedFactory` splits `parameterNames` into injected
(the struct's own generics) and assisted (box roles on `create`); `renderFactoryDeclaration` emits
`struct _WireFactory_<key><Repository: TodoRepository> { let repository: Repository; func create<Ctx>(…)
-> Produced<Ctx, Repository> }`; `factoryBinding` is generic over the injected axis with the `@Inject`
deps as bare-parameter dependencies, so it's a **lift node** the existing transitive-lift machinery
threads `T0` through; the proxy field is `_WireFactory_<key><Repository>`, matched to the consumer's
generic param by constraint. This is where a generic controller and its middleware share one backend
through the graph. De-risked by
[spike-22](../../../swift-wire-spikes/spike-22-plugin-generated-proxy/). Gate: `Controllers`' `AuditGate`
gained a `Repository: TodoRepository` injected axis sharing the controller's backend; all three runtimes
serve.

## 3.4 — collapse every `@Middleware` to a graph injection

Both `.self` forms had constructed the middleware **inline** (`Concrete()` / `Generic<Builder…>()`),
silently assuming a no-arg init / no graph dependencies — unverifiable. So every `@Middleware` became a
**graph injection lifted onto the proxy**. `.injectsFactoryOnArgument` and `.injectsDependencyOnArgument`
collapsed into one `.injectsFromGraph` capability, **dispatched on the argument's kind**: a `FactoryKey`
(matches a `@Factory` template) → factory-lift (`create<box roles>` + injected axis); a `BindingKey<T>`
→ a keyed dependency on `T`; `T.self` → a by-type dependency. Factory synthesis takes the factory-key
use-sites; `SynthesizedDependencies` takes the `.self` / binding-key ones (keyed-aware). Field-name
handshake: `_wireFactory_<key>` / `_wire<Type>` / `_wire<sanitisedKey>`. Concrete **keyed** bindings come
for free. WireMVC's witness is mixed — `middlewareConstructions` classifies each use-site against the
`@Factory` template keys the tool collects across all input sources (factory → `self._wireFactory_<key>
.create(…)`; `.self` → `self._wire<Type>`; other key → `self._wire<key>`). The inline construction and
the `WireContext`/`WireReader`/`WireSender` placeholder types retired; box-role-generic middleware became
`@Factory` templates. Gate: `WireMVCExample` + all three `wire-mvc-examples` runtimes serve; the generated
fold shows `LogRequests`, `AuditGate` (injected axis), and `RequireAPIKey` all lifted as factories.

## Standing conventions these plans followed

- **swift-wire lands + pushes; the external WireMVC adapter picks it up.** The framework-agnostic core is
  validated *in* swift-wire's tests (stand-in adapter-annotation declarations, the `ContributionAliasTests`
  pattern); the end-to-end is validated in the wire-mvc repo and the example set, against **pushed** main
  (`swift package update`, never a local path override).
- **Naming is the handshake.** `_WireFactory_<sanitisedKey>` / `_wireFactory_<sanitisedKey>` (and, from
  3.4, `_wire<Type>` / `_wire<sanitisedKey>`) are derived identically by swift-wire's synthesis and the
  WireMVC codegen tool.
- Each increment ran end-to-end, was risk-ordered, and had a validation gate — the discipline the earlier
  archived milestone plans set.

## Pointers

- **Design records (live):** [Notes/WireMVCMiddleware.md](../Notes/WireMVCMiddleware.md),
  [Notes/WireMVCDesign.md](../Notes/WireMVCDesign.md); the adapter-capability model in
  [Notes/AdapterModel.md](../Notes/AdapterModel.md).
- **Forward work (designed, not built):**
  [Notes/DecompositionTransformers.md](../Notes/DecompositionTransformers.md) — pluggable parameter
  decomposition, `@Configuration`, explicit `@RawRoute` roles.
- **Spikes:** [18](../../../swift-wire-spikes/spike-18-wiremvc-factory-lift/) (factory lift),
  [19](../../../swift-wire-spikes/spike-19-wiremvc-contributor-proxy/) (contributor proxy),
  [21](../../../swift-wire-spikes/spike-21-wiremvc-transforming-rawroute/) (transforming middleware /
  raw route), [22](../../../swift-wire-spikes/spike-22-plugin-generated-proxy/) (plugin-generated proxy /
  injected axis), [23](../../../swift-wire-spikes/spike-23-two-tool-codegen/) (two-tool orchestration).
- **Milestone context:** [M5_PLAN.md](M5_PLAN.md), M5.3.
