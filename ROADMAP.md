# Roadmap

Library milestones are tied to what task-cluster needs next, not to a fixed calendar. task-cluster today is a small CRUD service over Hummingbird and the OpenAPI generator with a DynamoDB-backed repository; planned growth includes a real task executor, metrics, tracing, auth, and scheduled or background work. Each milestone below lands when task-cluster's evolution makes it the next thing to solve.

M0 and M1 are complete. The historical M1 implementation plan is archived at
[Documentation/Archive/M1_PLAN.md](Documentation/Archive/M1_PLAN.md); the detail
sections after the milestones (pre-1.0 polish, deferred features, the
WireConfiguration preview) expand on what lands when.

## Milestones

- **M0: validation spikes — complete (macOS 6.3 + Linux 6.3.1).** Four PoCs confirmed M1's design assumptions, with three derived adjustments folded in:
  - Spike 1 (cross-target source reading): PASS-with-fallback. Reading works for same-package and external-package dependencies; library discovery falls back to a `_WireExports.swift` marker file because SPM plugin-usage inspection isn't exposed.
  - Spike 2 (type-level macro walking method-level annotations): PASS. M5's `WireMVC` design is mechanically viable.
  - Spike 3 (annotation argument extraction): PASS. SwiftSyntax preserves type-expression structure verbatim, including nested- and multi-argument generics. M1 must normalise interior whitespace before binding lookup so `Router<X, Y>` and `Router<X,Y>` resolve to the same binding.
  - Spike 4 (swift-syntax pinning): PASS. `from: "601.0.0"` resolves to swift-syntax 601.0.1 identically on both platforms. Bumps to 602.x are deliberate per-Swift-release maintenance events.
