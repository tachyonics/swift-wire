# M1 Implementation Plan

This is the implementation plan for M1 of swift-wire — the milestone where the core graph, build plugin, validation, multi-module composition, and adapter-annotation contract land. M0's validation spikes have all passed (see [the spikes repo](../swift-wire-spikes)) and the design committed in [README.md](README.md) is ready to build against.

The plan is **iterative**, not waterfall. Each iteration builds on the previous and produces something that runs end-to-end. Iteration boundaries will move as implementation surfaces things the design didn't anticipate; the order is what matters.

## How to use this plan

- Each iteration has a *scope*, a *why-now* rationale, and a *validation gate*. Don't move on until the validation gate passes.
- Test fixtures grow with the iterations — every iteration that adds a feature also adds the test cases that prove it.
- task-cluster is the integration vehicle. Don't migrate it in one shot at the end; migrate incrementally as features come online (see "Cross-cutting concerns" below).
- Diagnostics are iterative, not a one-shot polish at the end. Iteration 3 sets the standard; every iteration after re-validates new error paths.
- The pre-build SourceKit "no such module" noise observed during M0 is normal and stays loud through development — real plugin failures produce different errors; don't filter the noise.

## Iteration 1 — minimum viable graph

The smallest end-to-end pipeline. Highest-risk integration first: if anything in the macro/build-plugin/bootstrap chain is fundamentally broken, you find out before building anything else.

**Scope:**
- `BindingKey<T>` runtime type
- `@Singleton` macro (single scope only — others come in iteration 4)
- `@Inject` macro (synthesises constructor)
- Build plugin: scan a single target's source, aggregate `@Singleton` types, emit a generated bootstrap (`_WireGraph.swift`) into the plugin work directory
- Generated bootstrap constructs all `@Singleton`s in dependency order; bootstrap is a concrete struct with one stored property per binding, accessed directly (no `Resolver` protocol — see "Deferred decisions" below)

**Out of scope:** `@Provides`, `@Container`, validation diagnostics beyond "it compiles," other scopes, lifecycle, multi-module, the `Resolver` protocol.

**Validation gate:** test app with two `@Singleton` types where one `@Inject`s the other; build plugin produces a working bootstrap; running the app constructs both and resolves the inner one through the outer.

## Iteration 2 — `@Provides` and `@Container`

Lets the test app inject framework primitives (`Logger`, configuration, etc.) that aren't `@Singleton` types.

Split into two sub-milestones. `@Container` introduces a binding-selection mechanism whose design questions are independent of `@Provides` discovery, and a half-done `@Container` (binding discovery without selection) would be a worse user experience than no `@Container` at all.

### Iteration 2a — module-scope `@Provides`

**Scope:**
- `@Provides` macro on:
  - Module-scope `let` and `func` declarations
  - `static let` and `static func` members of any enclosing type (struct, class, enum, actor) that is *not* `@Container`-annotated
- Build plugin aggregates `@Provides` declarations alongside `@Singleton` types into the default graph
- Function-form `@Provides` contributes parameter dependencies; property-form contributes none

**Out of scope:** `@Container` macro and container selection. The `@Container` identifier is unrecognized in 2a — if a consumer writes it, it parses as a plain enum and Wire ignores it.

**Why static members of non-`@Container` types count as module-scope:** the caseless-enum-as-namespace pattern is a Swift idiom unrelated to DI semantics. Refusing to recognize `@Provides` on `static` members would force a stylistic choice ("must be at file scope") with no DI rationale. Semantically a `@Provides` is part of the default graph unless its enclosing type is `@Container`; the enclosing type is otherwise just an access-path detail (`AppConfig.logger` vs. `logger`).

**Validation gate:** test app with `@Provides let logger = Logger(label: "test")` at module scope, consumed by a `@Singleton` via `@Inject`. Same scenario with the binding declared as `static let` on a non-`@Container` enum used as a namespace. `@Provides func` form (with parameter dependencies) covered by an additional fixture.

