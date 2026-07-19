# M5.4 build plan — request-scoped controllers

The build breakdown for iteration **M5.4** of [M5_PLAN.md](M5_PLAN.md) (the overall WireMVC plan
carries the *why* and the A-inject decision; this file carries the *how*). Same discipline as the
milestone plans: each sub-step runs end-to-end and has a validation gate; highest-risk seam first.
Grounded in the shipped shapes (verified in the `swift-wire` and `wire-mvc` trees, cited below) —
not a predicted model. Related design records: [Notes/RouteErrorHandling.md](Notes/RouteErrorHandling.md)
(M5.4E, interleaved), [Notes/WireMVCMiddleware.md](Notes/WireMVCMiddleware.md) (the fold the scope
entry composes with), [Notes/ScopeAndKeyModelEvolution.md](Notes/ScopeAndKeyModelEvolution.md)
(seeded scopes).

## The headline

A `@Scoped(seed: RequestSeed.self) @Controller` becomes an **app-scoped route-contributor proxy**
whose per-route register closure, *per request*, builds the seed, enters a fresh request scope,
constructs the controller from it, and dispatches. The controller consumes its request-scoped
values by **A-inject** (ordinary `@Inject` off the request scope), never by projecting off the
middleware box — see [M5_PLAN.md](M5_PLAN.md), M5.4. The scope-entry handle reaches the register
closure as an **injected thunk**, not a weak back-reference (the shipped graph is a value type — see
*The central mechanism decision*). App-scoped (`@Singleton`) and request-scoped (`@Scoped`)
controllers coexist unchanged in one app: both are boxed as `any RouteContributor`; the only
difference is a stored thunk the scoped witness calls.

## What M5.4 embeds into (shipped — stable targets, do not change)

- **Seeded-scope bootstrap.** `Wire.bootstrap<Seed>Scope(seed: S, wireGraph: _WireGraph) async throws
  -> _<Seed>WireScope` — a plain struct, one `let` per binding, **no conformances, no teardown**.
  App singletons are shared by passing the *same* graph in; they are read off it inline as synthetic
  "borrow" bindings, not stored on the scope struct. (`swift-wire`:
  `Sources/WireGenCore/CodeEmission.swift:197-322`, `Sources/WireGenCore/SeedScopeOrchestration.swift`;
  golden `Tests/WireGenCoreTests/SeedScopeEmissionTests.swift:98-116`; runtime
  `Tests/IntegrationTests/BootstrapTests.swift:322-326, 383-399`.)
- **The route-contributor proxy.** `_WireRouteContributor_<C>` — app-scoped, WireGen emits the
  *structural* half (`_wireSubject: C` holding the whole constructed controller, unlabelled; plus
  `_wireFactory_<key>` / `_wire<T>` middleware fields), all resolved once at bootstrap.
  (`swift-wire`: `Sources/WireGenCore/ContributorProxyEmission.swift:24, 40-90`,
  `Sources/WireGenCore/ContributorProxySynthesis.swift:112-146`.)
- **The witness.** `func registerWireRoutes<Builder: RoutableHTTPServerBuilder>(on builder: inout
  Builder) throws where …~Copyable…` — the *domain* half, emitted by `WireMVCRouteGen` in the
  consumer module as `extension _WireRouteContributor_<C>: RouteContributor`. (`wire-mvc`:
  `Sources/WireMVC/Contributor.swift:15-29`, `Sources/WireMVCCodegen/RouteContributorGeneration.swift:51-69`,
  `Sources/WireMVCCodegen/RouteCodegen.swift:212-235`.)
- **The register closure** `builder.register(method:path:) { request, requestContext, pathParameters,
  reader, responseSender in … }` is the **only place a genuine per-request value exists**:
  `requestContext` is `consuming Builder.RequestContext`, `~Copyable & ~Escapable`, reachable only
  *inside* the closure, never stored. (`wire-mvc`: `Sources/WireMVC/Routing.swift:10-34`; the base
  capability `HTTPServerCapability.RequestContext` is a bare `~Copyable & ~Escapable` marker.)
- **`apply`.** `WireMVC.apply(_ graph: some WireMVCComposable, to: inout Builder)` loops
  `graph.routeContributors` and calls each witness **once**, at bootstrap — no per-request work.
  (`wire-mvc`: `Sources/WireMVC/Composable.swift:43-57`; example wiring
  `Sources/WireMVCExample/main.swift:49-62`.)

## The central mechanism decision

**The M5.4 design text's "weak back-reference to the app graph" does not work against the shipped
code, because `_WireGraph` is a value-type struct.** You cannot `weak`-reference a struct; you cannot
store the graph in the proxy at construction (the graph is not built yet — the proxy is *part of*
it); and capturing it after the fact diverges from the returned copy. The weak-back-ref design was a
class-graph assumption the proposal-native value-type graph invalidated.

