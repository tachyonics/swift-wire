# `Lazy<T>` — design notes

> **Status:** working notes captured during iteration 4b's design
> discussions. Not the final form of any public-facing doc; intended
> to preserve the design space before context drifts. The concrete
> iteration-4b plan in `M1_PLAN.md` references this for the depth
> that doesn't fit in the iteration sketch.

## Relationship to effect-aware resolution

`Lazy<T>` builds on the effect-aware emission infrastructure
described in `Documentation/Notes/EffectAwareResolution.md`.
That note captures (a) the conceptual unification of DI and
data resolution that emerges once `async throws` providers are
supported, and (b) the levels-of-construction-strategy
trajectory (sequential now; parallel and beyond when
workloads make the case). `Lazy<T>` is a Level 1 feature: it
provides intra-scope deferred-and-cached construction without
introducing parallelism. At higher levels, `Lazy<T>`'s
`Mutex<Task<T, Error>?>` pattern generalises into the
deduplication primitive parallel resolution needs.

The 4b-pre work (effect-spec capture in discovery + effect-
aware codegen) is a prerequisite for `Lazy<T>` because the
deferred construction is async by contract; without effect-
aware emission, the generated bootstrap can't correctly call
async-init T inside `Lazy`'s factory closure.

## Architectural principle: widest-contract = best port

The same producer/consumer asymmetry that drives the rest of
Wire's design applies to `Lazy<T>` — but the surface that needs
protecting is the *call shape* rather than the *type*. The consumer
references the Lazy port, not T's implementation, and the port's
contract is the widest plausible call shape: `async throws`.

T's init colour (sync, `async`, `throws`, `async throws`) is an
implementation detail that lives behind the port. A team can
change `init()` to `init() async throws` — add a DB connection,
make setup fallible, refactor between colours — and none of those
changes ripple into `Lazy<T>` consumer sites, because consumers
were already paying the `try await` cost. Producer-side
implementation evolves; consumer code is stable.

If we'd traced T's init colour through to multiple `Lazy<T>`
variants (`LazySync<T>`, `LazyThrows<T>`, `LazyAsync<T>`,
`LazyAsyncThrows<T>`), every consumer site would be load-bearing
on T's current init shape, and a colour change would be a
breaking refactor across the codebase. That's exactly the
"implementation-detail leak through the type system" hex
architecture is designed to prevent. `Lazy<T>`'s always-async
contract is the port; T's init is the adapter.

This is the same shape as Wire's other design choices applied
to call colour rather than type identity:

- Opaque returns from `@Provides`: consumer references the
  protocol (port); concrete type stays hidden.
- Producer-side binding declarations: consumer matches, doesn't
  drive.
- `BuilderKey<B>` result type from the key, not the consumer.

`Lazy<T>` adds: call shape from the wrapper, not from T.

## Runtime type

```swift
public struct Lazy<T: Sendable>: Sendable {
    public init(_ factory: @escaping @Sendable () async throws -> T)
    public func get() async throws -> T
}
```

