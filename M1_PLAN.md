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

**Scope:**
- `@Provides` macro on module-scope `let` and `func` declarations
- `@Provides` macro inside `@Container` enums
- `@Container` macro
- Build plugin aggregates `@Provides` declarations alongside `@Singleton` types

**Validation gate:** test app with `@Provides let logger = Logger(label: "test")` at module scope, consumed by a `@Singleton` via `@Inject`. Same with a `@Container` enum holding multiple `@Provides`.

## Iteration 3 — validation diagnostics

This is Risk #4 ("macro diagnostics") and Risk #5 ("resolution edge cases") meeting reality. Building it on top of the basic pipeline (rather than after every feature lands) means you can write diagnostic test cases against real graphs.

**Scope:**
- Missing-binding errors (compile error pointing at the `@Inject` site)
- Cycle detection (compile error naming each edge of the cycle)
- Ambiguity errors with explicit-key disambiguation (`@Inject(Foo.key)`)
- Generic specialization (when one binding satisfies a generic constraint, specialise; when multiple do, the explicit-key rule applies)
- Whitespace normalisation for type-expression matching (M0 finding from Spike 3 — `Router<X, Y>` and `Router<X,Y>` resolve to the same binding)

**Validation gate:** a "diagnostic gallery" test directory containing intentionally-broken graphs:
- Missing binding for a primitive type
- Missing binding for a generic instantiation
- Two-type cycle (A → B → A)
- Three-type cycle (A → B → C → A)
- Ambiguous binding requiring a key
- Deep generic instantiation across multiple `@Singleton`s

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

- After iteration 2: replace task-cluster's manual `Logger` and `InMemoryDynamoDBCompositePrimaryKeyTable` wiring with `@Provides`. The repository and controller stay manually constructed.
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
