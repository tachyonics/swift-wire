# Roadmap

Library milestones are tied to what task-cluster needs next, not to a fixed calendar. task-cluster today is a small CRUD service over Hummingbird and the OpenAPI generator with a DynamoDB-backed repository; planned growth includes a real task executor, metrics, tracing, auth, and scheduled or background work. Each milestone below lands when task-cluster's evolution makes it the next thing to solve.

M0 through M5 are complete. The historical implementation plans are archived at
[Documentation/Archive/M1_PLAN.md](Documentation/Archive/M1_PLAN.md),
[Documentation/Archive/M2_PLAN.md](Documentation/Archive/M2_PLAN.md), and
[Documentation/Archive/M5_PLAN.md](Documentation/Archive/M5_PLAN.md) (with the
M5.4 request-scope and M5.5 composition-root detail in
[Documentation/Archive/M5_4_PLAN.md](Documentation/Archive/M5_4_PLAN.md) and
[Documentation/Archive/M5_5_PLAN.md](Documentation/Archive/M5_5_PLAN.md)); M3's
design lives in [WireOpenAPIDesign.md](Documentation/Notes/WireOpenAPIDesign.md).
The next milestone is **M6 (surface completeness)**; the detail sections after
the milestones (pre-1.0 polish, deferred features, the WireConfiguration preview)
expand on what lands when.

## Milestones

- **M0: validation spikes — complete (macOS 6.3 + Linux 6.3.1).** Four PoCs confirmed M1's design assumptions, with three derived adjustments folded in:
  - Spike 1 (cross-target source reading): PASS-with-fallback. Reading works for same-package and external-package dependencies; library discovery falls back to a `_WireExports.swift` marker file because SPM plugin-usage inspection isn't exposed.
  - Spike 2 (type-level macro walking method-level annotations): PASS. M5's `WireMVC` design is mechanically viable.
  - Spike 3 (annotation argument extraction): PASS. SwiftSyntax preserves type-expression structure verbatim, including nested- and multi-argument generics. M1 must normalise interior whitespace before binding lookup so `Router<X, Y>` and `Router<X,Y>` resolve to the same binding.
  - Spike 4 (swift-syntax pinning): PASS. `from: "601.0.0"` resolves to swift-syntax 601.0.1 identically on both platforms. Bumps to 602.x are deliberate per-Swift-release maintenance events.