- **M1: core graph — complete.** Macros (`@Singleton`, `@Scoped`, `@Inject`, `@Container`, `@Provides`, `@Contributes`, `@Teardown`), runtime types (`Lazy<T>`, `BindingKey<T>`, `CollectedKey<T>`, `MappedKey<K, V>`, `BuilderKey<B>`), build plugin, graph validation (including cross-scope storage checks), the adapter-annotation contract v1, opaque-type support (`@Singleton(as:)` plus lift-the-minimum — see [OpaqueTypesSupport.md](OpaqueTypesSupport.md)), multi-module composition (activation = depending on a Wire-aware library; full cross-target validation by re-parsing dependency sources at build time and merging into one graph; the manifest and reachability-pruning optimizations are deferred to M6a/M6b), Linux CI. task-cluster's manual wiring switched to Wire-driven construction; framework integration stays manual at this point. The `_WireGraph.json` dump moved to pre-1.0 polish (below). No public 0.x tag yet.
- **M2: `WireHummingbird` adapter.** Lands when task-cluster needs first-class request-scoped observability — likely a request-id-tagged logger or the equivalent for tracing. Includes the per-request resolver, `@WebSocketRoute` as the first ship-worthy adapter annotation (type-level form), the first concrete consumer of `CollectedKey` (the application's `[any Service]` lifecycle list), and the runtime `Resolver.introspect()` API plus an `/admin/wiring` example endpoint demonstrating it.
- **M3: `WireOpenAPI` adapter (`@RoutedBy`).** Lands when task-cluster's existing `TaskController.registerHandlers(on:)` call moves into the adapter-annotation system. Auto-wires generated `APIProtocol` conformances. The headline differentiator.
- **M4: lifecycle orchestration.** Lands when task-cluster gets a resource needing orderly shutdown — most likely the first time `AsyncHTTPClient` or a real DynamoDB client (vs the in-memory one) ships in the example. The `@Teardown` annotation exists from M1 (recognised and recorded, but inert); M4 is when the build plugin starts emitting teardown calls in reverse dependency order at scope teardown, integrating with swift-service-lifecycle for app-scope signal handling and Hummingbird's request lifecycle for request-scope teardown. Defines failure semantics (init failure tears down already-initialized bindings in reverse order; teardown failures are collected and logged).
- **M5: `WireMVC` adapter.** Lands when task-cluster has an actual use case for inline route declarations — likely an internal admin endpoint, or as a deliberate content piece contrasting `@RoutedBy`. The first type-level-with-member-recognition adapter; if the contract holds up here, it'll hold up for almost anything.
- **M6: multi-module composition optimizations.** Multi-module composition itself ships in M1; M6 is purely two perf optimizations, each landing when its cost is felt. Both keep the surface contract unchanged and are invisible to users.
  - **M6a — manifest-based discovery.** Lands when re-parsing dependency sources at build time becomes a build-time performance problem (a large dependency graph). Each library's build plugin emits a per-library compile-time manifest of its bindings; the consumer reads manifests instead of re-parsing source. The `_WireExports.swift` marker (a hand-written stub in M1) becomes the generated manifest.
  - **M6b — reachability pruning.** Lands when *eager construction* becomes a runtime/startup cost — depending on a library constructs all its singletons even if the consumer reaches only a few. The plugin computes the bindings reachable from the home package's roots (`allowUnused` marks a root, and only in the home package) and strips the rest before codegen, so a dependency costs only what's used. Until then, an expensive library binding opts into deferral with `Lazy<T>`.
- **Post-1.0:** custom scopes, container composition / fine-grained overrides, `WireVapor` if a Vapor variant of task-cluster materialises, anything else that came out of real use.

The ordering assumes task-cluster's roughly-expected trajectory; it'll shift if the trajectory does.

## Pre-1.0 polish (M6 → 1.0)

Output and developer-experience items lifted out of iteration 9. None are
correctness or milestone blockers, and doing them late is deliberate:

- **`_WireGraph.json` build-time dump.** An inspectable JSON of the wired graph
  alongside `_WireGraph.swift`. Deferred because the schema wants the fuller
  model (adapter registrations, opaque identities, containers/scopes) that lands
  through M2–M6; it also pairs with M6's manifest/metadata emission, and the
  runtime `Resolver.introspect()` counterpart is already M2.
- **Diagnostic-quality sweep.** Re-read every error the suite fires, fix the
  worst wording, tighten fix-it text. Best done against a *stable* error surface
  — M2–M6 add new paths (adapters, `some P<…>`, manifest generation), so a sweep
  now would be partly re-done. Diagnostics stay maintained incrementally
  meanwhile (iteration 3's standard, re-checked each iteration).
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

### `Resolver` protocol

The README describes a public `Resolver` protocol surfacing in three places: `Provider<T>` lazily resolving into a request scope, runtime `introspect()` for ops/admin endpoints, and explicit escape-hatch resolution. None of these have a concrete iteration-1 use case, and the adapter-contract redesign (direct-injection `_wireRegister` parameters) removed adapters as a fourth user.

The protocol is therefore deferred. Iteration 1's bootstrap is a concrete struct with one stored property per binding, accessed directly. Decisions to make later:

- **Iteration 4** decides whether `Provider<T>` needs a `Resolver` protocol or works with a `@Sendable () async throws -> T` closure.
- **M2** decides whether `introspect()` lives on the bootstrap struct directly or on a public `Resolver` protocol.

If neither iteration ends up needing the protocol, it never lands. If one does, the resulting design is shaped by that real use case rather than M1-time speculation. The README's references to `Resolver` describe the *eventual* design and don't need to change at this point — they describe a target that will either be reached or revised once the use case clarifies.

### Library-binding override (`@Replaces`)

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

## Post-M1 milestone preview: WireConfiguration

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

## M2 and the opaque `BuilderKey`

The parameterized-opaque `BuilderKey` (`some P<A,B,C>` lifting + the
`.opaque(P<…>.self)` middleware fold) lands in **M2 / WireHummingbird**, where its
only consumer (`router.addMiddleware`) gets the bootstrap-driven form it actually
wants. The design and the deferred *conformance-derived aliasing* thread live in
[OpaqueTypesSupport.md](OpaqueTypesSupport.md) — *Deferred to M2* and *Second
forcing condition*.
