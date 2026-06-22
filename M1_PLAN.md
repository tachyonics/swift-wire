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
  - **Owned-type member form** — `@Teardown` (no argument) marking the teardown method on a `@Singleton`/`@Scoped` type. The method may be any name and `private`; effect specifiers (`async`/`throws`) are read off its declaration. Mechanically the marker-on-method pattern spike-2 already proved.
  - **Producer form** — `@Teardown(<action>)` on a `@Provides func`/`@Provides var`, where `<action>` is an explicit-typed closure (`@Teardown({ (c: HTTPClient) in try await c.shutdown() })`) or a free/static function reference (`@Teardown(shutdownClient)`). The produced type stays honest (no wrapper, no unwrap); consumers inject it directly. Spike-5 confirmed: attributes take no trailing-closure sugar (parenthesise the closure), `$0`-inference doesn't reach across the attribute (explicit parameter type required), and sync actions coerce into the `async throws` contract.
- Discovery records a `TeardownAction` on `DiscoveredScopeBoundType` (member form) and `DiscoveredProvider` (producer form). The build plugin extracts the action by source-parsing (spike-3's mechanism), not from an expanded peer.
- Misuse diagnostics (iteration-appropriate; diagnostics are iterative): bare member-form `@Teardown` with no enclosing scope-bound binding; producer-form `@Teardown` on a non-`@Provides`; a member-form teardown method that is `static` or takes parameters; more than one `@Teardown` per binding.
- No runtime types ship — only the annotation. Code emission is unchanged (no teardown calls).

**Validation gate:** test app with a `@Singleton` carrying an `@Teardown` method *and* a `@Provides` returning a third-party-style type with an `@Teardown` closure; bootstrap constructs both; consumers `@Inject` the honest (un-wrapped) types; discovery records the teardown actions; the generated bootstrap contains no teardown calls. Manual cleanup is the only way to teardown (M4 lands the orchestration). Diagnostic-gallery cases cover the misuse shapes above.

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

### Opaque-type returns from `@Provides` (`@Provides -> some P`)

Wire's existing specialisation handles concrete-typed providers and `any P`-typed providers. The middle ground — `@Provides func makeDB() -> some DatabaseClient { ... }` with a generic consumer `Foo<DB: DatabaseClient>` — preserves the protocol-level abstraction at the source while keeping compile-time identity through generic specialisation. The pattern is useful but requires non-trivial codegen: every opaque-typed binding lifts a generic parameter onto the generated `_WireGraph`, and the bootstrap returns `_WireGraph<some P1, some P2, ...>` with opaque arguments.

Design spec lives in [`OpaqueTypesSupport.md`](OpaqueTypesSupport.md). The doc covers the binding-identity model, the codegen requirements (lifted generic parameters, opaque return from bootstrap), keying for multiple opaque-typed bindings of the same protocol, and the open implementation questions.

Decision point: iteration 9's task-cluster migration is the forcing function. If migration surfaces a real `@Provides -> some P` case, support lands in iteration 9 against the spec in `OpaqueTypesSupport.md`. If migration completes without hitting it, the spec stays documented and implementation waits for an external adopter's case to surface.

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