- **M1: core graph — complete.** Macros (`@Singleton`, `@Scoped`, `@Inject`, `@Container`, `@Provides`, `@Contributes`, `@Teardown`), runtime types (`Lazy<T>`, `BindingKey<T>`, `CollectedKey<T>`, `MappedKey<K, V>`, `BuilderKey<B>`), build plugin, graph validation (including cross-scope storage checks), the adapter-annotation contract v1, opaque-type support (`@Singleton(as:)` plus lift-the-minimum — see [OpaqueTypesSupport.md](Documentation/Notes/OpaqueTypesSupport.md)), multi-module composition (activation = depending on a Wire-aware library; full cross-target validation by re-parsing dependency sources at build time and merging into one graph; the manifest and reachability-pruning optimizations are deferred to M7a/M7b), Linux CI. task-cluster's manual wiring switched to Wire-driven construction; framework integration stays manual at this point. The `_WireGraph.json` dump moved to pre-1.0 polish (below). No public 0.x tag yet.
- **M2: `WireHummingbird` adapter — complete.** The first framework adapter: native **app-scoped** Hummingbird controllers auto-wired onto a `Router` that stays *outside* the graph, on the principle of **collation, not registration**. Two framework-agnostic capabilities landed in Wire Core — the graph-conformance emission (`extension _WireGraph: <Protocol>`, so Wire wires an adapter-declared protocol knowing nothing about HTTP) and the **contribution-alias** adapter contract (an annotation aliases `@Contributes(to: key)`, retiring the iteration-8 `_wireRegister` side-effect). On top, the external `wire-hummingbird` repo (depending on pushed swift-wire main) ships: context-free route collation via `@HummingbirdController` (a `@Contributes` alias that also generates the mount witness); service-lifecycle collation via `@HummingbirdService` → `[any Service]` (the first real `CollectedKey` consumer); and a framework-agnostic `introspect()` wiring model (bindings, kinds, scopes, dependency edges, source locations) with a mountable JSON endpoint. **Middleware is out of scope** — a context-typed value with no clean collation shape, so the app owns it via `router.addMiddleware`; the callable-vs-value boundary (routes/controllers are callables whose context defers to the call site; middleware and typed values aren't) is what decides what collates. The Tier-2 composition-root macro anticipated here was **retired** — M5.5 shipped the proposal-native `@WireMVCBootstrap` instead (see M5 above), on the principle that a `@WireHummingbird`/`@WireVapor` macro fights the grain in those frameworks' own ecosystems. See the archived [M2 plan](Documentation/Archive/M2_PLAN.md) and [WireHummingbirdDesign.md](Documentation/Notes/WireHummingbirdDesign.md).
- **M3: `WireOpenAPI` adapter — complete.** The **cross-runtime** adapter and the headline differentiator. It **re-homes M2's collation model** from `some RouterMethods<Context>` onto `some ServerTransport`: `@OpenAPIController` (a `@Contributes` alias, mirroring `@HummingbirdController` — optional path → `registerHandlers`'s `serverURL`) makes an `APIProtocol` conformer a `TransportContributor` whose generated witness calls `registerHandlers`; `WireOpenAPI.apply` registers the collated handlers onto a user-provided `ServerTransport` that stays *outside* the graph. Because the target is `ServerTransport` (and the external `wire-open-api` package depends only on `OpenAPIRuntime`, no HTTP framework), the same wired controller mounts on Hummingbird, Vapor, or Lambda unchanged. **Handlers-only** — unlike Hummingbird, OpenAPI is not a runtime, so services/lifecycle stay with WireHummingbird. task-cluster demonstrates **the two adapters coexisting on one graph**: WireOpenAPI registers the collated handlers on the router's `ServerTransport`, and WireHummingbird's introspection endpoint serves the graph's wiring model over the same router (`/wiring`), verified live. Two Wire Core capabilities landed to make that clean: a graph conformance now emits for an **activated adapter with zero contributors** (empty-collection accessors, with conformances and multibinding keys treated as import sources like bindings), and every generated graph conforms to a public **`Introspectable`** protocol, so a facade takes `some Introspectable`/`mountIntrospection(graph:)` without naming the internal concrete graph. The `ServerTransport` collation surface (`TransportContributor` / `TransportKeys.handlers` / `TransportComposable` / `apply`) is the durable primitive M5's `@Controller` folds into — a re-home, not a parallel surface. task-cluster's `TaskController.registerHandlers(on: router)` moved into the adapter system, validated live against pushed swift-wire main. **M3.4 (an explicit second-transport demo) was skipped** — the cross-runtime property is structural (the target is `ServerTransport`), not something a demo makes truer. `@OpenAPIConfiguration` and middleware are deferred (middleware to align with M5's `swift-http-api-proposal` `Middleware`). See [WireOpenAPIDesign.md](Documentation/Notes/WireOpenAPIDesign.md).
- **M4: lifecycle orchestration — complete.** The forcing case: task-cluster moved onto a real (Soto) DynamoDB client vs the in-memory one, needing orderly shutdown. The `@Teardown` annotation existed from M1 (recognised and recorded, but inert); M4 emits the **app-scope** teardown walk — `teardown()` on the generated graph, calling each `@Teardown` action in reverse dependency order, run at shutdown via WireHummingbird's `teardownService` (a `ServiceLifecycle` service prepended so it shuts down last, after the server stops). Teardown-action failures are collected and logged so one doesn't stop the rest. **Request-/job-scope teardown** needs request scope and is **M5**. **Init-failure partial teardown** — tearing down already-constructed bindings in reverse before a bootstrap rethrow — is deferred to **M7c**: its implementation is fixed by the construction scheduler that pass settles (a linear prefix today vs. resolved `AtomicState` cells under dynamic scheduling), so it lands there once rather than being rewritten; until then a bootstrap init-failure leaves constructed resources for process exit to reclaim. The forcing case moved task-cluster onto the Soto AWS stack (`AWSClient` `@Provides @Teardown`), validated against a real table via a LocalStack integration test. See [TeardownDesign.md](Documentation/Notes/TeardownDesign.md).
- **M5: `WireMVC` adapter — complete.** The first type-level-with-member-recognition adapter (spike-2 proved the macro mechanics): `@Controller`/`@Get`/`@Path`/`@JSONResponse`/`@JSONInput`/`@RawRoute` **fold into a Wire collation surface** (`WireMVCKeys.routeContributors`, mirroring M3's `ServerTransport` collation *shape* with WireMVC's own key) — so cross-runtime comes for free and WireMVC is essentially a spec-free, annotation-driven analogue of the OpenAPI generator's registration codegen. **Proposal-native:** the witness registers on `RoutableHTTPServerBuilder` (over `swift-http-api-proposal`'s `HTTPServer`), not `some ServerTransport` — deploying against macOS 26 makes `anyAppleOS 26.0` unconditional, so the plan's *tracked successor* became the core; `some ServerTransport` is retained as the opt-in `WireMVCServerTransport` adapter (Hummingbird/Vapor), so the core doesn't depend on OpenAPIRuntime. The settled design is the authoritative record in [WireMVCDesign.md](Documentation/Notes/WireMVCDesign.md) (raw-handler + middleware detail in [WireMVCMiddleware.md](Documentation/Notes/WireMVCMiddleware.md)); the implementation history is the archived [M5 plan](Documentation/Archive/M5_PLAN.md). What shipped:
  - **M5.0–M5.3 — typed routing, middleware, raw handlers.** Because WireMVC owns the route-registration codegen, controller- and route-scoped `@Middleware` are nested wrappers around the generated handler closure — no runtime router type, composition is closure nesting. **Type-transforming middleware falls out as a compile error, not a declared feature:** the codegen threads each middleware's output type into the next stage's input, terminating at the handler's expected input, so an auth middleware producing a principal a handler requires either type-checks or fails at the generated seam — modeled on the ecosystem-standard `Middleware<Input, NextInput>` shape (forward transform, handler as terminal stage, mismatch enforced by `@MiddlewareBuilder`/`ChainedMiddleware`). The `@RawRoute` escape hatch takes the proposal's raw primitives (`consuming sending Reader`/`ResponseSender`) verbatim, skipping decode/encode — streaming/SSE/proxying live here (spike-14 proves SSE both natively and via the `ServerTransport` adapter); **WebSocket stays escape-to-framework** (an upgrade isn't request→response).
  - **M5.4 — request-scoped controllers.** A `@Scoped(seed:)` controller becomes an app-scoped proxy contributor whose *generated* registration embeds per-request scope entry (weak back-ref to the app graph + an injected scope-entry thunk), reusing the shared "adapter replaces the binding" primitive. Each is a **per-request reachability root** — its scope-entry constructs only its own transitive request-scoped subgraph (the M7b reachability concept at the request-construction layer, structural here, not deferrable). Sub-milestones: M5.4E `@ErrorResponse` (error→status tiers), M5.4R `@RawRoute(.role)`, M5.4.5 request-scope teardown, M5.4.6 per-root reachability. Detail in the archived [M5.4 plan](Documentation/Archive/M5_4_PLAN.md).
  - **M5.5 — `@WireMVCBootstrap` composition root.** The WireMVC-native Tier-2 macro: a `@Singleton` composition-root struct whose plugin generates the program entry point (`@main`) — no hand-written `main.swift`. It folds in the `@NotFound` fallback, `@ErrorResponse` global tiers, an optional `introspect()` mount (`mountIntrospectionAt()`, basic or route-scope-guarded), and **global `@Middleware`** as a front layer: a single `GlobalMiddlewareHandler` wraps the finalized router once in the `@main` — O(1) in route count, plain routes untouched, the miss endpoint covered for free (the wrapper sits above the router's 404). It rides swift-wire's `.liftsPeersToProxy` capability (a keyless `.contributesProxy` variant that reattributes the root's `@Middleware` factories onto a synthesized proxy). **Deliberately proposal-native, not a `@WireHummingbird`/`@WireVapor` macro** — a composition-root macro fights the grain in those frameworks' own ecosystems. Detail in the archived [M5.5 plan](Documentation/Archive/M5_5_PLAN.md).
  - **M5.6 — `WireMVCAbstraction.md` rewrite (doc debt, still open).** The one remaining M5 thread: fold the abstraction note's Tier-1/Tier-2 progressive-adoption content into [WireMVCDesign.md](Documentation/Notes/WireMVCDesign.md) and retire the `_wireRegister` model. Cheaper against the settled surface; slots into the M6-era doc pass.
- **M6: surface completeness / DX.** The remaining pre-1.0 *surface* work — features that make idiomatic apps expressible and unblock the last examples, ahead of M7's invisible perf passes. The principle is *complete the surface before optimizing it*. Ordered so foundational, example-unblocking work leads:
  - **M6a — testing (`@WireMVCBootstrap` seam + `@Replaces`).** Make a `@WireMVCBootstrap` app testable end-to-end. Three deliverables: (1) **seam codegen** — `@WireMVCBootstrap` generates a `withTestServer { client in … }` entry over a build-without-serve seam; the generated code owns serving, reading the bound port, and cancellation, so a test writes only assertions against a typed client (the `@main` stays generated in the executable). (2) **`@Replaces`** — a test target is *its own Wire consumer* (its own build plugin, depending on the app executable directly, so it regenerates the graph) and substitutes one binding via `@Replaces`: a consumer binding **superseding a sibling module's binding for the same key**, instead of the current duplicate-binding error. (3) a **`WireMVCTesting`** typed client (`post`/`get` → `.status`/`.json(T.self)`) plus a `SwiftHttpServerExample` migration demonstrating both an integration test (real backend) and a Docker-free `@Replaces` fake-dependency test. Validated by spikes **26** (the seam factors trivially — return the concrete unfrozen router, `finalize()` at the serve site; no graph-generic gymnastics) and **27** (a test target composes an executable dependency's bindings with no `@main` collision — the app needs a `_WireExports.swift` marker and `package`-access cross-module bindings; **no library restructure**). The port needs **no override machinery** — the harness owns it (the test creates the only client). This **promotes the former deferred `@Replaces`** (below) into M6a; it's the biggest M6 piece and leads because it unblocks the last example. Sequence: seam codegen → `@Replaces` → client + example.
  - **M6b — request-logger seam.** The request-scope witness currently collects but discards the request context. Thread it through so a per-request logger (request-id metadata into request-scoped controllers, cross-runtime) is a first-class convenience on top of the already-shipped request-scope injection — not a new primitive. Small; completes the request-scope observability story.
  - **M6c — `@Configuration` / WireConfiguration.** The swift-configuration adapter: `@Configuration(forKey:default:)` at `@Inject`/`@Provides` parameter sites, desugared to a synthesized `ConfigReader` binding — sugar over the graph machinery, riding the shared "adapter replaces the binding" primitive (already built for M5.4 request scope). The broadest DX win — every example hand-rolls config. Full design in the [WireConfiguration preview](#wireconfiguration-scheduled-as-m6c) below.
  - **M6d — advanced OpenAPI integration.** Bring WireMVC's request-scope + typed-param/response DX (`@JSONResponse`/`@JSONInput`-style ergonomics) onto OpenAPI operations, beyond today's spec-driven-handlers-only surface. Genuinely new (not a prior deferral, so it needs a design pass before build); the largest of the four and sequenced last.
- **M7: performance optimizations.** A cluster of perf passes, each landing when its cost is felt — the multi-module discovery/pruning optimizations (M7a/M7b; multi-module composition itself ships in M1) plus construction scheduling (M7c). All keep the surface contract unchanged and are invisible to users. When M7 starts, the ordering among them is decided then.
  - **M7a — manifest-based discovery.** Lands when re-parsing dependency sources at build time becomes a build-time performance problem (a large dependency graph). Each library's build plugin emits a per-library compile-time manifest of its bindings; the consumer reads manifests instead of re-parsing source. The `_WireExports.swift` marker (a hand-written stub in M1) becomes the generated manifest.
  - **M7b — reachability pruning.** Lands when *eager construction* becomes a runtime/startup cost — depending on a library constructs all its singletons even if the consumer reaches only a few. The plugin computes the bindings reachable from the home package's roots (`allowUnused` marks a root, and only in the home package) and strips the rest before codegen, so a dependency costs only what's used. Until then, an expensive library binding opts into deferral with `Lazy<T>`. Reachability also unlocks a **dead-code diagnostic**: a *package-local* binding pruned from every graph is genuinely dead (nothing in its own package reaches it, and it can't be reached from outside), so it should warn. This subsumes the subtle multibinding case — a package-local contributor folded into a `public` aggregate that is itself never consumed: the aggregate stays silent (permissively public, may be consumed downstream), but its package-local contributor is dead and warrants the warning.
  - **M7c — dynamic construction scheduling.** Lands when construction latency (a deep async dependency chain built strictly level-by-level) is worth optimising. Replaces the strict sequential/per-level bootstrap with the dynamic *ready-as-deps-resolve* form — a single `TaskGroup` plus per-binding `AtomicState<T>` cells, each binding firing the instant its own deps resolve (maximum parallelism; sync bindings still construct inline) — see [EffectAwareResolution.md](Documentation/Notes/EffectAwareResolution.md). It **subsumes init-failure partial teardown** (deferred from M4): tearing down the already-constructed bindings before a bootstrap rethrow depends on how the constructed set is represented — a linear prefix under today's sequential chain vs. resolved `AtomicState` cells here — so it's implemented once against the final scheduler. Decision point: with M7c, or earlier if a concrete adopter hits a throwing init that coexists with a constructed `@Teardown` binding. (Happy-path teardown walks the *static* topological order in reverse, so it's independent of the scheduler and already ships in M4.)
  - **M7d — retire the whole-scope seed-scope façade in consumers.** A `@Scoped(seed:)` app emits `Wire.bootstrap<S>Scope` + the `_<S>WireScope` struct + `_wireBootstrap<S>Scope`, but the generated witness never calls them — it uses the per-request `_wireEnterScope` thunk (which since M5.4.6 constructs a per-root *subset*, not the whole scope). So in a consumer the façade is emitted-but-`internal` dead code: a struct + two functions per seed scope. It's retained today because it's swift-wire's *own* testable seed-scope constructor — `Tests/IntegrationTests/BootstrapTests.swift` validates shared-singletons / per-seed-identity / construction-ordering through it, and `SeedScopeEmissionTests` golden-tests its emission. Retiring it from consumer emission needs a thunk-based construction harness for those tests first; fold it in with the `_WireExports`/surface trim (M7a-adjacent) rather than as a standalone change. Invisible to users (the façade is `internal` and uncalled). Surfaced by the M5.4.6 per-root work.
  - **M7e — retire the vendored `WireDisconnected` for the stdlib `Disconnected`, when SE-0538 ships.** M5.5 Phase 5 shipped the global-`@Middleware` **front layer**: a single `GlobalMiddlewareHandler` wrapper in the generated `@main` folds the global tier around `router.handle` once — O(1) in route count, plain routes untouched, the miss endpoint covered for free (the wrapper sits above the router's 404). Its one obstacle was that the linear-sender box launders `sending` off its reader/sender on extraction, so the wrapper's terminal (`consuming`) couldn't call `router.handle` (`consuming sending`). WireMVC cleared that **now** by vendoring `WireDisconnected` — the stable-feature subset of [SE-0538 `Disconnected<Value>`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0538-disconnected.md) (`nonisolated(unsafe)` storage; `init(_ value: consuming sending Value)` / `consuming func take() -> sending Value`) — held inside the box's `.pending` case so `withPendingContents` re-yields the reader/sender `sending`. So SE-0538 is no longer a *prerequisite*; it's a **cleanup**: when it lands in a usable toolchain (in review 2026-07-17→31, impl `swiftlang/swift#89597`), swap the ~20-line vendored `WireDisconnected` for the stdlib type. `WireDisconnected` stands on stable features regardless of the proposal's fate (accepted, renamed, or rejected), so this is optional polish, not a blocker. User-invisible (the type is `internal`). Detail: [M5_5_PLAN.md § Deferred](Documentation/Archive/M5_5_PLAN.md).
- **Post-1.0:** custom scopes, container composition / fine-grained overrides, `WireVapor` if a Vapor variant of task-cluster materialises, anything else that came out of real use.

The ordering assumes task-cluster's roughly-expected trajectory; it'll shift if the trajectory does.

## Pre-1.0 polish (M6/M7 → 1.0)

Output and developer-experience items lifted out of iteration 9. None are
correctness or milestone blockers, and doing them late is deliberate:

- **`_WireGraph.json` build-time dump.** An inspectable JSON of the wired graph
  alongside `_WireGraph.swift`. Deferred because the schema wants the fuller
  model (adapter registrations, opaque identities, containers/scopes) that lands
  through M2–M7; it also pairs with M7's manifest/metadata emission, and the
  runtime `Resolver.introspect()` counterpart is already M2.
- **Diagnostic-quality sweep.** Re-read every error the suite fires, fix the
  worst wording, tighten fix-it text. Best done against a *stable* error surface
  — M2–M7 add new paths (adapters, `some P<…>`, manifest generation), so a sweep
  now would be partly re-done. Diagnostics stay maintained incrementally
  meanwhile (iteration 3's standard, re-checked each iteration).
- **Extension member-default access (edge case).** A binding or multibinding key
  declared as a *defaulted* member of a `public extension` — `public extension Foo {
  static let x }`, no per-member modifier — reads as `internal`, so an unconsumed key
  can falsely warn "no consumer". The explicit-member idiom (`extension Foo { public
  static let x }`) and no-modifier extensions are handled; the remaining fix is to
  inherit a defaulted member's access from the extension's explicit modifier. Benign —
  over-warns only in that rarer idiom.
- **Missing-transitive-activation hint** (deferred from 7e/7g). When a
  cross-module `@Inject` is unsatisfied and the type is declared in a
  *non-activated* transitive Wire-aware dependency, name that library and suggest
  depending on it. The base "no binding produces X" error already fires
  cross-module, so this is fix-it polish; it also needs a three-package fixture
  under `CompositionHarness/`. Slot in with a broader cross-module DX pass.

## Deferred features

Features the README describes but M1 deliberately didn't commit to. Each is
documented as a design space to build **when a concrete adopter use case forces
it**, not on a fixed schedule — the *decision point* in each names the trigger.
Opaque-type support (once listed here) landed in iterations 9–10; the remaining
candidates:

### Shaping the graph: config vs `@Container` vs `@Replaces` (three tools, three intents)

Three of the deferred features below (`@Configuration`/config, `@Container(includes:)`,
`@Replaces`) all "make the graph different," which invites treating them as
alternatives — especially when reaching for a **testing** story. They aren't
alternatives; they sit at three points on a granularity axis and answer three
different questions, and every mature DI system ships all three (Spring
`@Profile` + `@MockBean` + `@ConfigurationProperties`; Dagger `@Module`/`@Component`
+ Hilt `@BindValue` + config):

| Tool | Granularity | Intent | Prior-art twin |
|---|---|---|---|
| **config / `@Configuration`** | a *value* | 12-factor: same graph, different inputs (port, URL, pool size) | Spring `@ConfigurationProperties` / `@DynamicPropertySource` |
| **`@Container` / `@Container(includes:)`** | a *coherent, named set of bindings* | select one of several **structural** variants wholesale | Spring `@Profile` / Dagger `@Module`+`@Component` |
| **`@Replaces`** | a *single binding* | surgically swap one thing in an otherwise-intact graph | Spring `@MockBean` / Hilt `@BindValue` |

Consequences for how these get built and sequenced:

1. **Testing draws on two of them at different resolutions, and neither is "the
   testing feature."** A **value** override (an ephemeral test port, a container's
   mapped DB port) is config's job — no graph surgery (this is what the examples'
   integration tests already do via env). A **surgical** override (swap one real
   dependency for a fake, so a unit test needs no Docker) is `@Replaces`'s job. A
   coarse **whole-"test-environment"** swap (an all-in-memory stack selected
   wholesale) is a `@Container` use, à la `@ActiveProfiles("test")`. So the
   build-without-serve seam (M6a) needs *none* of this machinery — the port is a
   value; config handles it.

2. **`@Container`'s enduring home is environments and modularity, not testing.**
   Its non-test justifications: environments that differ *structurally* (dev binds
   an in-memory repo + fake mailer; prod binds real DynamoDB + SES — a coherent set
   of implementations, not values); reusable binding fragments composed into a graph
   (`@Container(includes:)` = Dagger `@Module`); and multiple entry points in one
   package each selecting a graph. **Caveat — its territory is narrower than classic
   Spring suggests:** in a config-driven (12-factor) app, config absorbs the *value*
   variation and `@Replaces` absorbs the *surgical-test* variation, leaving `@Container`
   composition only the residue — "swap a coherent set of *implementations* as a named
   unit." Real, but narrow. If no such structural-variation use case appears (the
   examples' three runtimes are separate *packages*, not containers in one package;
   task-cluster is a single deploy), container composition legitimately stays a
   documented design space indefinitely. **So don't build `@Container(includes:)` for
   testing reasons** — its trigger is a structural-environment or modularity case.

3. **The bootstrap↔container plumbing has standing regardless.** A `@WireMVCBootstrap`'s
   generated `@main` bootstraps the default graph (`Wire.bootstrap()`); associating a
   bootstrap with a chosen container ("which environment does this app boot") and
   letting an entry point run it against a selected container is a real gap — but it's
   justified by *production environment selection*, not testing, and it's the seam any
   `@Container`-based path (test or prod) would need.

Each has its own forcing case (below): config/`@Configuration` is **M6c**; **`@Replaces`
is now scheduled in M6a** (its surgical-test trigger arrived — the `SwiftHttpServerExample`
fake-dependency test); `@Container(includes:)` stays deferred behind a structural-variation
trigger that hasn't appeared. So M6a builds `@Replaces`, while the coarse container band
stays a documented design space.

### `Resolver` protocol

The README describes a public `Resolver` protocol surfacing in three places: `Provider<T>` lazily resolving into a request scope, runtime `introspect()` for ops/admin endpoints, and explicit escape-hatch resolution. None of these have a concrete iteration-1 use case, and the adapter-contract redesign (direct-injection `_wireRegister` parameters) removed adapters as a fourth user.

The protocol is therefore deferred. Iteration 1's bootstrap is a concrete struct with one stored property per binding, accessed directly. Decisions to make later:

- **Iteration 4** decides whether `Provider<T>` needs a `Resolver` protocol or works with a `@Sendable () async throws -> T` closure.
- **M2** decides whether `introspect()` lives on the bootstrap struct directly or on a public `Resolver` protocol.

If neither iteration ends up needing the protocol, it never lands. If one does, the resulting design is shaped by that real use case rather than M1-time speculation. The README's references to `Resolver` describe the *eventual* design and don't need to change at this point — they describe a target that will either be reached or revised once the use case clarifies.

### Library-binding override (`@Replaces`)

> **Now scheduled as part of M6a (testing)** — the trigger arrived: the `SwiftHttpServerExample` fake-dependency test. The *surgical single-binding* band of [three tools, three intents](#shaping-the-graph-config-vs-container-vs-replaces-three-tools-three-intents) — the DI-idiomatic **test-double** primitive (Hilt `@BindValue`). Spike-27 pinned the exact mechanism: a consumer's binding must **supersede a sibling module's binding for the same key**, where today WireGen's graph generation raises a duplicate-binding diagnostic. The design sketch below (a `@Provides @Replaces(X.self)` in the consumer) is what M6a builds; the "when a use case forces it" framing is now satisfied.

The README's "What's not in scope" section excludes fine-grained binding override across containers — when you select a `@Container`, it's the whole graph for that run, not an overlay on the default. That stance still holds, but a narrower form of override has surfaced as a concrete future use case worth capturing now: replacing a single library-provided `@Singleton` with a consumer-provided `@Provides`.

The shape we'd consider when the use case becomes concrete:

```swift
import WireSQS

@Provides
@Replaces(WireSQS.SQSClient.self)
static func customSQSClient(config: CustomConfig) -> WireSQS.SQSClient {
    SQSClient(specialConstructor: config)
}
```

Build plugin behaviour:
- Removes the library's `@Singleton SQSClient` binding from the graph.
- Substitutes the consumer's `@Provides` as the binding for that type.
- Validates: replacement type matches replaced type; consumer's target only (libraries can't replace each other's bindings); at most one `@Replaces` per replaced type per graph.

Reasons to defer until a real use case appears:

1. The all-or-nothing activation rule is the simplest committable model. `@Replaces` introduces the first crack; once we have one override mechanism, requests for others (override a `@Contributes` collection element, override an adapter annotation's effect) become harder to refuse without a principle to point at.
2. Step B's "two bindings for the same type, both activated" diagnostic already gives users a path: disambiguate with a key. Less ergonomic than `@Replaces` but functional. Whether that pain is real has to be measured by external adopters hitting it, not anticipated.
3. The exact validation rules — particularly around transitive consumers of the library binding inside the library itself — need shaping by a real example, not a hypothetical one.

Decision point: when a concrete adopter (likely the user themselves, integrating a library binding they need to swap) hits the disambiguate-with-keys workaround and finds it insufficient, that's the demand signal to build `@Replaces`. Until then, document the design space here and move on.

### Cross-file `@Container` composition (`ContainerKey`)

Iteration 2b commits to single-declaration containers — every `@Provides`/`@Singleton` belonging to a logical container lives inside that one `@Container enum { ... }` body. `extension TestContainer { @Provides ... }` is silently ignored.

The leading candidate for relaxing this when it bites in real use: an explicit-key mechanism that mirrors iteration 5's `CollectedKey<T>` / `MappedKey<K, V>` / `BuilderKey<B>` pattern.

The shape we'd consider:

```swift
struct ContainerKey: Sendable, Hashable {
    let identifier: String
}

extension ContainerKey {
    static let logging = ContainerKey(identifier: "logging")
}

@Container(key: ContainerKey.logging)
enum CoreLogging {
    @Provides static let logger = Logger(...)
}

@Container(key: ContainerKey.logging)
enum HTTPLogging {
    @Provides static let httpLogger = HTTPLogger(...)
}

// Selection at entry point uses the key, not a contributing type:
let graph = try await _LoggingWireGraph.bootstrap()
```

Build plugin behaviour:
- All `@Container`-annotated types referencing the same key contribute their bindings into one logical container, named after the key's accessor (`ContainerKey.logging` → `_LoggingWireGraph`).
- Within-key duplicate bindings (same type from two contributors) are an error, same rules as iteration 1's duplicate-binding check.
- Cross-module key sharing extends naturally once iteration 7's plugin walks dependency targets — a library publishes a `ContainerKey` and consumer-target `@Container`s reference it.

Why deferred:
1. The single-declaration model is the simplest committable shape. Whether the inability to spread containers across files is actually painful needs to be measured by adoption, not anticipated.
2. Auto-magical extension-based merging (a plain `extension TestContainer { @Provides ... }` joining the container without any annotation) was rejected outright — it would load `extension` syntax with DI semantics that surprise readers who don't know to look for them. 2b's `@Container extension` opt-in covers the same-name cross-file story without that magic; ContainerKey is specifically about cross-*type* contribution.
3. The exact validation rules around cross-module key sharing want shaping by a real adopter scenario rather than a hypothetical.

Decision point: when an adopter hits the same-name limit (wanting multiple unrelated types — not just multiple declarations of the same enum — to contribute to one logical container), that's the signal to build `ContainerKey`. Until then, document the design space here and move on.

### Container composition / hierarchies (`@Container(includes:)`)

> The *coherent-set-of-bindings* band of [three tools, three intents](#shaping-the-graph-config-vs-container-vs-replaces-three-tools-three-intents) — for **structural** environment variation and modularity, **not** testing (config eats value-variation, `@Replaces` eats surgical-test). Trigger: an app that swaps a coherent set of *implementations* as a named unit in one package. Narrow; may never land if all environment differences are config values.

A separate axis from `ContainerKey`: composition lets one container *build from* others by including their bindings, instead of multiple types *contributing to* a single container. The motivating use case is environment-specific configuration — a shared `BaseConfig` plus per-environment overlays:

```swift
@Container
enum BaseConfig {
    @Provides static let logFormat: LogFormat = .json
    @Provides static let appName: String = "MyApp"
}

@Container(includes: [BaseConfig.self])
enum DevContainer {
    @Provides static let baseURL: URL = URL(string: "https://api.dev.example.com")!
    @Provides static let dbName: String = "dev_db"
}

@Container(includes: [BaseConfig.self])
enum ProdContainer {
    @Provides static let baseURL: URL = URL(string: "https://api.example.com")!
    @Provides static let dbName: String = "prod_db"
}

// Selecting DevContainer at the entry point materialises a graph
// containing both DevContainer's bindings and BaseConfig's.
```

Without composition, `BaseConfig`'s bindings would have to be repeated inside every environment container.

Design rules to lock in (so future work doesn't accidentally exclude them):

1. **Composition is additive across all `@Container` declarations of the same logical container.** Just like bindings, `includes:` clauses accumulate. A primary `@Container(includes: [Base.self]) enum DevContainer` plus a `@Container(includes: [Logging.self]) extension DevContainer` mean DevContainer's composition is `{Base, Logging}`. No conflict between annotations is possible because composition is set-valued.

2. **No overriding** — duplicate-binding rules apply within the resolved (post-composition) graph. If `BaseConfig` and `DevContainer` both `@Provides Logger`, that's a duplicate-binding error at validation time. Users design their bindings so each binding has exactly one home in the composed graph.

3. **Relaxed validation: validate the resolved graph, not per-fragment.** A container can have unsatisfied dependencies in isolation (e.g., `BaseConfig` provides `func appLogger(level: LogLevel) -> Logger` but no `LogLevel` binding) as long as the composer fills them. Validation runs on the union of own bindings + transitive `includes:`. A container that's selected (or transitively included by something selected) and ends up with missing bindings is a build error pointing at the entry-point selection.

4. **Fragment opt-out for non-selectable containers.** A container that only makes sense composed (a "fragment" like `BaseConfig` whose standalone graph has open dependencies) needs a way to opt out of bootstrap-struct codegen. Cleanest shape: a parameter on `@Container` — `@Container(selectable: false)` — keeping fragments-are-containers under one annotation. Alternative: a separate `@PartialContainer` / `@ContainerFragment` peer annotation. Either works; the bikeshed is for the actual composition iteration.

What 2b's design preserves so this lands cleanly later:

- `containerBindings: [String: [DiscoveredBinding]]` partitions bindings by container name. Composition adds a *separate* structure (`containerComposition: [String: Set<String>]`) without touching the partition.
- Per-container graph construction in sitting 2 takes a `[DiscoveredBinding]` for each container. With composition, that vector becomes the union of own bindings plus transitive `includes:` resolution; the graph algorithm doesn't need to know.
- Codegen emits one `_<Name>WireGraph` per selectable container. Composition doesn't change the per-container output shape, only the binding set fed in.

Decision point: when an adopter hits the "I'm repeating bindings across containers" pattern (most likely the environment-config case described above), that's the signal to build composition. Until then, document the design space here and move on.

### Nested seeded-scope hierarchies (`@Scoped(within:)`)

Iteration 4a commits to a two-layer scope structure: `@Singleton` is the one always-active scope; everything else is a sibling seeded scope identified by its seed type. Two seeded scopes can't see each other's bindings — they're isolated by design. The common cases the iteration 4 audience cares about (request handling, job consumption, scheduled tasks) fit this shape: a request scope and a job scope coexist as siblings, both pulling from `@Singleton`, never reaching across.

The case worth capturing for future work: scope-within-scope composition. A session scope around a request scope — the session is established at login, lasts across many requests, and a request handler wants access to session-scoped values without re-seeding them per request. Or a per-tenant scope around a per-request scope — tenant identity comes from a token verified once, then descendants inside the request handler need it.

Today's workaround is a composite seed struct: `struct RequestSeed { let request: HTTPRequest; let session: SessionData; let tenant: TenantID }`. The framework adapter assembles the composite at request-scope entry by reading from whichever upstream context holds each piece. Works for shallow composition; gets awkward when the session/tenant values have lifetimes meaningfully longer than the request and you'd rather express the lifetime in the type system.

The shape we'd consider when the use case becomes concrete:

```swift
@Scoped(seed: SessionData.self)
struct SessionLogger {
    @Inject var seed: SessionData
    @Inject var baseLogger: Logger
}

@Scoped(seed: HTTPRequest.self, within: SessionData.self)
struct RequestLogger {
    @Inject var session: SessionData       // from outer scope
    @Inject var request: HTTPRequest       // from this scope's seed
    @Inject var sessionLogger: SessionLogger   // also from outer scope
}

// Entry point: nest via the outer scope's handle.
try await wire.withScope(seeded: session) { sessionScope in
    try await sessionScope.withSubScope(seeded: request) { requestScope in
        // RequestLogger resolves here, with session + request both visible.
    }
}
```

Design rules to lock in:

1. **`@Scoped(within:)` declares the parent statically.** The build plugin verifies that every entry point reaching a `@Scoped(within: A.self)` binding does so from inside an `A` scope. A subscope can only be entered through its declared parent's handle; entering it from singleton scope (or from an unrelated sibling) is a compile-time error.

2. **Validation generalises naturally.** A `@Scoped(seed: B.self, within: A.self)` type can `@Inject` from: `@Singleton` bindings, the A scope's bindings (including A's seed), and the B scope's bindings (including B's seed). It cannot reach sibling scopes of A.

3. **No task-local context propagation is required.** The sub-scope's handle is passed explicitly via the closure parameter (`sessionScope.withSubScope { ... }`), which carries the captured outer-scope state directly. The build plugin generates the `withSubScope` method on the outer scope's resolver type, with the inner scope's binding set + the captured outer bindings. This avoids the ambient-context fragility that `Provider<T>` already mitigates with a different mechanism.

4. **Cross-scope storage rules generalise.** A `@Scoped(seed: A.self)` value still can't be stored directly by a `@Singleton` — same diagnostic with the same `Provider<...>` fix-it. Storing a `@Scoped(within: A.self)` value inside a non-`A` scope is the obvious extension of the rule and gets the same diagnostic shape.

5. **Sibling-scope rule unchanged.** Two `@Scoped(seed: B.self, within: A.self)` and `@Scoped(seed: C.self, within: A.self)` types share an A scope but are independent within it. They can each be entered from inside A but not from inside each other.

Reasons to defer:

1. The two-layer model covers the dominant iteration 4 cases without complicating either the macro contract or the build plugin's graph routing. The cost of deferring is a small ergonomic tax on the session-around-request case (a composite seed struct), not a fundamental capability gap.
2. The static-analysis story — verifying every entry point to a sub-scope goes through its parent — is the substantive work. Designing it against a real use case (rather than a hypothetical session pattern) avoids over-engineering the graph-validation pass.
3. The closure-captured-state vs. task-local-propagation choice should be made when there's a concrete API to weigh against — the current `withSubScope { }` sketch is plausible but not the only option.

Decision point: when an adopter has a real session-scoped value (or tenant-scoped value, etc.) that they want to express as scope nesting rather than as a composite seed, that's the signal to design `@Scoped(within:)`. Until then, document the shape here and let the composite-seed workaround serve.

### Cross-scope reads from outer scope (`Provider<T>`)

The original iteration 4 plan included `Provider<T>` as the scope-crossing primitive for a `@Singleton` reading a `@Scoped`-bound value lazily. Working through the design surfaced that most cross-scope-reading cases collapse under "scope the consumer correctly":

- A controller wanting a request-scoped logger → make the controller `@Scoped(seed: HTTPRequest.self)` (or whatever seed the adapter publishes); the logger injects naturally.
- A long-lived service wanting per-request tracing → wrap with a `@Scoped(seed: ...)` decorator that composes the singleton service with the request-scoped trace; consumers inject the wrapper.
- A controller-shaped type that needs request-scoped values → use `@Scoped`-ing on the controller itself (the `WireVapor` and `WireHummingbird` adapters handle the per-request controller construction transparently — see `WireMVCAbstraction.md`).

The residual cases that genuinely need cross-scope ambient reads — singleton-shaped service reaching down into a request scope it didn't establish — are architecturally inverted and uncommon enough that designing the primitive speculatively risks shipping the wrong shape. Particularly around the captured-scope vs dynamic-lookup decision, the ergonomics of "this call can fail at runtime if no scope is active," and the error-message specificity (naming the expected seed type concretely).

Iteration 4b ships `Lazy<T>` for the deferred-construction motivation (which is often conflated with `Provider<T>` in JVM-DI usage) — that's a separate primitive (just a regular Swift type Wire happens to define) that doesn't have the cross-scope-crossing concerns.

The shape we'd consider when the use case becomes concrete:

```swift
public struct Provider<T: Sendable>: Sendable {
    public func callAsFunction() async throws -> T  // throws if no active scope
}
```

Design notes if `Provider<T>` is reopened:

1. **Throws explicitly.** `callAsFunction()` is `async throws`. Two failure modes: no active scope (`WireScopeError.noActiveScope(seedType: "HTTPRequest")`) and any `async throws` propagated from `T`'s init. The first error names the expected seed type concretely.
2. **Visible code-smell beacon.** Searching for `Provider<...>` in `@Inject` lists shows every place a long-lived type reaches across scope boundaries — useful in code review without needing additional tooling.
3. **Captured-scope vs dynamic-lookup** is the open design question for the API shape; resolve against a real adopter's pattern.
4. **Distinct from `Lazy<T>`.** Lazy is a regular Swift type the user opts into per binding for deferred-and-cached construction (no framework recognition); Provider would be a framework-recognised cross-scope per-call primitive. They serve different needs and ship as separate types if both ever land.

Decision point: when an external adopter has a concrete cross-scope-read pattern that genuinely resists the wrapper-at-appropriate-scope solution, that's the signal to design `Provider<T>` against their pattern. The error-message specificity bar from iteration 3 applies at runtime: the runtime error names the seed and suggests the wrapper-pattern alternative before naming Provider as the resort.

## WireConfiguration (scheduled as M6c)

> **Status:** now scheduled as **M6c** (see Milestones above). The milestone-ordering speculation in this section is historical — it predates M2–M5 and its "suggested reorder" did not happen (WireHummingbird shipped as M2, WireOpenAPI as M3). The **design** below (desugaring model, recognized sites, key-based dedup, `ConfigReader`-method dispatch, validation) is current and is what M6c builds. References to "iteration 3/8" are M1-internal iteration numbers.

The README names `WireHummingbird` as M2 — the first framework adapter, the integration target task-cluster is built around. Working through the M1 design surface (specifically iteration 8's adapter-annotation contract) surfaced a smaller adapter that's a better first real-world test: **WireConfiguration**, a swift-configuration adapter exposing `@Configuration(forKey:default:)`. This section captures the design so the eventual milestone-ordering decision has the work to point at.

### Why ahead of WireHummingbird

1. **Smaller adapter surface, simpler first contract validation.** Hummingbird is the canonical "framework adapter" — type-level + member-level annotations (`@Controller`, `@Get`, `@Post`, `@RoutedBy`) with deeper integration patterns. swift-configuration is comparatively narrow (read a value, pass it through). Validating M1's iteration-8 adapter contract on a smaller surface first surfaces issues before they're tangled up with framework complexity. Same "highest-risk integration first" philosophy the M1 plan applies at the iteration level, applied at the milestone level.
2. **Universal applicability.** Configuration is a fundamental need in any real app; configuration wiring through DI is high-leverage. WireHummingbird benefits HTTP apps; WireConfiguration benefits everything.
3. **Concrete migration target in task-cluster.** The current `let port = config.int(forKey: "HTTP_PORT", default: 8080)` line in `TaskCluster.swift` becomes `@Configuration(forKey: "HTTP_PORT", default: 8080) port: Int` at the @Inject site. Another step on the incremental task-cluster migration path the M1 plan calls out.

### Desugaring model

`@Configuration` is **sugar over the existing graph machinery** — not a new adapter-contract form. The build plugin sees the annotation and synthesizes a binding equivalent to:

```swift
static func _wire_<configKey>(config: ConfigReader) -> <Type> {
    config.<typedMethod>(forKey: "<configKey>", default: <default>)
}
```

The original consumer parameter/property resolves to that synthesized binding via the graph's normal mechanics. **No new adapter form, no contract extension.** The README's three adapter forms (type-level, type-level-with-members, member-level) stay intact — `@Configuration` is purely a build-plugin source transformation that produces existing graph constructs.

### Recognized sites

`@Configuration` is recognized at three sites, all desugaring identically:

```swift
// 1. @Inject property site (most common — Controller-style consumers)
@Singleton
struct TaskController {
    @Inject @Configuration(forKey: "REQUEST_TIMEOUT", default: 30) var timeout: Int
    @Inject var repository: any TaskRepository
}

// 2. @Inject init parameter site
@Singleton
struct TaskController {
    @Inject
    init(
        @Configuration(forKey: "REQUEST_TIMEOUT", default: 30) timeout: Int,
        repository: any TaskRepository
    ) { ... }
}

// 3. @Provides func parameter site (multi-field config aggregation)
@Provides
static func appConfig(
    @Configuration(forKey: "HTTP_PORT", default: 8080) port: Int,
    @Configuration(forKey: "HTTP_HOST", default: "0.0.0.0") host: String
) -> ApplicationConfiguration {
    .init(address: .hostname(host, port: port))
}
```

A standalone `@Provides @Configuration static let httpPort: Int` form was considered but **deliberately not supported** — Swift's `let`-must-be-initialised rule plus the absence of a "synthesise initializer expression for a stored let" macro role means there's no clean way to ship that syntax without sentinel-value workarounds. The three @Inject/@Provides parameter sites cover the realistic consumer patterns; the standalone form is mostly redundant once those work. Worth revisiting if Swift's macro system grows the capability later.

### Synthesized-binding identity (key-based dedup)

Two `@Configuration` annotations of the same parameter type with the *same* config key resolve to the *same* synthesized binding (natural deduplication). Two with *different* config keys resolve to *different* synthesized bindings — keyed by the config key string (e.g., `BindingKey<Int>(identifier: "HTTP_PORT")` and `BindingKey<Int>(identifier: "TIMEOUT")` are distinct).

This integrates cleanly with iteration 3's explicit-key disambiguation work — `@Configuration` essentially uses iteration 3's machinery internally, just with auto-derived keys instead of user-written ones.

### Disambiguating the underlying ConfigReader

`@Configuration` does **not** take a `configKey:` parameter for selecting which `ConfigReader` binding to use. That'd special-case Configuration when iteration 3 is already shipping a general explicit-key disambiguation mechanism for `@Provides func` / `@Inject init` parameters. Instead, the user combines the general annotation with `@Configuration`:

```swift
@Provides
static func appConfig(
    @Inject(ConfigReader.testKey) @Configuration(forKey: "PORT", default: 8080) port: Int
) -> ApplicationConfiguration { ... }
```

Desugaring: the `@Inject(ConfigReader.testKey)` annotation flows through to the synthesized binding's `config: ConfigReader` parameter, where it's just iteration-3's ordinary explicit-key disambiguation. Spec for the flow-through rule: "annotations on the parameter that aren't consumed by the synthesizer (`@Configuration` consumes itself) are forwarded to the synthesized binding's signature." For a synthesizer with one transitive dep (`ConfigReader`), there's no ambiguity about where they land. Future synthesizers with multiple transitive deps can specify per-target if needed; that's a per-synthesizer design question, not architectural.

The user only learns one disambiguation pattern (the iteration-3 annotation), which works the same way regardless of whether the binding is synthesized or hand-written.

### Type → ConfigReader-method dispatch

`@Configuration` needs to call the right typed method on `ConfigReader` based on the annotated parameter's type — `Int` → `config.int(forKey:default:)`, `String` → `config.string(...)`, etc. swift-configuration's surface is constrained enough that a hard-coded mapping for the well-known primitives (`Int`, `String`, `Bool`, `Double`) is the right starting point, with extension hooks for `Codable`-conforming structured config later.

### Validation

Synthesized binding's `ConfigReader` dep resolves against the active graph like any other dep. Missing `ConfigReader` binding → ordinary missing-binding diagnostic at the synthesized site, with a fix-it: "no `ConfigReader` binding satisfies `@Configuration`'s requirement; add `@Provides let configReader = ConfigReader(...)` at module scope, or pin a specific `ConfigReader` via the explicit-key annotation."

### Suggested milestone reorder

- **M2 — WireConfiguration**: smaller surface, validates the iteration-8 adapter contract on a focused adapter, gives task-cluster's port/timeout wiring an obvious migration target.
- **M3 — WireHummingbird**: framework adapter with type-level + member-level annotations. Bigger integration; lands once the contract has been shaken out by M2.
- WireSQS, WireOpenAPI, etc. shift one slot accordingly.

The README still names WireHummingbird as M2; that's editing work for after M1 ships, not now. This section captures the case so the decision is informed.

## The opaque `BuilderKey` fold (superseded — no scheduled consumer)

The parameterized-opaque `BuilderKey` (`some P<A,B,C>` lifting + the
`.opaque(P<…>.self)` middleware fold) was originally slated for **M2 / WireHummingbird**,
where its anticipated consumer (`router.addMiddleware`) would get a bootstrap-driven
form. That consumer never materialised: M2 shipped with middleware left a framework
concern, M5.3 (spike-15) found the opaque `Middleware` fold **isn't expressible and
isn't needed**, and M5.5's global-middleware front layer uses the concrete
`.liftsPeersToProxy` proxy instead. So this fold now has **no scheduled consumer** —
treat it as unbuilt and likely permanently unneeded, not pending. The design and the
deferred *conformance-derived aliasing* thread remain documented in
[OpaqueTypesSupport.md](Documentation/Notes/OpaqueTypesSupport.md) for reference.