### Iteration 2b — `@Container` with selection

**Scope:**
- `@Container` macro, attachable to enum primary declarations *and* to extensions (see "Container composition rules" below)
- Build plugin discovers `@Provides` declarations and `@Singleton` types inside `@Container`-annotated declarations as that container's bindings; static `@Provides` on non-`@Container` enclosing types continue to feed the default graph (preserves 2a)
- Per-container `_<ContainerName>WireGraph` struct generated alongside the default `_WireGraph`. Each has its own `bootstrap()` static method; type-based stored-property naming and the free-function delegation pattern from 2a carry through
- Default `bootstrap()` (no container) continues to use only module-scope `@Provides` and module-scope `@Singleton`s
- Multiple `@Container` enums with different names → multiple independent selectable graphs

**Container composition rules** (atomic per the README's "selection is atomic" rule):
- Container's graph = the `@Provides` declarations and `@Singleton` types declared *inside* `@Container`-annotated declarations targeting the same type name. Nothing leaks in from module scope.
- A `@Singleton` nested inside a `@Container` declaration belongs to that container's graph, not the default graph.
- 2b implements **implicit-type-key containers**: a primary `@Container enum Foo { ... }` and any `@Container extension Foo { ... }` declarations all merge their bindings into one container called `Foo`. The opt-in is loud — a plain `extension Foo { @Provides ... }` (no `@Container` annotation) does *not* contribute to the container; its bindings fall through to the default graph with a `Foo.member`-style access path. Iteration 3's diagnostic gallery will warn when this fall-through is likely unintentional.
- Explicit-key composition (multiple types contributing under a `ContainerKey`) is deferred — see below.

**Validation gate:** test app with a `@Container` enum holding multiple `@Provides` and at least one nested `@Singleton`; `_<ContainerName>WireGraph.bootstrap()` produces a graph with the container's bindings only. Default `bootstrap()` still works using only module-scope `@Provides` and module-scope `@Singleton`s. A `@Container extension Foo` correctly merges into `Foo`'s graph alongside the primary declaration. Two `@Container`s with different names produce two independent generated structs.

## Iteration 3 — validation diagnostics

This is Risk #4 ("macro diagnostics") and Risk #5 ("resolution edge cases") meeting reality. Building it on top of the basic pipeline (rather than after every feature lands) means you can write diagnostic test cases against real graphs.

**Scope:**
- Missing-binding errors (compile error pointing at the `@Inject` site)
- Cycle detection (compile error naming each edge of the cycle)
- Ambiguity errors with explicit-key disambiguation (`@Inject(Foo.key)`)
- Generic specialization (when one binding satisfies a generic constraint, specialise; when multiple do, the explicit-key rule applies)
- Whitespace normalisation for type-expression matching (M0 finding from Spike 3 — `Router<X, Y>` and `Router<X,Y>` resolve to the same binding)
- **Extension-init detection on `@Singleton` types.** The macro can't see extensions, so `@Inject` on an extension init is silently ignored and a non-`@Inject` extension init either collides with the macro-generated init (Swift redeclaration) or is silently shadowed by it. The build plugin's whole-file parse can detect both cases and emit Wire-specific diagnostics: "@Inject on an extension init is ignored; move it to the primary declaration of `Foo`" and "extension init conflicts with Wire's generated init for `Foo`; move it to the primary declaration and mark it @Inject if it should be the canonical one." Both diagnostics point at the extension init with the precise remedy, replacing Swift's confusing "invalid redeclaration" or the silent-shadow non-error.
- **Unannotated-extension `@Provides` warnings.** 2b lets `@Provides` in a plain (un-`@Container`-annotated) `extension Foo { ... }` fall through to the default graph with a `Foo.member` access path. That's correct as a default but is almost certainly *not* what the user wanted when the extended type itself has a `@Container` declaration elsewhere, or when the extended type isn't declared in this module. Two warnings to add:
  - `@Provides` in an extension of a type that has a `@Container` declaration: "this `@Provides` falls through to the default graph; if you intended it to extend the container, mark the extension `@Container`."
  - `@Provides` in an extension of a type not declared in this module: "this `@Provides` falls through to the default graph under `<TypeName>`'s namespace; consider declaring at module scope or as a member of a type you own."
  Both need the type-declaration index iteration 3 will be building anyway for missing-binding errors.
- **`@Container` combined with a scope annotation on the same type.** A type can technically carry both `@Container` and a scope macro (`@Singleton`, eventually `@RequestScope`/`@JobScope`). 2b doesn't reject the combination — it just routes the type into the default graph as the scoped binding *and* treats the same type's static `@Provides` as a container. That's almost certainly user error: the type ends up as both a node in one graph and a grouping for another. Iteration 3 should warn at the `@Container`-annotated decl with the precise remedy ("split into two types: a `@Singleton` for the instance binding and a separate `@Container` enum for grouping").

**Validation gate:** a "diagnostic gallery" test directory containing intentionally-broken graphs:
- Missing binding for a primitive type
- Missing binding for a generic instantiation
- Two-type cycle (A → B → A)
- Three-type cycle (A → B → C → A)
- Ambiguous binding requiring a key
- Deep generic instantiation across multiple `@Singleton`s
- `@Inject`-marked init in an extension of a `@Singleton` type
- Non-marked init in an extension of a `@Singleton` type that Wire is auto-generating an init for
- `@Provides` in an unannotated extension of a `@Container`-declared type
- `@Provides` in an extension of a type not declared in this module

Each broken graph produces a precise error pointing at the right source location with a fix-it where applicable. The diagnostic gallery becomes the regression suite for diagnostic quality from this point forward.

## Iteration 4 — `@RequestScope`, `@JobScope`, `Provider<T>`

The other two scopes plus the scope-crossing wrapper.

**Scope:**
- `@RequestScope` macro
- `@JobScope` macro
- `Provider<T>` runtime type — likely a `@Sendable () async throws -> T` closure-backed wrapper that the build plugin populates with the appropriate scope-resolution logic. Decide whether `Provider<T>` needs the `Resolver` protocol (deferred from iteration 1) once we see what the closure-based version costs in practice.
- Build plugin's check that refuses storing a `@RequestScope` value as a property on a `@Singleton` (compile error with a fix-it suggesting `Provider<...>`)

**Validation gate:** test app with a `@Singleton` injecting `Provider<RequestLogger>`-style; calling `provider()` returns a fresh value each invocation; storing a `@RequestScope` directly on a `@Singleton` produces the expected compile error.

## Iteration 5 — multibindings

All four key flavours plus the unified `@Contributes(to:)` annotation.

**Scope:**
- `@Contributes(to:)` macro
- `CollectedKey<T>` with `withOrder:` parameter
- `MappedKey<K, V>` with `atKey:` parameter
- `BuilderKey<B>` (uses the user's result-builder type to fold contributors)
- Build plugin parameter validity checks (`withOrder:` only on `CollectedKey`, `atKey:` required on `MappedKey`, no mixing)

**Validation gate:** test app with three contributors to a `CollectedKey<any Service>` (with `withOrder:` covering ordered + unordered cases), two contributors to a `MappedKey<String, Strategy>` (including the duplicate-key compile error case), two to a `BuilderKey<MiddlewareBuilder>` exercising real result-builder constraints. Each consumer gets the right shape with the right ordering and the right type.

## Iteration 6 — `Lifecycle` and `Resource<T>` (types only)

The lifecycle types ship in M1 to lock the public API. Orchestration (when teardown actually fires) is M4.

**Scope:**
- `Lifecycle` protocol
- `Resource<T>` wrapper type (consumer-side `T` resolution; resolver unwraps from `Resource<T>` at the `@Provides` site)
- Build plugin recognises `Lifecycle` conformance and `Resource<T>` wrappers but does *not* yet generate teardown calls

**Validation gate:** test app with a `Lifecycle`-conforming `@Singleton` and a `Resource<HTTPClient>`-style `@Provides`; bootstrap constructs them; consumers `@Inject` the unwrapped types; manual cleanup is the only way to teardown (M4 lands the orchestration).

## Iteration 7 — multi-module composition

Cross-target binding aggregation, the activation model, transitive-activation diagnostics. Needs all of iterations 1–6 to be solid because it exercises them across module boundaries.

**Scope:**
- `_WireExports.swift` marker file as the discovery mechanism (M0 finding from Spike 1)
- Build plugin reads dependency target source via the SPM plugin context (Spike 1's pattern)
- `.activating(LibraryName.self)` at the consumer's entry point
- Same-package targets auto-activate; external-package targets require explicit `.activating(...)`
- Cross-library validation (every `@Inject` satisfied somewhere in the activated set)
- Missing-direct-binding diagnostic across libraries
- Missing-transitive-activation diagnostic with fix-it (e.g., "WireOpenAPI references `Router<...>` declared in WireHummingbird; activate WireHummingbird")

**Validation gate:** two-package test setup mirroring task-cluster's structure (consumer + library); the consumer activates the library; bindings from both compose; deactivating the library produces a clear error at the relevant `@Inject` with the suggested fix.

## Iteration 8 — adapter-annotation contract

Risk #6's mitigation lives here. Builds the contract surface that M3, M4, and M5's adapters will be written against, with a throwaway adapter as a regression test.

**Scope:**
- Manifest format spec (Wire-aware library declares its adapter annotations: name, form, phase, contract version)
- Library-side manifest registration mechanism
- Build plugin discovers adapter macros from dependency manifests
- `_wireRegister` parameter extraction (Spike 3's pattern)
- Validation of adapter-declared dependencies against the binding graph
- Generated bootstrap emits `_wireRegister` calls in phase order (post-graph for M1; per-request and per-job phases land later when an adapter actually needs them)
- Throwaway `@RoutedBy`-style adapter built in this iteration as a regression test (don't ship it publicly until M3)

**Validation gate:** the throwaway adapter's `_wireRegister` is detected, validated, and called in the bootstrap. Missing parameter binding produces an error pointing at the adapter annotation. Removing the adapter library from `.activating(...)` deactivates the registration cleanly.

## Iteration 9 — output, diagnostics polish, task-cluster migration

Tail-end work scope-bounded by what earlier iterations surfaced.

**Scope:**
- `_WireGraph.json` build-time dump (the runtime `Resolver.introspect()` API is M2, not M1)
- Diagnostic-quality pass: re-read every error message that fires across the test suite; fix the worst ones; tighten fix-it text
- task-cluster migration completion (most of it should already be migrated incrementally — this iteration is the cleanup)
- Linux CI configured (matrix: macOS Swift 6.3, Linux Swift 6.3.1, both producing identical bootstraps for the same input)

**Validation gate:** task-cluster builds with Wire, produces correct output (existing tests still pass), framework integration is still manual per the README's M1 scope. `_WireGraph.json` is produced and inspectable. CI passes on both platforms with no skipped tests.

## Cross-cutting concerns

### task-cluster as the validation vehicle

Don't migrate task-cluster all at once at iteration 9. Migrate incrementally as Wire features become available:

- After iteration 2a: replace task-cluster's manual `Logger` and `InMemoryDynamoDBCompositePrimaryKeyTable` wiring with module-scope `@Provides`. The repository and controller stay manually constructed.
- After iteration 3: confirm the migration's diagnostics behave well (introduce a deliberate missing binding, fix it, see the diagnostic improvement work in real time).
- After iteration 5: if any task-cluster behaviour benefits from `@Contributes` (e.g., a list of middleware), migrate it.
- After iteration 7: if task-cluster's library targets exercise multi-module composition meaningfully, validate against them.
- After iteration 8: if iteration 8's throwaway adapter approximates `@RoutedBy`, use it as a sketch of M3.
- Iteration 9: complete any residual migration; everything that was manually wired in `TaskCluster.swift` and `Application+build.swift` is now Wire-driven (except the framework-level `Application(...)` construction, which stays manual until M2's `WireHummingbird`).

### Diagnostic quality is iterative

Iteration 3 sets the diagnostic-quality standard. Every iteration after that re-validates new error paths produce good diagnostics. If iteration 8 introduces a confusing "missing binding from adapter" error that iteration 3's work didn't anticipate, fix it then, not later.

The diagnostic gallery from iteration 3 is the regression suite — extend it as iterations add new error paths.

### Test fixtures live alongside iterations

Each iteration grows the test suite; don't ship an iteration without its fixtures. The diagnostic gallery is the template: a directory of small fixtures, each demonstrating one specific behaviour, with assertions about the resulting diagnostics or runtime output.

### Macro surface stays small

Risk #1 ("swift-syntax tax") gets mitigated by keeping macros lean — most logic lives in the build plugin, which is more stable across Swift versions. When tempted to put logic in a macro, ask: "could this be done by the build plugin reading the macro's output instead?" If yes, do that.

## Deferred decisions

Decisions where the README describes a target shape, but iteration 1 / Step A intentionally doesn't commit to the implementation until a concrete iteration needs it.

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

## Estimating

Hard to be precise; iterations 3 and 8 have the most variance.

- Iterations 1–2: a few weekends each
- Iteration 3: longer, possibly several weeks (diagnostic polish is iterative)
- Iterations 4–6: weekend-scale each
- Iteration 7: a couple of weeks (multi-module integration is fiddly)
- Iteration 8: hard to estimate — depends on how much manifest format ends up needing in practice
- Iteration 9: tail-end polish, scope-bounded by what earlier iterations surfaced

Calendar: realistically 3–6 months part-time alongside task-cluster's own development. The honest range is wide because iterations 3 and 8 have the most variance.

## When M1 is "done"

Per the README's M1 entry: "task-cluster's manual wiring switches to Wire-driven construction; framework integration stays manual at this point. No public 0.x tag yet."

Concrete done-criteria:

- task-cluster's `TaskCluster.swift` and `Application+build.swift` no longer manually construct `DynamoDBTaskRepository`, `TaskController`, or thread their dependencies — Wire does it.
- All existing task-cluster tests still pass.
- `_WireGraph.json` is produced as part of the build and accurately reflects the wired graph.
- The diagnostic gallery passes on both platforms.
- CI runs on macOS Swift 6.3 and Linux Swift 6.3.1.
- No public 0.x tag yet — the README's "Status: pre-alpha" stays loud per Risk #2.

The 0.x tag itself is a calendar gate, not an iteration: per the README, "used in one of my own services for at least a month before any 0.x release." So M1 ending and 0.1 shipping are different events; M1 ends when the iterations above are done, and 0.1 ships after a month of using it in task-cluster development without fundamental issues surfacing.

## What this plan deliberately doesn't include

- **No version-tagging plan.** v0.1 ships when M1 is done *and* used in task-cluster for at least a month per the README.
- **No "done is done" bar for diagnostics.** The standard is "you don't get confused by an error during normal task-cluster development." That's subjective; the diagnostic gallery is the floor and you stop polishing when the floor's high enough.
- **No fallback plan for M0 retrofits.** All four M0 spikes passed; no surprises lurking. If implementation work surfaces a problem the spikes missed, document and adjust — that's an unplanned slip, not part of the plan.
- **No design changes.** The README is the design spec. If implementation surfaces something the design got wrong, edit the README first, then update this plan, then continue. Don't drift the plan from the design silently.