The `.get()` naming is deliberate: it's the spelling JVM-audience
users already know (Dagger's `Provider<T>.get()`, Java's
`Optional.get()`, Kotlin's `Supplier.get()`) and matches Swift's
own `Result.get()`. `callAsFunction` (`pool()`) is terser but
lower-discoverability — `.get()` autocompletes naturally and reads
the same way in the JVM ecosystem and in Swift.

Implementation uses a "lazy task" pattern via a `~Copyable`-free
internal box class:

```swift
public struct Lazy<T: Sendable>: Sendable {
    private let box: LazyBox<T>

    public init(_ factory: @escaping @Sendable () async throws -> T) {
        self.box = LazyBox(factory: factory)
    }

    public func get() async throws -> T {
        try await box.value()
    }
}

private final class LazyBox<T: Sendable>: @unchecked Sendable {
    private let factory: @Sendable () async throws -> T
    private let mutex = Mutex<Task<T, Error>?>(nil)

    init(factory: @escaping @Sendable () async throws -> T) {
        self.factory = factory
    }

    func value() async throws -> T {
        let task = mutex.withLock { task in
            if let existing = task { return existing }
            let new = Task { try await factory() }
            task = new
            return new
        }
        return try await task.value
    }
}
```

First caller under the lock creates the `Task` and stores it;
subsequent callers see the same Task and await its value.
Concurrent first-callers race to the lock but only one Task gets
created and executed. Failure is cached: if the factory throws,
every subsequent `get()` rethrows the same error (the `Task`'s
value rethrows for every awaiter). This matches Kotlin's `lazy {}`
and Dagger's `Provider.get()` semantics.

`@unchecked Sendable` on `LazyBox` reflects that we're managing
the mutual exclusion ourselves through `Mutex`; the compiler
can't verify that automatically.

## Build plugin recognition

Discovery scans every `DependencyParameter` (from `@Inject` props,
`@Inject init` params, `@Provides func` params, `@Provides`
static-func params — all unified through the `DependencyParameter`
model) for the `Lazy<...>` wrapper shape via SwiftSyntax. When
detected, the inner `T` becomes the dependency for graph purposes:

- The graph edge runs from consumer → T (the unwrapped type).
- Cycle detection, missing-binding diagnostics, and cross-scope
  validation all apply against T, not against `Lazy<T>`.

So `Lazy<T>` is transparent to the dep graph's correctness checks
— it only affects codegen.

## Codegen shape

Two cases drive the emission, determined by T's consumer set:

### Case A: T has at least one direct consumer

T is constructed eagerly at bootstrap. The `Lazy<T>` wrapper is a
trivial closure that returns the already-constructed value:

```swift
let config = Config()
let databasePool = DatabasePool(config: config)         // eager
let lazyDatabasePool = Lazy { databasePool }            // trivial wrapper
let application = Application(pool: lazyDatabasePool)
```

This is the **"no-effect" case** — the `Lazy` wrapper is purely
ceremonial because T is constructed anyway. The build plugin emits
a warning at the `Lazy<T>` `@Inject` site (see
[The no-effect warning](#the-no-effect-warning) below).

### Case B: T has only `Lazy<T>` consumers

T's construction is genuinely deferred — the bootstrap emits the
`Lazy` wrapper with a factory closure that constructs T, with T's
deps captured by reference (or by value, depending on the
binding shape):

```swift
let config = Config()                                          // eager (Config has direct consumers)
let lazyDatabasePool = Lazy { DatabasePool(config: config) }   // defers DatabasePool
let application = Application(pool: lazyDatabasePool)
```

T's deps are still resolved by the normal topological order; the
deferred T just delays calling `T(deps...)` until `Lazy.get()`
fires. The factory closure captures the constructed deps.

## Consumer-count rule

The rule that determines case A vs case B is **local per-T**:

> T is eager iff any consumer references T directly (without a
> `Lazy<...>` wrapper). T is deferred iff every consumer references
> it through `Lazy<T>`.

"Consumer" includes any source of `DependencyParameter`:
- `@Inject` properties on `@Singleton` / `@Scoped` types.
- `@Inject init` parameters.
- `@Provides func` parameters.
- `@Provides` static-func parameters on `@Container` enums.

The graph-uniform treatment of `DependencyParameter` means the
rule applies symmetrically — Wire doesn't special-case consumer
kinds. A `@Provides func primaryDb(pool: DatabasePool)` counts as
a direct consumer for the same reason a `@Singleton struct Foo {
@Inject var pool: DatabasePool }` does.

### Why local, not transitive

The "transitive deferrability" variant — T is deferred iff *all*
of T's consumers are either (a) Lazy<T> consumers or (b) deferred
providers (whose outputs are only Lazy-consumed, recursively) — is
implementable but deliberately not pursued. Two costs:

1. **Reasoning load.** With the local rule, users can scan their
   graph and predict construction order. With transitive, a
   deeply-nested chain of providers determines whether anything is
   eager — surprising when a code change "downstream" silently
   makes upstream construction eager.

2. **Implementation.** Fixpoint analysis over the consumer graph,
   more edge cases.

The local rule's price is that users have to be explicit when they
want full deferral (wrap parameters explicitly through the chain).
That's arguably a feature: the graph encodes intent at each
point, not at the bottom of an analysis chain. If a real adopter
case wants transitive deferral, it can be revisited; defaulting
to local keeps the mental model predictable.

## The no-effect warning

When `Lazy<T>` is used but T also has a direct consumer
(`Lazy<T>` is no-op because T is constructed eagerly anyway), Wire
emits a build-time warning:

```
Source.swift:8:17: warning: 'Lazy<DatabasePool>' has no deferral effect here — 'DatabasePool' is constructed eagerly for another consumer
Source.swift:15:23: note: 'DatabasePool' is also injected directly here
Source.swift:8:17: note: inject 'DatabasePool' directly to avoid the wrapper, or remove the direct injection if deferral was intended
```

The note references the direct-consumer site so the user can see
who's forcing the eager construction. Two fix-its are surfaced —
remove the wrapper, or remove the direct injection — because
either resolution is valid and the user is in the best position
to know which.

Implementation: a post-discovery pass walks all consumers,
classifies each T as having `{direct, Lazy, mixed}` consumers, and
emits the warning at every `Lazy<T>` site whose T is in the mixed
category. The warning is informational, not error-level — the
code compiles and runs correctly.

## T's dependencies

Three sub-cases, all handled by the local rule + standard
topological ordering:

### Sub-case 1: T's deps are directly injected

T's deps are constructed eagerly at bootstrap (because the deps
themselves likely have direct consumers, or even if they don't,
they have to exist before T's factory closure can capture them).
T's factory closure captures the constructed deps:

```swift
let config = Config()
let lazyDatabasePool = Lazy { DatabasePool(config: config) }
```

### Sub-case 2: T's deps are also `Lazy`-wrapped

`Lazy` wrappers compose naturally via closures:

```swift
let lazyCache = Lazy { Cache() }
let lazyPool = Lazy { DatabasePool(cache: lazyCache) }
```

When `pool.get()` runs, DatabasePool constructs and receives the
`lazyCache` wrapper; DatabasePool's code calls `cache.get()` to
trigger Cache's construction. Deferral chains across multiple
levels.

### Sub-case 3: Cycles

`Lazy<T>` doesn't break cycles in 4b's design. The graph edge runs
from consumer → T regardless of whether the wrapper is used, so
the cycle detector still fires:

```swift
@Singleton struct A { @Inject var b: Lazy<B> }     // edge A → B
@Singleton struct B { @Inject var a: A }            // edge B → A
// → cycle reported
```

Cycle-breaking via Lazy would require treating `Lazy<T>` as a
deferred edge (or no edge) at cycle detection, which has subtle
correctness concerns — the cycle still exists at runtime, the
compiler just stops catching it. If a real adopter case wants
cycle-breaking, it's a separate feature with its own design.

## Scope rules

`Lazy<T>` is intra-scope only — the same scope rules that apply to
direct T injection apply to `Lazy<T>` injection. The wrapper
doesn't cross scope boundaries:

- A `@Singleton` consumer's `Lazy<T>` resolves T against the
  default graph (singletons + `@Provides`-bound types at module
  scope).
- A `@Scoped(seed: X.self)` consumer's `Lazy<T>` resolves T against
  the X-seeded scope graph (scope-bound types + the seed itself +
  borrowed singletons).
- A `@Scoped(seed: X)` consumer trying to use `Lazy<T>` where T is
  bound in a sibling seeded scope (or a container) gets the same
  cross-scope diagnostic from iteration 4c — the wrapper doesn't
  paper over the partition mismatch.

The cross-scope-storage validation pipeline (iteration 4c) treats
`Lazy<T>` deps identically to direct T deps for the purpose of
fitting binding/consumer scope rules. The wrapper is only a
codegen-level concern.

## User-provided `Lazy` producers

A user can write a `@Provides` that produces a `Lazy<T>` directly,
bypassing Wire's automatic recognition:

```swift
@Provides
func makeLazyDb(config: Config) -> Lazy<DatabasePool> {
    Lazy { DatabasePool(config: config) }
}
```

This is a legitimate escape hatch — sometimes the user wants
control over how the Lazy is constructed (e.g., a custom factory
with side effects). Wire treats the return type as a plain
`Lazy<DatabasePool>` binding; no automatic recognition machinery
runs for this case.

Implication for the no-effect warning: it shouldn't fire on
user-provided Lazy bindings, only on Wire-synthesised ones. The
distinction is straightforward — synthesised Lazy bindings are
created in response to a `Lazy<T>` `@Inject` dep, not declared
explicitly by a `@Provides`.

## Iteration 4b scope and forward-compat

Iteration 4b ships:

- The `Lazy<T>` + `LazyBox<T>` runtime types in Wire core, with
  `.get()` as the canonical API.
- Build plugin recognition of `Lazy<T>` in dep type lists.
- The consumer-count rule (per-T, local) driving eager vs deferred
  codegen.
- The no-effect warning for the mixed case.
- Cross-scope validation extended to recognise `Lazy<T>` deps as
  equivalent to direct T deps for scope rules.

Out of scope (deferred):

- Cycle-breaking via Lazy. The cycle detector still fires for
  `Lazy<T>` edges; opt-in cycle-breaking is a separate feature.
- Transitive deferrability analysis. Local rule only.
- Alternative API spellings (`callAsFunction`, `.value` property).
  `.get()` is canonical.

Forward-compat:

- The `Lazy<T>` type's API is fixed at `.get()` from day one.
  Adding `callAsFunction` later as a synonym is non-breaking.
- The no-effect warning's text and structure can evolve; it's a
  warning, not error, and not graph-shape load-bearing.

## Why this design is worth shipping

`Lazy<T>` answers a specific server-side pattern Wire needs to
support: heavy initialisation deps that aren't always reached
during a process's lifetime. A DB connection pool that takes 30
seconds to establish, an HTTP client with expensive TLS setup,
an LLM client with a model that needs warmup — eager construction
would force every process startup to pay these costs even when
only a fraction of the deps are exercised.

The pattern is well-trodden in JVM DI (Dagger's `Provider<T>`,
Spring's `ObjectFactory<T>`, Guice's `Provider<T>`), and the
`.get()` API choice is deliberately familiar to that audience.
Wire's contribution is doing this with full type-system support
and graph-level diagnostics:

- The no-effect warning closes a common adopter footgun (wrapping
  things in Lazy that don't actually defer).
- The widest-contract async API stays stable across implementation
  refactors.
- Intra-scope rules prevent the common JVM pitfall of using `Provider<T>`
  as an ambient cross-scope back-channel; Wire's scope rules
  apply uniformly to `Lazy<T>` and direct deps.

Together with `@Scoped(seed:)` (the seed-typed-scope work from
iteration 4a), `Lazy<T>` rounds out the deferred-evaluation
toolkit for server-side dependency graphs.

## Open implementation questions for iteration 4b

1. **Warning suppression escape hatch.** Some users may genuinely
   want `Lazy<T>` even when T is constructed eagerly — e.g., for
   uniform consumer-side ergonomics across cases where some
   consumers want eager and others want lazy. Should there be an
   opt-out for the no-effect warning at the consumer site
   (`@Inject(suppressWarning: true) var pool: Lazy<...>` or
   similar)? Or is the warning's existence enough — the user can
   ignore it without breaking the build?

   Decision likely: no escape hatch in 4b. Warnings are
   informational; ignoring them is the user's prerogative. Revisit
   if real adopter cases push for the hatch.

2. **Failure-caching semantics.** If T's factory throws, every
   subsequent `Lazy.get()` rethrows the same error. This matches
   Kotlin's `lazy {}` and Dagger's `Provider.get()`. Alternative
   semantics — retry on next call — has been proposed in other DI
   systems but is rare; mention this in the doc but ship with
   cache-the-failure behaviour.

3. **`LazyBox` lifetime.** The `Task` stored in `LazyBox.mutex`
   captures the factory closure, which may capture other Lazy or
   binding instances. Long-lived `LazyBox` instances retain those
   captures for the process lifetime. For singletons that's fine;
   for scoped Lazy<T> in seeded scopes, the LazyBox's lifetime is
   the scope's lifetime. Worth pinning that the LazyBox doesn't
   outlive its containing scope's instance.

4. **`@unchecked Sendable` audit.** `LazyBox` uses
   `@unchecked Sendable` because we manage Mutex correctness
   manually. Worth a careful review during implementation to
   confirm there are no concurrency holes — the standard "lazy
   task" pattern is well-known but each implementation deserves
   its own check.