**Decision: an injected scope-entry thunk, not a back-reference.** The scoped proxy holds a
synthesized provider

```swift
let _wireEnterScope: @Sendable (RequestSeed) async throws -> C   // the rooted request-scoped controller
```

built during `_wireBootstrap` capturing **only the borrowed app-singleton locals** it needs — never
the graph, never the proxy. Then:

- **No cycle** — the thunk captures singletons (built as locals before the proxy in topo order), not
  anything containing the proxy.
- **Value semantics are clean** — singletons are shared (the captured references/immutable values are
  the same the app graph holds), and there is no divergent-copy hazard.
- **No protocol or `apply` change** — the thunk is a proxy field; the witness calls it inside the
  register closure. `registerWireRoutes` and the `any RouteContributor` boxing are untouched, so app-
  and request-scoped controllers stay uniform.
- It **dissolves the existential-type wall**: the concrete `_WireGraph` / `bootstrap<Seed>Scope` are
  named only where WireGen emits the thunk (the consumer module), never in the library `apply` or the
  boxed contributor.

This is the "**adapter replaces the binding with a synthesized provider**" primitive M5.4 was slated
to build, shared with `@Configuration`. It relies on the shipped `@Inject weak var`
"assigned-post-construct" machinery only conceptually — the concrete carrier is a captured thunk, not
a `weak` field. (`swift-wire`: general weak-injection `Sources/WireGenCore/InjectMemberDiscovery.swift`,
`Documentation/Notes/WeakInjectionSupport.md`.)

