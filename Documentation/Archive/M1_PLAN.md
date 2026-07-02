# M1 Implementation Plan — archived

> **Archived.** M1 is complete — every iteration below shipped and task-cluster
> runs Wire-driven. This is the historical plan, kept as the record of what M1
> built and the design decisions settled along the way. Forward-looking work
> (pre-1.0 polish, deferred features, post-M1 milestones) moved to
> [ROADMAP.md](../../ROADMAP.md).

This was the implementation plan for M1 of swift-wire — the milestone where the core graph, build plugin, validation, multi-module composition, and adapter-annotation contract land. M0's validation spikes have all passed (see [the spikes repo](../../../swift-wire-spikes)) and the design committed in [README.md](../../README.md) is ready to build against.

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
- **Generated-identifier collisions across bindings.** Sitting 1c's `identifierName(forType:key:)` uses a `Keyed` infix separator (matching the `Of`/`And` pattern from generic-instantiation sanitisation) to push collisions out to "type names literally containing the word `Keyed` in the matching position" — vanishingly unlikely in real code. But the collision space isn't empty, and a future identifier-mangling rule could narrow it further. Add a codegen-time check: group every binding by its generated identifier; if any group has > 1 member, emit a Wire diagnostic at each contributing binding site listing the collision and suggesting a rename. Catches the "someone is deliberately trying to break the system" case cleanly with a Wire-shaped error pointing at user source, rather than letting Swift's "invalid redeclaration" fire on the generated file.

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
- Generated-identifier collision (e.g. an adversarial `@Singleton struct DatabaseKeyedDatabasePrimary` alongside `@Provides(Database.primary) ... : Database`) — Wire diagnostic instead of opaque Swift "invalid redeclaration" on the generated file

Each broken graph produces a precise error pointing at the right source location with a fix-it where applicable. The diagnostic gallery becomes the regression suite for diagnostic quality from this point forward.

## Iteration 4 — seed-typed scopes, `Lazy<T>`, cross-scope validation

The planned `@RequestScope` / `@JobScope` named-scope macros are replaced by a single seed-typed scope macro — `@Scoped(seed: SeedType.self)`. The seed type *is* the scope identity: two `@Scoped` types share a scope iff their seed types match. Multiple adapters (Hummingbird, Vapor, SQS, Redis, schedulers) publish independent sibling scopes keyed by their own seed types, avoiding the named-scope namespacing problem that `@JobScope` would have produced when multiple job-handling adapters coexist. See `Documentation/Notes/ArchitecturalPatterns.md` for the architectural framing.

`Provider<T>` is removed from this iteration's scope. Most cross-scope-reading cases collapse under "scope the consumer correctly" or "compose via a wrapper at the appropriate scope" — see the deferred-decision entry below. `Lazy<T>` ships in its place as a regular public type Wire happens to define: same closure-backed runtime shape (defer construction to first call, cache after), no special framework recognition. The case for `Lazy<T>` (lazy initialisation of expensive deps) is independent of any cross-scope reading.

**Sittings:**

- **4a — `@Scoped(seed:)` macro + discovery + per-seed graph routing + code emission.**
  - `Sources/Wire/Macros.swift` declares `@Scoped<Seed>(seed: Seed.Type)`.
  - `Sources/WireMacrosImpl/ScopedMacro.swift` implements expansion (delegates to `SingletonMacro.expansion`; the synthesised members are identical, only the unsupported-declaration error message differs).
  - `BindingDiscovery` recognises `@Scoped(seed:)`-annotated types, extracts the seed type expression, and routes bindings into the unified `[Partition: [DiscoveredBinding]]` map under a `Partition` whose `scope` carries the seed.
  - `DiscoveredSingleton` (renamed to `DiscoveredScopeBoundType` to reflect dual `@Singleton`/`@Scoped` use) carries an optional `scopeKey: ScopeKey?`.
  - Per-seed binding partitions in `SourceFileDiscovery.allBindings`. WireGen aggregates and builds one graph per seed type; the seed type is implicitly bound within its scope.
  - Code emission generates a `_<SeedTypeName>WireScope` struct per seed, mirroring the per-`@Container` codegen pattern.
  - Wire core publishes `withScope<Seed>(seeding seed: Seed, body: (Resolver) async throws -> T) async rethrows -> T` as the entry-point primitive.
  - **Worked-example adapter convenience macro:** ship one hand-coded adapter macro alongside the test fixtures (e.g. `@TestRequestScope` expanding to `@Scoped(seed: TestRequestSeed.self)`) as a forward-looking demonstration of what adapter packages will publish in iteration 8. Not part of the contract — purely an example.
  - **README rework:** the "Scope annotations" section gets rewritten around `@Singleton` and `@Scoped(seed:)`; `@RequestScope`/`@JobScope` references throughout become `@Scoped(seed: …)` with a forward-looking note about adapter convenience macros.
  - Existing iteration-3 diagnostics that hard-code scope-macro names already generalise (`scopeMacroNames` is now `["Singleton", "Scoped"]`); the extension-init-conflict warning iterates the unified partition map so both `@Singleton` and `@Scoped` types are covered.
- **4b-pre — effect-aware emission for bindings.** Prerequisite for 4b; closes a latent gap from iteration 2's `@Provides func` work. See `Documentation/Notes/EffectAwareResolution.md` for the design depth — the conceptual unification of DI and data resolution, the levels-of-construction-strategy trajectory (Level 1 ships now; Levels 2+ deferred to forcing conditions), and prior art at each level.
  - Discovery extension: capture `effectSpecifiers` from `FunctionDeclSyntax` (`@Provides func`), `InitializerDeclSyntax` (`@Inject init`), `AccessorDeclSyntax` (`@Provides` computed properties). Record `isAsync: Bool` / `isThrowing: Bool` on the matching `DiscoveredProvider` / `DiscoveredScopeBoundType`.
  - Emission extension: `constructionExpression` prefixes each binding's call site with `try `, `await `, `try await `, or nothing based on the captured flags. The bootstrap is `async throws` (the widest contract) so any sub-call colour is permitted.
  - Tests: each colour (sync, async, throws, async throws) for `@Provides func`, `@Provides` computed property, `@Inject init`; unit tests on the rendering plus integration tests exercising a real async binding through bootstrap.
- **4b — `Lazy<T>` runtime type.** Builds on 4b-pre. See `Documentation/Notes/LazyTypeSupport.md` for the design depth — architectural principle (widest-contract = best port; T's init colour stays producer-side), `.get()`-canonical API, idiomatic patterns (heavy init, first-use singleton, mixing eager + lazy consumers), and the reasoning behind not pursuing framework-level wrapper-marker recognition.
  - Wire core publishes `public struct Lazy<T: Sendable>: Sendable` with `public func get() async throws -> T`. First call invokes the factory closure (whose contents the user controls — typically constructing a `T` from values captured at the `@Provides` site); result is cached for subsequent calls. Internal `LazyBox<T>` class uses a tri-state `Mutex<State>` (`.unmarked → .pending(Task) → .resolved(Value)`) mirroring `AtomicState<T>`'s lifecycle vocabulary — post-resolution gets read the value directly without a Task hop and release the factory closure's capture.
  - Build plugin treats `Lazy<T>` like any other Swift type. No wrapper recognition, no consumer classification, no synthesised wrappers, no no-effect warning. Users opt into deferral by writing a `@Provides` that returns `Lazy<T>` and consumers requesting `Lazy<T>` get matched through normal binding identity.
  - Cycle detection unchanged — `Lazy<T>` is just a binding type and graph edges work the way they would for any other type. Cycle-breaking that uses Swift's `weak` keyword + post-construction assignment is a separate planned iteration (see iteration 4e below).
- **4c — cross-scope storage validation.**
  - A `@Singleton` directly storing a `@Scoped(seed: X.self)` value is a compile error with a fix-it: "make the consumer `@Scoped(seed: X.self)` too, or extract the request-scoped concern into a `@Scoped(seed: X.self)` wrapper."
  - Two `@Scoped` types with different seeds directly storing each other is the same error class, same fix-it shape.
  - The check is framed as **scope-inheritance rules**, not as "`@Singleton` vs `@Scoped`" specifically — so the same code generalises to multi-level hierarchies if `@Scoped(within:)` lands later.
- **4d — integration test.** End-to-end fixture: a seed type (`TestRequestSeed`), one or more `@Scoped(seed: TestRequestSeed.self)` types injecting the seed and singletons, `withScope(seeding: ...)` entry, two scope entries produce distinct instances, a second seed type produces an independent scope. Adds a user-written `@Provides static func makePool(...) -> Lazy<TestResource>` fixture demonstrating the heavy-init / first-use-singleton pattern: the factory runs once on first `.get()`, the result is cached, and the underlying instance is shared across consumers of the same `Lazy<TestResource>` binding. Demonstrates the cross-scope-storage error fires with the expected fix-it text.
- **4e — weak-reference injection (cycle-breaking via Swift's `weak`).** Distinct sitting, optional for M1; can land at the end of iteration 4 or push to a later milestone if 4 is running long. See `Documentation/Notes/WeakInjectionSupport.md` for the design depth — post-construction assignment, weak edges as cycle-breakers, the asymmetry with `Lazy<T>` (Lazy is just a type; weak leans on Swift's language keyword).
  - Macro: `@Inject weak var pool: DatabasePool?` is recognised and excluded from the synthesised init's parameter list. The property stays as Swift's native `weak var x: T?` storage.
  - Discovery: a new `DependencyKind` (or a flag on the existing kind) distinguishes weak-deferred property deps. The dep type stays `T` for resolution purposes.
  - Graph: weak-deferred edges still contribute to topological ordering (T must be constructed before the post-init assignment) but skip cycle detection. A `A → B` strong edge + `B → A` weak-deferred edge is a valid graph.
  - Codegen: after the topological construction block, emit a post-init assignment block: `handler.pool = pool`. Ordering naturally satisfies both edges.
  - Integration test: a `@Singleton` cycle that compiles by virtue of one side being `weak`; runtime test confirms the weak reference zeros out when the strong holder is released.

**Hooks for future hierarchical-scope work.** `@Scoped(within:)` is a deferred decision (see below); iteration 4a already leaves the cheap-to-leave hooks so reopening it later doesn't require touching the original infrastructure. `ScopeKey` is shaped `(seed: String, within: String?)` from day one with `within` always `nil`; the partition is keyed by the full `(container, scope)` pair via `Partition`; cross-scope-storage validation in 4c is phrased as scope-inheritance rules; the entry-point primitive stays `withScope<Seed>(seeding:body:)` and is forward-compatible with adding `withSubScope` methods to the resolver type.

**Forward-compatibility notes.** `@Scoped(seed:)` and `Lazy<T>` are framed as the features that would shift shape most if Swift ever gained native effect handlers — they're the scope-and-deferred-evaluation cases where a static graph stops fitting and a handler-based implementation would be the natural representation. API-framing choices to make deliberately at this iteration so a future migration stays open:

- **`@Scoped(seed:)` framed as a dynamic extent** — `withScope(seeding:) { ... }`-shaped entry points, not mutable graph state or thread-local registries. Same mental model a handler-based implementation would use natively.
- **`Lazy<T>` framed as "deferred-and-cached resolution,"** not "a captured closure you call." Implementation today is closure capture with `Mutex`-guarded result memoisation; the documented contract is the effectful-operation framing. A future handler-based implementation could replace the closure without changing the user-facing surface.
- **Avoid baking in any specific concurrency primitive** (custom executor, particular actor-isolation shape) at this level. `Sendable` and standard `async throws` are the surface; the rest is implementation.

See also: "Dynamic binding lookup by `Any.Type` (rejected)" and "Cross-scope reads from outer scope (`Provider<T>`)" under Deferred decisions for the related forward-compatibility commitments.

**Validation gate:** the 4d integration test passes. `@Scoped(seed:)` types are constructed per `withScope` entry, sharing singletons but isolated between scope entries. A user-written `@Provides -> Lazy<T>` defers the underlying construction to first `.get()` and caches the result. A `@Singleton` storing a `@Scoped` value directly produces the documented compile error. (4e, if it lands in this iteration, has its own integration test for weak-injected cycle-breaking.)

## Iteration 5 — visibility-driven diagnostics + multibindings

Split into two sub-iterations. The diagnostic infrastructure (5α) lands first because it establishes a policy that multibindings (5β) inherits — building it the other way around would mean baking in multibinding-specific empty-handling shapes and then refactoring them when the generalization arrives. See `Documentation/Notes/VisibilityModel.md` for the design contract that pins what both sub-iterations build on.

### Iteration 5α — visibility-driven dead-binding diagnostics

Reads source-level access modifiers to drive diagnostic strictness: Wire warns about "declared but never consumed" patterns for non-public bindings (where Wire has full build-time visibility) and stays silent for public bindings (where downstream consumers may exist). The model also pins the contract for future container composition — access modifiers will become the composition-boundary markers, with no extra annotation surface.

**Scope:**
- Discovery extensions: capture access-level modifier on every binding declaration (`@Singleton`/`@Scoped` types, `@Provides` properties/functions, `BindingKey<T>` static declarations) and on host types for `@Inject` consumers.
- Graph extensions: per-binding consumer count, computed as part of dependency resolution.
- **Declaration-too-private error** (severity: `.error`): any source-level name Wire's generated bootstrap textually references — `@Singleton`/`@Scoped` types, `@Provides` declarations, `@Container` enums, `@Inject init`, `@Inject weak var` properties, `@Inject func` methods, `BindingKey<T>` static declarations — must be at least `internal`. `fileprivate` and `private` produce a build-blocking diagnostic at discovery time, anchored at the user's declaration rather than at the generated bootstrap. `@Inject weak var` and `@Inject func` get an additional `Diagnostic.Note` explaining why the asymmetric `@Inject var` / `@Inject let` (constructor-injected) doesn't have the same constraint — the macro generates the init within the host type's scope, so `@Inject private var` works fine while `@Inject private weak var` doesn't. Structural prerequisite for the dead-binding warning below (and for everything downstream).
- **Dead-binding warning** (severity: `.warning`): for non-public bindings with zero consumers in the module. Public bindings stay silent. Threaded through iteration 4's `Diagnostic` infrastructure.
- Silencer for the dead-binding warning: explicit per-declaration opt-in (`allowUnused:` / `permitMissing:` — naming finalised during implementation). The declaration-too-private error isn't silenceable — it's a structural compile-time issue.
- Documentation: README iteration-5 prose mentioning the post-`package` visibility triad expectation and how Wire's policy fits.

**Validation gate:** test fixture with mixed-visibility bindings demonstrating both diagnostics correctly distinguish. A `fileprivate @Singleton` produces the declaration-too-private error and the build fails. An `internal @Singleton` without consumers warns; a `public @Singleton` without consumers stays silent; the silencer parameter takes effect. Existing iteration 1-4 binding kinds covered (Singleton, Scoped, Provides, BindingKey).

### Iteration 5β — multibindings

All four key flavours plus the unified `@Contributes(to:)` annotation. Inherits 5α's diagnostic infrastructure for the dead-key case; adds an empty-contributor warning (consumer exists but no `@Contributes` annotations) as a multibinding-specific check under the same visibility-driven policy. See `Documentation/Notes/BuilderKeyDesign.md` for the design depth on `BuilderKey<B>` — emission via result-builder attribute, return-type derivation from `buildBlock` / `buildFinalResult`, coupling with `OpaqueTypesSupport.md`, ordering decision settled (compile error when `withOrder:` mixed with unranked contributors).

**Scope:**
- `@Contributes(to:)` macro
- **Producer-side key-declaration reading, uniform across all three flavours.** Discovery gains a key-declaration scanner that finds `static let X = CollectedKey<…>/MappedKey<…>/BuilderKey<…>("name")` declarations and extracts the flavour, the type argument(s), and the key string; aggregate nodes take their element/value/result type and their flavour from this declaration, never from contribution sites or consumer annotations. `BuilderKey` *forces* this — without opaque support the emitted `@resultBuilder` fold function needs an explicit concrete return type, whose only producer-side source is the builder's `buildBlock` / `buildFinalResult`. Rather than run declaration-reading for `BuilderKey` and string-only offload (the `BindingKey` `_check<T>` precedent) for the other two, all three read declarations: one discovery discipline, uniform producer authority, better diagnostics (contributor-type mismatch, empty aggregate typed without a consumer, flavour-wrong `withOrder:`/`atKey:`). Matching stays string-keyed and module-wide (the `Service.lifecycle` reference matches the declaration's reconstructed `(enclosingType, member)` name, same opaque-string discipline as today's keyed bindings); the compiler `_check<T>`-style assertion is still emitted as a backstop so reference→declaration matching brittleness (module qualification, typealiases) can't silently mis-wire.
- `CollectedKey<T>` with `withOrder:` on `@Contributes` for explicit ordering
- `MappedKey<K, V>` with `atKey:` on `@Contributes` for key disambiguation
- `BuilderKey<B>` with return-type derivation from the builder's `buildBlock` / `buildFinalResult` signature; `withOrder:` on `@Contributes` for ordering the fold-function parameters (often type-relevant for order-sensitive builders like middleware chains). The parameterized-opaque case is deferred to when `OpaqueTypesSupport.md` lands; see the design note for the split.
- Build plugin parameter validity checks (`withOrder:` valid on `CollectedKey` and `BuilderKey` contributions only, `atKey:` required on `MappedKey` contributions only, no mixing).
- Empty-contributor warning piggy-backing on 5α's diagnostic infrastructure: non-public multibinding key with consumer but zero contributors → warn. Public keys stay silent. Silenceable via the same silencer mechanism 5α establishes.
- Keys are global identities, not container-owned: any partition (default graph, container, or seed scope) may contribute to a declared key, and each partition builds its own aggregate. This enables the production/test-container pattern — a module-scope key with a `Prod` and a `Test` container each supplying their own contributors, selected at the entry point. A stray contributor (no consumer in its partition) becomes a dead binding (the visibility-gated warning), not a hard error. (An earlier cross-container *rejection* was tried and reverted — it wrongly treated keys as owned by their declaring container.)
- `@Contributes(to: X)` referencing a key `X` that isn't a discovered key declaration → missing-key diagnostic. "Discovered" means *within the plugin's parse set* — one module today; under multi-module/package composition the key may live in any parsed package, gated by visibility (see `Documentation/Notes/MultiModuleComposition.md`). The check is "no such key in the parse set," which widens automatically as the parse set does.
- `@Contributes` requires a co-located producer macro (`@Singleton`/`@Scoped`/`@Provides`) to give the contributor a lifetime; bare `@Contributes` → diagnostic. Argument-shape validity (`atKey:` required on `MappedKey`, `withOrder:` mapped-disallowed, key-type of `atKey:`) is carried by the `@Contributes` overload set at the type level; the plugin only enforces the cross-contributor rules overloads can't see (no-mixing `withOrder:`, duplicate `atKey:`).

**Implementation plan:** the sequenced build order (de-risk spikes → surface → discovery → graph → codegen → diagnostics → gate, each a shippable commit) lives in `Documentation/Notes/MultibindingsImplementationPlan.md`.

**Validation gate:** test app with three contributors to a `CollectedKey<any Service>` (with `withOrder:` covering ordered + unordered cases), two contributors to a `MappedKey<String, Strategy>` (including the duplicate-key compile error case), two to a `BuilderKey<MiddlewareBuilder>` exercising real result-builder constraints and `withOrder:`-driven contributor sequencing. Each consumer gets the right shape with the right ordering and the right type. Plus an empty-multibinding fixture demonstrating the visibility-driven warning policy (`internal` empty key warns; `public` empty key stays silent).

## Scopable `@Provides` — scope blocks (post-iteration-5 addition)

> Added after iteration 5, slotted here with the scope/lifecycle work (it
> extends iteration 4's seed scopes). Kept outside the 6–9 numbering to
> avoid renumbering the cross-references throughout this plan.
> **Status: implemented.** Design depth — including the
> self-production / membership / definition framing and the deferred items
> — lives in `Documentation/Notes/ScopeAndKeyModelEvolution.md` (Axis A).

Extends seed scopes to explicit producers. A `@Scoped(seed: X.self)`
namespace enum is a **scope block** — the scope-axis sibling of
`@Container` — and routes the `@Provides` declarations inside it into the
`X`-seed scope. The seed is declared once on the block, not per producer.

**Why a block, not per-producer `@Provides @Scoped`.** A macro's
`@attached` roles all apply to its target, so one `@Scoped` can't be a
member macro on types *and* a peer macro on producers — `@attached(member)`
on a func/var is a hard compiler error (and `assertMacroExpansion` doesn't
catch it; the real compile did). The block sidesteps this (the marker only
ever sits on an enum, which bears members), is less verbose, *and* is the
scope-*definition* surface Wire previously lacked — the `@Container`
analog for the scope axis.

**Scope:**
- `@Scoped(seed:)` on a namespace enum as a scope-block marker. The macro's
  member role emits nothing on an enum (inert marker, like `@Container`);
  it still synthesises `init`/`key` on struct/class/actor. `@Scoped` on a
  var/func is now a plain compiler error, so no plugin check is needed.
- Discovery tracks an enclosing `seedScope` on the visitor frame
  (mirroring `containerName`); `@Provides` inside a block inherit it.
  Maps 1:1 onto the existing `Partition(container, scope)`, so **no graph
  or codegen change** — a scoped provider flows through
  `orchestrateSeedScope` as an ordinary scope binding, and composes with
  `@Container` into `(container, seed)` cells.
- `@Singleton` inside a scope block is a diagnosed error — process
  lifetime can't live in a seed scope, and left unflagged it would
  silently route to the process graph. Self-producing `@Scoped(seed:)`
  types are unaffected; they carry their own seed.
- **Deferred** (recorded in the design note): bare `@Scoped` inside a block
  meaning "self-produce, inherit the block's seed"; the fuller
  self-production / scope separation (a scope-neutral self-production
  marker); and keyed-and-scoped `@Provides`.

**Validation gate:** a `@Scoped(seed:) enum` block with a `@Provides`
function that reads the seed *and* borrows a singleton, plus a `@Provides`
property constant, consumed by a scope-bound type; the generated per-seed
scope bootstraps with the right values and ordering
(`ScopedProvidesExample`).

## Iteration 6 — `@Teardown` (annotation only, recorded but inert)

The teardown annotation ships in M1 to lock the public API. Orchestration (when teardown actually fires) is M4.

**Design pivot from the original plan.** The plan originally specified a `Lifecycle` protocol and a `Resource<T>` wrapper the build plugin unwraps at the `@Provides` site. Both were dropped during this iteration: `Resource<T>` is a framework-recognised, silently-unwrapped wrapper — exactly the "magic type" Wire has refused elsewhere (`Lazy<T>` is just a type; dynamic `Any.Type` lookup is rejected; `Provider<T>` deferred) — and its stated rationale ("third-party types you can't add a conformance to") is a JVM constraint Swift doesn't have. A recognised `Lifecycle` conformance is milder magic but still magic (a runtime `as? Lifecycle` probe), can't distinguish two bindings of the same type with different teardown needs, and pushes a per-binding decision into the type system. Both are replaced by a single explicit annotation, `@Teardown`, declared at the binding's declaration site. See `README.md` ("Lifecycle and teardown") for the committed design; the producer-form ergonomics were validated in spike-5 (`../swift-wire-spikes/spike-5-teardown-closure-ergonomics`).

**Scope:**
- `@Teardown` macro (two inert peer-macro overloads), recognised by the build plugin but emitting no teardown calls yet:
  - **Owned-type member form** — `@Teardown` (no argument) marking the teardown method on a `@Singleton`/`@Scoped` type. The method may be any name and takes no parameters, but must be at least `internal` (the generated bootstrap calls it from a separate file — the same post-construct visibility rule as `@Inject func`); effect specifiers (`async`/`throws`) are read off its declaration. Mechanically the marker-on-method pattern spike-2 already proved.
  - **Producer form** — `@Teardown(<action>)` on a `@Provides func`/`@Provides var`, where `<action>` is an explicit-typed closure (`@Teardown({ (c: HTTPClient) in try await c.shutdown() })`) or a free/static function reference (`@Teardown(shutdownClient)`). The produced type stays honest (no wrapper, no unwrap); consumers inject it directly. Spike-5 confirmed: attributes take no trailing-closure sugar (parenthesise the closure), `$0`-inference doesn't reach across the attribute (explicit parameter type required), and sync actions coerce into the `async throws` contract.
- Discovery records a `TeardownAction` on `DiscoveredScopeBoundType` (member form) and `DiscoveredProvider` (producer form). The build plugin extracts the action by source-parsing (spike-3's mechanism), not from an expanded peer.
- Misuse diagnostics (iteration-appropriate; diagnostics are iterative): bare member-form `@Teardown` with no enclosing scope-bound binding; producer-form `@Teardown` on a non-`@Provides`; a member-form teardown method that is `static` or takes parameters; more than one `@Teardown` per binding.
- No runtime types ship — only the annotation. Code emission is unchanged (no teardown calls).

**Validation gate:** test app with a `@Singleton` carrying an `@Teardown` method *and* a `@Provides` returning a third-party-style type with an `@Teardown` closure; bootstrap constructs both; consumers `@Inject` the honest (un-wrapped) types; discovery records the teardown actions; the generated bootstrap contains no teardown calls. Manual cleanup is the only way to teardown (M4 lands the orchestration). Diagnostic-gallery cases cover the misuse shapes above.

## Iteration 7 — multi-module composition

Cross-target binding aggregation, the activation model, transitive-activation diagnostics. Needs all of iterations 1–6 to be solid because it exercises them across module boundaries. The design depth lives in `Documentation/Notes/MultiModuleComposition.md` (the activation model, naming, and visibility, plus the deferred M6a/M6b optimizations) and `Documentation/Notes/ScopeAndKeyModelEvolution.md` (the `BindingKey`-tracking linchpin and Axis B).

**Two discovery-model foundations land first**, before any cross-module wiring. Both are additive and single-module-testable, and one (`BindingKey` tracking) is a behavioural change best landed before adopters exist:

- **7a — single-`BindingKey` tracking.** Wire tracks *multibinding* keys today (the element type lives on the key) but not single `BindingKey`s (the type lives producer-side, enforced by generated `_check`s). Add a key-declaration scanner for `static let X = BindingKey<T>("…")`, so every key becomes "a declared, type-carrying reference Wire tracks." Resolves the single/multi diagnostic inconsistency (concern 1 in the design note) and is the same key-discovery machinery the cross-module key references (7f) ride on. It is a **behavioural change** — Wire begins diagnosing single keys — so it lands here, before library behaviour expectations lock in, and it is the linchpin for Axis B (below), making that a cheap later addition. Single-module; no composition needed to build or test it.
- **7b — origin-module metadata per binding.** Thread an origin-module field through discovery onto every binding. A single module doesn't need it; composition does — it's load-bearing for both SE-0491 qualification and the context-dependent visibility threshold (7f). Additive and single-module-testable (the field is own-module until composition consumes it). Per the design note, the `::` emission is mechanical once this metadata exists.

**Composition mechanics:**

- **7c — cross-target source reading (same-package).** `_WireExports.swift` marker file as the discovery mechanism (M0 finding from Spike 1); the build plugin reads same-package Wire-aware dependency sources via the SPM plugin context (Spike 1's pattern), stamps them with their module, merges into one graph, and emits `import <module>` for each foreign origin. *(Done.)*
- **7d — activation model.** **Activation = depending on a Wire-aware library**, read from the consuming target's *direct* dependencies (`target.dependencies` in the plugin) — there is no call-site `.activating(...)` directive. Activation is a compile-time, per-target fact (one `_WireGraph` per target = one activation set), and the manifest dependency list is the one plugin-readable, SPM-name-checked signal for it. 7d extends 7c's same-package reading to external-package dependencies; the rule is uniform (same-package and external both activate by direct dependency), transitive deps are not auto-activated, and there is no inclusion/exclusion list in M1 (depend = activate, construct-all). A binding referenced from a library the target doesn't depend on can't be imported, so it's a compile error for free. See `MultiModuleComposition.md` ("Activation is the dependency") for the model and the rejected alternatives.
- **7e — cross-library validation + diagnostics.** Every `@Inject` satisfied somewhere in the activated set (union of the consumer's bindings + all directly-depended Wire-aware libraries) — this falls out of 7c/7d's merge, locked in by multi-module validation tests (resolution across modules, missing-binding across modules). The ambiguity diagnostic becomes origin-module-aware: when conflicting bindings span modules it names each one's module (two activated libraries binding the same type), with single-module output unchanged. The **missing-transitive-activation** diagnostic — "WireOpenAPI references `Router<...>` declared in WireHummingbird, which this target doesn't depend on; add WireHummingbird" — reads *beyond* the activated set (into non-activated transitive Wire-aware deps to find the declaring library), so it lands with 7g's two-package harness, where it can be exercised end-to-end.
- **7f — cross-module visibility + key references.** The declaration-too-private threshold becomes context-dependent: `internal` for in-module consumption, but a binding composed from another module needs `package` (same-package sibling) or `public` (external package). `crossModuleVisibilityDiagnostics` reads `originModule` plus an external-module set the plugin supplies (`.product` deps via `--external-module`, distinct from `.target` siblings) and gives origin-aware messages — "make it package or public" for an internal sibling binding, "make it public — package isn't visible across packages" for an external one (Option Y: Wire's message, not a compiler error on the generated file). Cross-module single/multibinding key references widen the parse set, not the rule — the missing-key check stays "no such key *in the parse set*" and loosens automatically (verified by a multi-module test). `withOrder:` keeps global-uniqueness in M1 (a cross-module duplicate rank still errors; unordered cross-module order is unspecified, so order-sensitive cross-module collections must use `withOrder:`); the coordination relief is deferred. **SE-0491 `::` naming is deferred out of 7f** — the clash it resolves surfaces as a duplicate identity today (7e names the modules; resolve with a key), and the robust fix needs an identity-model change + always-qualify codegen; the common non-clashing case already works via 7c's `import`. Tracked as a known limitation in `MultiModuleComposition.md`.
- **7g — two-package integration gate.** *(Done.)* A separate consumer + external library package pair under `CompositionHarness/`, run outside `swift test` (a macro-using fixture that swift-wire's own tests depended on would cycle). The consumer depends on the external library (activation = the dependency), applies the plugin, and its executable bootstraps the generated `_WireGraph` and asserts the library's unkeyed + keyed bindings composed across the package boundary — exercising external `.product` activation (7d), the foreign `import` (7c), cross-module key resolution (7a/7f), and the `--external-module` visibility-tracking wiring (7f) end-to-end. `run-harness.sh` drives it, and the `CompositionHarness` CI job runs that script on every push/PR so the gate can't bit-rot (it's outside `swift test`, so nothing else exercises it). The same-package `package`-access branch of the visibility threshold is covered in-`swift test` by `PackageVisibleService` (a `package @Singleton` in the sibling `WireTestLibrary`, composed into `IntegrationTests` — it only compiles because same-package `package` is reachable cross-module, where `public` is *not* required). The cross-module missing-binding **transitive-activation hint** (7e-deferred) moves to iteration 9 — it needs new plugin code (reading non-activated transitive Wire-aware deps as hint candidates) plus a three-package harness, and the base "no binding produces X" error already fires cross-module.

**Deferred within iteration 7 (or a clean slip to later): Axis B — value-level scope key.** Separating scope *identity* from scope *input* (`SeedKey(request: RequestSeed.self, userId: Request.userId)`), subsuming today's `@Scoped(seed: X.self)` as the single-input case. It builds *on* 7a's key tracking but is **not a prerequisite** for the composition mechanics, and it still has unresolved syntax (the design note's "open wrinkles": arbitrary argument labels need a positional/variadic/builder form; mixing a bare metatype with a key reference needs a common `ScopeInput` type). **The discipline that keeps it a clean later addition:** composition stays *agnostic to scope-input shape* — it treats each scope as an opaque `Partition(container, scope)` identity and delegates scope-bootstrap rendering to the existing iteration-4 scope codegen, never re-implementing or special-casing the single-seed `withScope(seeding:)` entry shape. Held to that, Axis B later just extends the scope codegen and composition inherits it for free; the only way it forces composition rework is if the single-seed entry shape is allowed to leak into composition-specific logic.

**Validation gate:** *(Met.)* `CompositionHarness/` — a consumer + external library package pair mirroring task-cluster's structure; the consumer activates the library by depending on it; bindings from both compose, including a cross-module key reference (verified end-to-end by `run-harness.sh`). The cross-module visibility threshold is covered by `CrossModuleVisibilityTests` (logic), the harness wiring (no false positive on a `public` external binding across a *package* boundary), and `PackageVisibleService` (the same-package `package`-is-sufficient branch, end-to-end in `swift test`). Cross-library validation is covered by `CrossLibraryValidationTests`, single-`BindingKey` diagnostics (7a) by their own single-module fixtures. Notes: under depend=activate, removing a *direct* external dependency is a Swift import error (the type vanishes), not a Wire missing-binding — the Wire cross-module missing-binding is the **transitive** case, whose fix-it hint is deferred to iteration 9. Eager construction of all activated bindings is accepted in M1 (reachability pruning is M6b); SE-0491 `::` clash resolution is deferred (see 7f).

## Iteration 8 — adapter-annotation contract

Risk #6's mitigation lives here. Builds the contract surface that M3, M4, and M5's adapters will be written against, with a minimal in-repo adapter fixture as a permanent regression test.

**Scope:**
- Manifest format spec (Wire-aware library declares its adapter annotations: name, form, phase, contract version)
- Library-side manifest registration mechanism
- Build plugin discovers adapter macros from dependency manifests
- `_wireRegister` parameter extraction (Spike 3's pattern)
- Validation of adapter-declared dependencies against the binding graph
- Generated bootstrap emits `_wireRegister` calls in phase order (post-graph for M1; per-request and per-job phases land later when an adapter actually needs them)
- A `@RoutedBy`-style adapter built in this iteration as a non-shipped in-repo fixture backing a permanent contract gate (the real, published adapters arrive in M3; the fixture stays as the gate's test subject, not discarded)

**Validation gate:** the fixture adapter's `_wireRegister` is detected, validated, and called in the bootstrap. Missing parameter binding produces an error pointing at the adapter annotation. Removing the adapter library from the target's dependencies deactivates the registration cleanly.

**Deferred (M1 is unkeyed):** keyed adapter dependencies — referencing a *keyed* binding from an adapter use-site via a `keyed(Type.self, with: Key)` slot, consumer-chosen and macro-agnostic. It's another member of the keyed-reference family, designed in [`ScopeAndKeyModelEvolution.md`](../Notes/ScopeAndKeyModelEvolution.md) ("Adapter dependencies"); the resolution seam (`BindingIdentity.key`, `nil` for bare slots) is in place so it's additive when a real case appears.

## Iteration 9 — task-cluster migration + opaque-type support

The substantive tail-end of M1. **Done.**

**Delivered:**
- **Opaque-type support** ([`OpaqueTypesSupport.md`](../../OpaqueTypesSupport.md)):
  opaque nominal identities (`@Singleton(as:)`), the constrained-parameter
  bridge, `_WireGraph` generic-parameter lifting, and the uniform
  `_Wire.bootstrap()` façade. Removes the generic-`@Singleton` CompositionRoot
  stopgap — a generic singleton becomes a graph node by *lifting* its parameter
  and resolving deps by identity, not by specialising against a concrete request
  — and lets `@RoutedBy` consume the abstract controller chain (validated by
  AdapterHarness). Iteration 10 landed *lift the minimum* — a `_WireGraph`
  parameter only for bridge targets, roots spelled as nested structural fields,
  and a generic `@Singleton` that's one instance or an error steering to
  `@Provides func` (validated end-to-end by the task-cluster migration and both
  lifting shapes in AdapterHarness), closing iteration 10. The parameterized-opaque
  `BuilderKey` moved to M2 / WireHummingbird (its only consumer,
  `router.addMiddleware`, wants the bootstrap-driven form, not an intermediate
  one); conformance-derived aliasing stays deferred/adjacent — both in that note.
- **task-cluster migration**: `TaskCluster.swift` / `Application+build.swift` are
  Wire-driven; `CompositionRoot` and the nested concrete spelling are gone, the
  concrete leaf named once; all task-cluster tests pass.

**Moved to pre-1.0 polish** (next section): the `_WireGraph.json` dump, the
dedicated diagnostic-quality sweep, and the missing-transitive-activation hint —
output/DX niceties, not correctness, and two are better done once the error and
model surface stabilise across M2–M6.

**Deferred (not surfaced):** adapter extensions — the producer-level `@Provides`
form and keyed adapter deps
([`AdapterModel.md`](../Notes/AdapterModel.md),
[`ScopeAndKeyModelEvolution.md`](../Notes/ScopeAndKeyModelEvolution.md))
were "if the migration surfaces the case," and it went the opaque route instead.

**Validation gate (met):** task-cluster builds with Wire and its existing tests
pass; CI is green on macOS and Linux; framework integration stays manual per the
README's M1 scope.

## Cross-cutting concerns

### task-cluster as the validation vehicle

Don't migrate task-cluster all at once at iteration 9. Migrate incrementally as Wire features become available:

- After iteration 2a: replace task-cluster's manual `Logger` and `InMemoryDynamoDBCompositePrimaryKeyTable` wiring with module-scope `@Provides`. The repository and controller stay manually constructed.
- After iteration 3: confirm the migration's diagnostics behave well (introduce a deliberate missing binding, fix it, see the diagnostic improvement work in real time).
- After iteration 5: if any task-cluster behaviour benefits from `@Contributes` (e.g., a list of middleware), migrate it.
- After iteration 7: if task-cluster's library targets exercise multi-module composition meaningfully, validate against them.
- After iteration 8: if iteration 8's adapter fixture approximates `@RoutedBy`, use it as a sketch of M3.
- Iteration 9: complete any residual migration; everything that was manually wired in `TaskCluster.swift` and `Application+build.swift` is now Wire-driven (except the framework-level `Application(...)` construction, which stays manual until M2's `WireHummingbird`).

### Diagnostic quality is iterative

Iteration 3 sets the diagnostic-quality standard. Every iteration after that re-validates new error paths produce good diagnostics. If iteration 8 introduces a confusing "missing binding from adapter" error that iteration 3's work didn't anticipate, fix it then, not later.

The diagnostic gallery from iteration 3 is the regression suite — extend it as iterations add new error paths.

### Test fixtures live alongside iterations

Each iteration grows the test suite; don't ship an iteration without its fixtures. The diagnostic gallery is the template: a directory of small fixtures, each demonstrating one specific behaviour, with assertions about the resulting diagnostics or runtime output.

### Macro surface stays small

Risk #1 ("swift-syntax tax") gets mitigated by keeping macros lean — most logic lives in the build plugin, which is more stable across Swift versions. When tempted to put logic in a macro, ask: "could this be done by the build plugin reading the macro's output instead?" If yes, do that.

## Design decisions settled during M1

Decisions the README described as a target shape that M1 resolved. The
forward-looking candidates (`Resolver`, `@Replaces`, `ContainerKey`, container
hierarchies, nested seeded scopes, `Provider<T>`) moved to
[ROADMAP.md](../../ROADMAP.md); what remains here is what M1 committed to —
opaque-type support (delivered in iterations 9–10), and two decisions that hold:
dynamic `Any.Type` lookup (rejected) and textual type-expression matching
(intentional).

### Opaque-type support (`some P` as an opaque nominal identity)

Wire's existing specialisation handles concrete-typed providers and `any P`-typed providers. The middle ground — `some P`, protocol-level abstraction at the source with compile-time identity and no boxing — has two forms: producer-side (`@Provides func makeDB() -> some DatabaseClient`) where the concrete type is hidden in the body, and consumer-side (a self-producing `@Singleton(as: P.self)` injected through `some P`). The model is opaque *nominal identity*: `some P` is another exact-match token, matched the way every identity is, plus a small closed set of qualifier promotions (`some P` satisfies `any P`, alongside `T` satisfies `T?`). It deliberately stops short of conformance-based resolution — no searching conformers — which keeps it from reimplementing the type system. Codegen lifts a generic parameter onto `_WireGraph` for every opaque binding exposed on the graph, and the bootstrap returns `_WireGraph<some P1, some P2, ...>`.

Design spec lives in [`OpaqueTypesSupport.md`](../../OpaqueTypesSupport.md). The doc covers the nominal-identity model and the rejection of conformance resolution, the closure invariant (opacity is viral; the chain is `some` end-to-end, bottoming out at a single `@Provides let x: some P = Concrete()`), the constrained-parameter bridge for generic consumers, producer-side disambiguation, the codegen requirements, and the `BuilderKey` coupling.

Decision point: iteration 7's incremental task-cluster adoption surfaced the forcing case — in the consumer-side `@Singleton(as:)` shape, not `@Provides -> some P`. `CompositionRoot` is forced to spell the full nested `TaskController<DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>>` because the self-producing repository and controller have only concrete identities. Support is scheduled around iteration 9's broader migration, now against a concrete case rather than a hypothetical one.

### Dynamic binding lookup by `Any.Type` (rejected)

Wire deliberately does not expose runtime binding lookup by `Any.Type` (or `String`, or any other type-erased key). Generated graphs surface typed accessors only; the binding set is not iterable, queryable, or addressable through an erased lookup at runtime.

Reasons:

1. **Wire's thesis is the static graph.** Resolution is decided at compile time; what's left at runtime is just stored properties (or whatever future backend emits in their place). Type-erased lookup reintroduces the late-binding hazards — missing deps surfacing at runtime, type mismatches, ambiguity — that compile-time validation is designed to eliminate.
2. **Backend forward-compatibility.** If Swift ever gains native effect handlers, "the graph" becomes more like an evaluation order managed by installed handlers (a Wire-to-handlers migration would mirror Scala's ZLayer-on-ZIO shape). A `lookup(by: Any.Type) -> Any?` surface would lock Wire to a value-typed-graph backend and close off that migration path.
3. **Read-only introspection is separable.** The runtime `introspect()` use case the README anticipates for M2 (ops/admin dashboards) needs a view of the graph's structure — binding list, dependency edges — not type-erased resolution. The two concerns can be served independently; offering introspection doesn't entail offering dynamic lookup.

If a concrete use case ever appears, the bar is high: it must demand resolution-by-type specifically and not be solvable by adding a typed accessor or surfacing read-only introspection. Until then this isn't deferred — it's intentionally excluded.

### Textual type-expression matching (intentional)

Sitting 2 canonicalises type expressions by stripping whitespace, then compares them by text. Sugar variants (`Array<X>` vs `[X]`, `Optional<X>` vs `X?`, `Dictionary<K, V>` vs `[K: V]`) and typealiases (`typealias TaskTable = ...; var x: TaskTable`) do *not* resolve to their underlying types — provider and consumer must use the same textual spelling.

**Architectural reason.** The build plugin runs as a SwiftPM `.buildCommand` plugin — a separate subprocess before `swiftc` compiles consumer source. It parses `.swift` files via SwiftSyntax and operates on syntactic information only. The type checker hasn't run yet; typealiases, sugar, and generic substitution aren't resolved at this layer. Dagger can match on underlying types because it's a JVM annotation processor running *after* `javac`'s type-resolution phase, where Kotlin's typealiases have already erased to their underlying types. Wire sits at a different point in the toolchain by design (no compiled-types dependency, no SourceKit-LSP coupling), and textual matching is what that layer affords.

**Side benefit: typealias-as-discriminator.** What looks like a limitation turns out to map well onto a Swift idiom: typealiases as phantom-typed discriminators. Two `String` bindings can coexist without keys if the user declares `typealias AppName = String` and `typealias AppVersion = String` and writes them consistently on both sides — Wire treats `AppName` and `AppVersion` as distinct types-as-far-as-Wire-is-concerned, even though they're both `String` underneath. Dagger users have to reach for `@Named("appName")`/`@Named("appVersion")` for the same effect. Wire's textual model accepts the user's source-level naming as the source of truth, which is consistent with the canonical-text rule we use for explicit `BindingKey` arguments — *what the user writes IS the identity*.

**Implications for the iteration 3 missing-binding diagnostic.** When a missing-binding error fires for a type name that doesn't appear in the binding set, the diagnostic should mention the textual-match rule neutrally rather than presuming user confusion. A reasonable note: "no binding produces 'TaskTable' — Wire matches by textual type expression; if `TaskTable` is meant to alias a bound type elsewhere, ensure both provider and consumer use the same name." Phrased so it acknowledges both the legitimate-typealias-as-discriminator case (no error, just a tip) and the genuine-mistake case (typo, accidental alias confusion).

**Things we could add later but currently won't.**

1. **Sugar canonicalisation** (`Array<X>` → `[X]`, `Optional<X>` → `X?`, `Dictionary<K, V>` → `[K: V]`). These genuinely refer to the same Swift type — there's no role-discriminator argument against canonicalising them. Defer until concrete demand: it's syntactic surgery on type expressions with the wrinkle of recursive application (`Array<[X]>` needs inner-bracket rewriting too), and mixing forms across providers/consumers is uncommon in real code.

2. **Typealias resolution.** Would require either a semantic-info source (SourceKit-LSP, swiftc dump-ast) or waiting for macro/build-plugin semantic APIs from the toolchain. Adding this *would break* the typealias-as-discriminator pattern, so the migration would need an opt-in flag rather than a hard switch. Not on any roadmap.

3. **Module-qualified spelling normalisation** (`Wire.BindingKey<T>` vs `BindingKey<T>`). Trivial syntactic transform if it ever bites. Probably never bites in practice — Swift's type inference and `import` resolution mean module qualifiers in property annotations are vanishingly rare.

The decision to revisit this section is when someone hits a confusing mismatch that's *not* a typealias-as-discriminator legitimate use. Until then, the textual-matching model holds and is documented as a design feature rather than a limitation.

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
- The diagnostic gallery passes on both platforms.
- CI runs on macOS Swift 6.3 and Linux Swift 6.3.1.
- No public 0.x tag yet — the README's "Status: pre-alpha" stays loud per Risk #2.

The `_WireGraph.json` build-time dump — previously listed here — is moved to
pre-1.0 polish (see *Pre-1.0 polish* in [ROADMAP.md](../../ROADMAP.md)); it's an
inspectable output, not a correctness criterion for M1.

The 0.x tag itself is a calendar gate, not an iteration: per the README, "used in one of my own services for at least a month before any 0.x release." So M1 ending and 0.1 shipping are different events; M1 ends when the iterations above are done, and 0.1 ships after a month of using it in task-cluster development without fundamental issues surfacing.

## What this plan deliberately doesn't include

- **No version-tagging plan.** v0.1 ships when M1 is done *and* used in task-cluster for at least a month per the README.
- **No "done is done" bar for diagnostics.** The standard is "you don't get confused by an error during normal task-cluster development." That's subjective; the diagnostic gallery is the floor and you stop polishing when the floor's high enough.
- **No fallback plan for M0 retrofits.** All four M0 spikes passed; no surprises lurking. If implementation work surfaces a problem the spikes missed, document and adjust — that's an unplanned slip, not part of the plan.
- **No design changes.** The README is the design spec. If implementation surfaces something the design got wrong, edit the README first, then update this plan, then continue. Don't drift the plan from the design silently.