**Alternatives weighed and rejected:**
- *Capture the graph at `apply`* (thread the concrete graph into `registerWireRoutes`, capture it in
  the closures): value semantics are fine (closures capture `apply`'s stable final copy), but it
  **changes the `RouteContributor` protocol** and hits the existential wall (`apply` has `some
  WireMVCComposable`, the witness needs concrete `_WireGraph`). More blast radius, no upside over the
  thunk.
- *Weak reference to a class wrapper of the graph* — restores the design-text shape but forces the
  graph (or a scope-entry facade) to become a reference type: a larger, more invasive Core change than
  a captured thunk, for no functional gain.

## Distinguishing hold from bridge — `proxyScope` on `contributesProxy`

A proxy lives at the scope of the **aggregate it contributes to**, not the scope of its subject. Until
M5.4 the two always coincided (`@Singleton` controller → app-scope `routeContributors`), so the
synthesis never had to tell them apart. M5.4 is the first divergence, and the distinguishing signal is
**not** a new `WireAdapterCapability` case — it is the subject's native scope compared against the
proxy's **declared** scope.

**`contributesProxy` gains an explicit `proxyScope`.** `@Controller` declares it, because wire-mvc
knows routes register once ⇒ the proxy must be app-scoped:

```swift
case contributesProxy(to: Any, proxyTypePrefix: String, proxyScope: WireProxyScope)

// wire-mvc's @Controller alias:
contributesProxy(to: WireMVCKeys.routeContributors,
                 proxyTypePrefix: "_WireRouteContributor_",
                 proxyScope: .singleton)
```

`proxyScope` is swift-wire's own scope vocabulary, so the adapter declaring it stays domain-clean — it
states a scope, it does not teach swift-wire "routing." `.singleton` is the only realistic value for a
collating adapter today (collation happens at app scope); `.seeded(_)` is reserved.

**swift-wire classifies by subject-scope vs declared `proxyScope`** — local, no graph-topology inference:
- subject **==** proxyScope (`@Singleton @Controller`): same scope, **not** cross-scope → proxy **holds**
  the subject (`_wireSubject`, today's shape).
- subject **narrower** than proxyScope (`@Scoped(seed:) @Controller`: seeded subject, `.singleton`
  proxy): a **sanctioned** cross-scope → proxy **bridges** (the `_wireEnterScope` thunk; seed type from
  the subject's `@Scoped(seed: S)`).
- **incomparable** (seeded subject, a differently-seeded proxy): a genuine cross-scope **error**.

For WireMVC (proxy always `.singleton`) this reduces to: **singleton subject → hold; seeded subject →
bridge** — and swift-wire can tell them apart *because* the proxy scope is declared.

**Why declared, not inferred.** A `CollectedKey` aggregate is scope-agnostic — nothing pins
`routeContributors` to app scope except the adapter's knowledge that it collates there. Declaring
`proxyScope` puts that fact where it lives and makes the hold/bridge decision a local comparison,
dissolving any need for swift-wire to reify the aggregate's scope from the conformance topology.

**Consistent API preserved.** `proxyScope` is fixed on the one `@Controller` alias; the per-use-site
variation stays entirely in the subject's native `@Singleton` / `@Scoped(seed:)`. One annotation, no
`@ScopedController` fork.

**Safety intact.** The bridge fires *only* when the subject is narrower than the proxy — exactly the
shape the shipped cross-scope rule already sanctions resolving via a `Provider`/wrapper. So "seeded
subject + `.singleton` proxy ⇒ bridge" is the rule's prescribed fix made structural, not a hole in it.

**Both codegen halves read the same signal.** swift-wire structural keys off the subject binding's
discovered scope (hold vs bridge); WireMVCRouteGen witness reads `@Scoped(seed: S.self)` syntactically
off the controller (plain terminal vs scope-entry terminal). No capability-level coordination token is
invented.

**Packaging.** Adding the field changes the `WireAdapterCapability` shape, but pre-1.0 with WireMVC the
sole (co-developed) `contributesProxy` consumer, that is extending the case + updating the one caller —
no `WireAdapterAnnotationV2` bump. It also generalizes `contributesProxy`'s docstring "holds the binding
(constructed its ordinary way)" to "holds the subject when same-scope, or **enters** the subject's scope
on demand when the subject is narrower than `proxyScope`."

## Sub-steps

**Status:** the spine (**M5.4.1–M5.4.4**), **M5.4G** (generic/opaque-backed scoped controllers), and
**M5.4E** (route error handling — [Notes/RouteErrorHandling.md](Notes/RouteErrorHandling.md), §M5.4E in
[M5_PLAN.md](M5_PLAN.md)) are all **shipped**: a `@Scoped(seed: HTTPRequest.self) @Controller` — including
the idiomatic generic opaque-backed shape — serves cross-runtime, and a route/handler throw maps at the
terminal. **Remaining: M5.4.5** (request-scope teardown — conditional) and **M5.4.6** (per-root
reachability — refinement), both below. Overall sequence in [M5_PLAN.md](M5_PLAN.md): **M5.4 spine ✅ →
M5.4G ✅ → M5.4E ✅ → M5.4R → M5.4.5 / M5.4.6 → M5.5 → M5.6.** The shipped sub-steps are collapsed to
one-liners below; the *central mechanism decision* and *proxyScope hold/bridge* sections above are the
durable rationale for why the shipped code is shaped as it is.

### M5.4.1 — scoped-controller recognition + the scoped proxy shape — ✅ DONE

`@Controller` declares `proxyScope: .singleton`; swift-wire branches **hold** (singleton subject →
`_wireSubject`, byte-identical to before) vs **bridge** (seeded subject → an `_wireEnterScope` thunk field
and *no* `_wireSubject`, the controller becoming an S-scoped binding). *(swift-wire main `0d08b95`.)*

### M5.4.2 — the synthesized scope-entry thunk — ✅ DONE

The "replace-the-binding-with-a-provider" primitive: `_wireEnterScope: @Sendable (Seed) async throws -> C`
emitted in `_wireBootstrap`, **capturing only the borrowed app-singleton locals** (never the graph),
returning the rooted controller. Two new `DependencyKind`s (`.scopeEntryThunk` / `.scopeCapture`) integrate
it into topo ordering without a "no producer" error. *(swift-wire.)*

### M5.4.3 — per-request scope entry in the witness — ✅ DONE

A scoped witness emits `let wireMVCController = try await self._wireEnterScope(request)` at the terminal top
and dispatches on that local (not `self._wireSubject`); the middleware fold composes around it, and the
entry sits **inside the terminal `catch`** so a construction throw maps (the M5.4E seam). *(wire-mvc;
swift-wire fixes `013e061`.)*

### M5.4.4 — seed construction — ✅ DONE

First cut: the seed is the concrete `request: HTTPRequest` from the register closure (always available, no
dependency on the generic `Builder.RequestContext`) — covering the whole auth cluster. *(wire-mvc.)*

### M5.4G — generic scoped controllers (the injected/opaque axis through a bridge) — ✅ DONE

The idiomatic shape now serves: a generic `@Scoped(seed:) @Controller` (`MeController<Repository: TodoRepository>`)
injecting the app's opaque-lifted `@Singleton(as: TodoRepository.self)` backend *and* a request-scoped `Session`
compiles and **serves** cross-runtime — the opaque singleton stays shared (borrowed), the controller fresh per
request. Two bounded codegen gaps fixed (not an architectural wall): (1) `ScopeEntryEmission.scopeEntryThunkLines`
— the bridge thunk is `liftSpecialised` with its param/effects/`@Sendable` emitted **inline** so Swift infers the
*concrete* backend return type from the body (not an unspellable `some P`); (2) `CodeEmission.appendSeedScopeStruct`
— the seed-scope struct + bootstrap are opaque-lifted like `_WireGraph<T0>` (a pre-existing hole for *any* generic
scoped binding). Validated **end-to-end by the example** (graph-driven lift, so a hand-written golden would risk a
false negative). *(swift-wire main `1814788`, 626 tests; files: `SeedScopeStructEmission.swift` (new),
`ScopeEntryEmission.swift`, `CodeEmission.swift`.)*

### M5.4.5 — request-scope teardown  *(swift-wire — conditional)*

**Scope:** the M4-deferred piece. Give `_<S>WireScope` a `teardown()` (it has none today —
`Documentation/Notes/TeardownDesign.md:19-20`, `CodeEmission.swift:264`) and run it after the response
in reverse construction order.

**Not for the auth cluster.** Auth request-scoped values (principal, session, decoded claims) are
**plain values** — nothing owns a lifecycle, so there is nothing to tear down and no leak (ARC reclaims
them). Teardown's forcing case is a request-scoped **resource**: a per-request DB connection/transaction,
a unit-of-work, a temp handle — a *persistence* concern, independent of auth. `sessions` needs none;
`todos-auth-fluent` needs it **only if** the port models a per-request transaction as a `@Scoped(seed:)
@Teardown` binding (the typical shape keeps the pool app-scoped and checks out per-query, so it doesn't).

**Why now (deferred, not spine):** trigger = the **first request-scoped `@Teardown`** (a per-request
resource / unit-of-work). The auth cluster gates M5.4 with zero teardown.

**Validation gate:** a per-request resource is torn down after each request, in reverse order, and a
teardown failure is collected/logged without stopping the rest (mirroring the app-scope teardown
contract).

### M5.4.6 — per-root reachability  *(swift-wire — refinement)*

**Scope:** today's `bootstrap<S>Scope` builds the *entire* S-scope. Make the scope-entry **rooted at
the controller** — construct the controller plus only its transitive request-scoped deps — so two
controllers sharing seed S do not cross-construct (a request to A never builds a B-only scoped
binding). Same seeded scope by seed identity; per-request construction is per-root (M5_PLAN.md M5.4
precisions).

**Why now (refinement):** the spine can ship whole-scope (correct, slightly over-constructs); per-root
is the structural guarantee the design promises, added as a bounded follow-on.

**Validation gate:** with two `@Scoped(seed: S)` controllers A and B sharing a scope, a request routed
to A constructs no binding reachable only from B.

## Key sub-decisions (pinned — all resolved as shipped)

- **Seed source (M5.4.4).** The generic `Builder.RequestContext` cannot *be* the seed (`@Scoped(seed:)`
  needs a concrete type). Commit to **seed-from-`HTTPRequest`** for the spine; the **enriched-context
  seed** (seed carrying a middleware-produced capability, projected off the generic `requestContext`
  under a capability constraint) is a harder second variant — defer it.
- **Whole-scope vs per-root for the spine.** Ship **whole-scope in M5.4.3**, add per-root in M5.4.6 —
  keeps the spine small. (Decide otherwise only if an example needs the per-root guarantee immediately.)
- **Teardown in or after M5.4.** M5.4.5 is spine iff a gate example has a request-scoped `@Teardown`;
  otherwise it defers.

## Risks / interleaves

- **The thunk must capture singleton locals, not the graph** — capturing the whole value-type graph
  re-introduces the construction-order problem. SeedScopeOrchestration already isolates the borrowed
  set; emit a singleton-parameterized bootstrap for the thunk to call.
- **`~Escapable` `requestContext` cannot leave the closure** — the seed is *built inside* the register
  closure; if a future variant seeds from the context, the context is consumed there.
- **M5.4E interleave (load-bearing) — resolved.** A failed verify throws at scope entry; that entry
  now sits inside the terminal's `catch` (M5.4.3 emits it there), so it maps rather than reaching a
  router 500 — the concrete seam where M5.4 and M5.4E touch. See
  [Notes/RouteErrorHandling.md](Notes/RouteErrorHandling.md).
- **Coexistence** — confirm a graph with both a `@Singleton` and a `@Scoped` controller collates and
  serves; the uniform `any RouteContributor` boxing should make this fall out, but it is the M5.4.3
  gate's second half.

## When M5.4 is "done"

- A `@Scoped(seed:) @Controller` serves, constructed fresh per request, injecting request-scoped
  values by A-inject, with a `@Singleton` controller coexisting in the same app.
- The scope-entry thunk (the synthesized-provider primitive) is the Core addition; `RouteContributor`
  and `apply` are unchanged.
- The auth cluster gate (`sessions` / `todos-auth-fluent`) ports, with auth failures and domain errors
  returning correct statuses (M5.4E).
- Request-scope teardown (M5.4.5) and per-root reachability (M5.4.6) are landed or explicitly deferred
  with their trigger recorded.
