# `Lazy<T>` — design notes

> **Status:** working notes for iteration 4b. `Lazy<T>` is shipped
> as a regular public Swift type; the build plugin treats it like
> any other type. Earlier drafts of this note proposed framework-
> level wrapper-marker recognition; that direction was rejected and
> the reasoning is preserved below under "Why not wrapper-marker
> recognition".

> **See also:** [`OptionalMatchingAndCycles.md`](OptionalMatchingAndCycles.md)
> places `Lazy<T>` in the cycle-breaking taxonomy — it is deferral
> only, *not* a cycle-breaker, alongside `weak var` (the breaker) and
> `weak let` (lifetime-only, also not a breaker).

## Framing: just a Swift type Wire happens to ship

`Lazy<T>` is a `public struct` in Wire core. The framework defines
it, ships it, documents it. Beyond that, the build plugin doesn't
know it's special — `Lazy<DatabasePool>` is a type expression the
graph treats the same as `Array<DatabasePool>` or
`Optional<DatabasePool>`. A binding of that type must exist, and
consumers requesting that type are matched against it through the
normal identity rule.

Practically, this means users opt into laziness by writing the
producer side explicitly:

```swift
@Provides
static func makePool(config: Config) -> Lazy<DatabasePool> {
    Lazy { DatabasePool(config: config) }
}

@Singleton
struct RequestHandler {
    @Inject var pool: Lazy<DatabasePool>
}
```

The `Lazy<DatabasePool>` binding is a normal singleton — Wire
constructs the wrapper at bootstrap (cheap: a closure + box).
`DatabasePool` itself only materialises when something calls
`pool.get()`, and is cached for the wrapper's lifetime.

Singleton-lifetime "first-use init" emerges naturally: the
`Lazy<DatabasePool>` binding lives for the singleton's lifetime
(process / container), the box caches the resolved value forever
after first call, so every consumer of the same `Lazy<DatabasePool>`
binding shares the underlying instance.

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

Implementation uses a "lazy task" pattern via an internal box
class:

```swift
public struct Lazy<T: Sendable>: Sendable {
    private let box: LazyBox<T>

    public init(_ factory: @escaping @Sendable () async throws -> T) {
        self.box = LazyBox(factory: factory)
    }

    public func get() async throws -> T {
        try await box.get()
    }
}

private final class LazyBox<Value: Sendable>: @unchecked Sendable {
    enum State {
        case unmarked(@Sendable () async throws -> Value)
        case pending(Task<Value, Error>)
        case resolved(Value)
    }

    private enum Outcome {
        case resolved(Value)
        case awaitTask(Task<Value, Error>)
    }

    private let mutex: Mutex<State>

    init(factory: @escaping @Sendable () async throws -> Value) {
        self.mutex = Mutex(.unmarked(factory))
    }

    func get() async throws -> Value {
        let outcome: Outcome = mutex.withLock { state in
            switch state {
            case .resolved(let value):
                return .resolved(value)
            case .pending(let existing):
                return .awaitTask(existing)
            case .unmarked(let factory):
                let new = Task<Value, Error> {
                    let value = try await factory()
                    self.mutex.withLock { storedState in
                        storedState = .resolved(value)
                    }
                    return value
                }
                state = .pending(new)
                return .awaitTask(new)
            }
        }
        switch outcome {
        case .resolved(let value): return value
        case .awaitTask(let task): return try await task.value
        }
    }
}
```

Tri-state lifecycle (`.unmarked(factory) → .pending(Task) → .resolved(Value)`)
mirrors `AtomicState<T>`'s vocabulary, adapted for Lazy's
create-or-await coordination. Each case owns the data its state
requires: unmarked holds the factory, pending holds the Task,
resolved holds the value. First caller under the lock creates
the Task and transitions to `.pending`; subsequent and concurrent
first-callers see the same Task and await its value. The Task
writes `.resolved(Value)` on success, after which gets read the
value directly through the lock — no Task hop on the hot path, and
the Task's closure capture is released as awaiters resume. Failure
is cached: if the factory throws, every subsequent `get()` rethrows
the same error (the `Task`'s value rethrows for every awaiter).
This matches Kotlin's `lazy {}` and Dagger's `Provider.get()`
semantics.

`@unchecked Sendable` on `LazyBox` reflects that we're managing
the mutual exclusion ourselves through `Mutex`; the compiler
can't verify that automatically.

## Idiomatic patterns

### Heavy initialisation deferred to first use

The original motivating case. A DB connection pool, an HTTP
client with TLS setup, an LLM client with model warmup — anything
that takes seconds at bootstrap and isn't always exercised in a
given process run.

```swift
@Provides
static func makePool(config: Config) -> Lazy<DatabasePool> {
    Lazy { DatabasePool(config: config) }
}
```

Bootstrap pays only the closure-allocation cost. First request
that touches the pool pays the connection-setup cost; everything
after gets the cached value.

### Singleton with first-use init

Same shape, different framing. The user wants a singleton-
lifetime instance (one across the process) that constructs on
demand rather than at bootstrap. The `Lazy<DatabasePool>` binding
*is* the singleton — the underlying `DatabasePool` materialises
inside the wrapper on first `.get()` and stays cached for the
wrapper's lifetime.

### Mixing eager and lazy consumers of the same underlying type

If some consumers want `DatabasePool` directly and others want
`Lazy<DatabasePool>` — and they should share the same underlying
instance — the user wires the relationship explicitly:

```swift
@Provides
static func makePool(config: Config) -> DatabasePool {
    DatabasePool(config: config)
}

@Provides
static func makeLazyPool(pool: DatabasePool) -> Lazy<DatabasePool> {
    Lazy { pool }
}
```

Both bindings exist; the `Lazy` wraps the already-constructed
`DatabasePool`. The eager-consumer path forces construction at
bootstrap (because `DatabasePool` has a direct consumer), and the
`Lazy<DatabasePool>` binding is the cheap trivial wrapper. The
user is in control of this trade-off, not the framework.

If the user instead wants *independent* lazy and direct instances,
they write two unrelated producers — the binding-identity rule
makes that the default.

### Atomic-unit deferral via seeded scopes

The case for "a deferred subsystem with internal mutual references" — a
heavy resource plus the types that compose around it, with cycle-break
needs inside — composes naturally from three primitives Wire already
provides (or will provide): seeded scopes (iteration 4a), `weak`
injection (planned iteration 4e), and `Lazy<T>` (this iteration).

The shape:

1. **Group the mutually-referencing bindings inside a seeded scope.**
   The scope struct becomes the atomic unit of construction. Mutual
   references between scoped types are kept inside the scope, where
   the scope struct holds both ends.

2. **Break cycles inside the scope with `weak`.** Scope-held types
   with mutual `weak` refs are leak-free at scope exit, because the
   weak side doesn't extend lifetime. Iteration 4e's macro recognition
   of `@Inject weak var` handles the construction-order side.

3. **Wrap the scope itself in `Lazy` for deferred materialisation.**
   The scope's generated `_<Seed>WireScope` struct is a normal Swift
   type; wrapping it in `Lazy` defers the entire subsystem's
   bootstrap until the first `.get()` call. The scope and everything
   in it stays cached after first materialisation, giving a "first-
   use init for the whole subsystem" lifecycle.

Worked example:

```swift
struct HeavyResourceSeed {}

@Scoped(seed: HeavyResourceSeed.self)
final class HeavyResource {
    @Inject var client: HeavyResourceClient
    // ... expensive init ...
}

@Scoped(seed: HeavyResourceSeed.self)
final class HeavyResourceClient {
    @Inject weak var owner: HeavyResource?
    @Inject init(owner: HeavyResource) { /* ... */ }
}

// At the bootstrap site (or wrapped inside another binding):
let lazyHeavyScope = Lazy {
    try await _HeavyResourceSeedWireScope.bootstrap(
        seed: HeavyResourceSeed(),
        _wireGraph: rootGraph
    )
}

// First request that needs the subsystem:
let scope = try await lazyHeavyScope.get()
scope.client.doWork()

// Subsequent calls return the cached scope; the heavy resource
// constructs once and lives for the process's remaining lifetime.
```

What you get from this composition:

- **First-use init at subsystem granularity.** One `.get()` triggers
  the entire scope's construction; cached thereafter. This is the
  "first-use singleton" pattern at a coarser, more useful granularity
  than per-binding deferral.
- **Cycle-breaking inside the unit.** `weak` keeps mutual references
  leak-free under the scope-struct lifecycle. The scope struct holds
  the strong side; weak refs zero correctly if the scope ever
  deallocates.
- **Right level of abstraction.** Deferral applies to the whole
  subsystem, not to individual bindings. Cycle-breaking applies to
  individual references inside, where it has correct lifetime
  semantics.

This composition pattern is materially better than any per-binding
"lazy as cycle-break" mechanism would be. It uses three existing
primitives at their respective sweet spots — scope for atomic
construction unit, weak for cycle-breaking with lifetime safety,
Lazy for deferred materialisation — without needing a new framework
affordance.

**Friction point worth flagging:** the bootstrap call to
`_<Seed>WireScope.bootstrap(seed:_wireGraph:)` needs access to the
parent `_WireGraph`. The user holds it at the bootstrap site where
they called `_wireBootstrap()`, so this works for `Lazy` wrappers
constructed in user code. Wrapping inside a `@Provides Lazy<Scope>`
binding would require the graph to be self-injectable (`@Inject var
graph: _WireGraph`) — a small future affordance that isn't on the
M1 critical path. The bootstrap-site composition shown above works
today without it.

## Why not wrapper-marker recognition

An earlier design pursued framework-level recognition of `Lazy<T>`
in dependency types: discovery would syntactically detect
`Lazy<T>` and unwrap it to `T` in the graph; codegen would
classify consumers per slot and emit eager-with-trivial-wrap or
defer-inside-Lazy emission based on whether the slot had direct
consumers, lazy-only consumers, or both. A "no-effect" warning
would fire for the mixed case. This was implemented through tasks
#80-#81 and then reverted.

The reasoning for backing out:

**Two paths to satisfy one consumer shape.** Under that model,
`@Inject var pool: Lazy<DatabasePool>` could be satisfied by
either an unwrapped `DatabasePool` binding (Wire synthesises the
wrapper) or by a user-written `@Provides Lazy<DatabasePool>`
(direct match). Two paths, one consumer-side shape. Reading the
code, you couldn't tell which was active without checking the
producer side AND the recognition rules.

**Producer-side semantics conflict.** Wire's broader design is
producer-side semantics — the producer dictates shape, the
consumer matches. Wrapper-marker recognition inverts that: the
consumer's `Lazy<T>` rewrites the graph behind the producer's
back. A producer of `DatabasePool` would have its consumer's
`Lazy<DatabasePool>` request silently shimmed by the framework,
even when the producer didn't opt into laziness.

**Language features over framework magic.** `Lazy<T>` under the
wrapper-marker model behaves like a normal Swift type at the call
site (you can read `.get()` on it) but is treated as a
disappearing marker by the build plugin (it's not really a
binding type, it's a wrapper-request annotation). That dual
identity is exactly the kind of framework-magic surface the
Wire-as-thin-DSL philosophy steers away from. The cleaner posture
is: `Lazy<T>` is a Swift type. If it appears in a dep position,
something has to bind it. No special unwrapping, no consumer
classification, no synthetic wrapper emission.

The cost of stepping back: one extra `@Provides` per Lazy use
case. The benefits: one resolution path per consumer shape, no
dual-identity behavior, no recognition machinery to maintain, no
no-effect warning to author, no cycle of "two paths" edge cases.

### Divergence from Swift-DI convention

This direction is a deliberate departure from the dominant
Swift-DI pattern for deferred resolution. Cleanse's `Provider<T>`
([github.com/square/Cleanse](https://github.com/square/Cleanse))
is the closest existing analogue and exposes exactly the
wrapper-marker model Wire rejected — a framework-defined wrapper
type with `.get() -> Element` that consumer sites use to defer
resolution, with the underlying binding registered for the
unwrapped `T`. That model is itself ported from JVM Dagger's
`javax.inject.Provider`, and the same shape appears in Guice and
similar frameworks.

Wire's just-a-type framing trades the ergonomic-but-magical
auto-wrap for explicit producer-side intent. The trade-off is
worth flagging because adopters coming from Cleanse, Dagger, or
JVM-DI in general will expect to write `@Inject Lazy<T>` and
have Wire synthesise the wrapper — they'll need to learn the
"write the `@Provides Lazy<T>` yourself" pattern instead. The
documentation and any adapter packages should call this out
prominently when explaining Lazy.

## Out of scope

- **Cycle-breaking via `Lazy<T>`.** Under the just-a-type model,
  `Lazy<T>` doesn't affect graph edges. Construction-time cycles
  through a `Lazy<T>`-typed dep still get detected by topological
  sort, because the binding's construction needs the cycle's other
  member at init time. Cycle-breaking that uses Swift's `weak`
  modifier and post-construction assignment is a separate planned
  iteration — see `Documentation/Notes/WeakInjectionSupport.md`.
- **Transitive deferrability analysis.** Not applicable; Wire no
  longer chooses when to defer. The user does, by writing a
  `@Provides Lazy<T>`.
- **No-effect warning.** Gone with wrapper-marker recognition.
  Mixed eager/lazy consumers are the user's intentional choice
  (see "Mixing eager and lazy consumers" above), not a Wire
  diagnostic concern.
- **Alternative API spellings** (`callAsFunction`, `.value`
  property). `.get()` is canonical.

## Forward-compat

- The `Lazy<T>` type's API is fixed at `.get()` from day one.
  Adding `callAsFunction` later as a synonym is non-breaking.

- **If Swift gains async-capable thread-safe `lazy`**, the
  natural ergonomic surface for *consumer-side* deferral becomes
  `@Inject lazy var x: T` (language keyword, no producer-side
  ambiguity — `lazy` isn't a type modifier, so the wrapper-
  marker footgun doesn't apply). The macro would recognise the
  keyword on `@Inject` properties — same structural pattern as
  the `weak` recognition for cycle-breaking — and emit codegen
  that stores `Lazy<T>` internally with synthesised accessors.
  Under that future, `Lazy<T>` recedes to implementation detail
  for the auto-wrap path; new code reads `@Inject lazy var x: T`
  and never types `Lazy<T>` directly.

  The explicit `@Provides Lazy<T>` pattern continues to serve a
  *different* role under that future — producer-side, graph-
  wide guarantee of deferred construction. The two are
  complementary, not redundant:

  - `@Inject lazy var x: T` — consumer-side convenience, weak
    guarantee. Useful for cycle-breaking and ergonomic per-
    property deferral. If T has any direct consumer in the
    graph, T constructs eagerly anyway and the lazy keyword
    is no-op at this site — a no-effect warning fires to tell
    the user their intent wasn't honoured.
  - `@Provides Lazy<T>` — producer-side intent, strong
    guarantee. Useful for "this resource's construction
    lifecycle must be deferred regardless of who consumes
    it" — the heavy-init singleton, the first-use-init
    singleton shared across requests. Auto-wrap can't
    substitute for this because any direct consumer would
    still force eager construction.

  The no-effect warning re-emerges for the consumer-side
  pattern, but it's defensible there: it's the contract
  telling the user their language-keyword intent didn't take
  effect because another consumer forced eagerness. Anchored
  on a Swift language modifier, not on a framework wrapper
  type, so the "two paths to satisfy one consumer shape"
  problem the wrapper-marker design suffered from doesn't
  reappear.

- A future iteration could also introduce cross-partition
  transitive deferral *if* a real adopter case demands it —
  i.e., "this singleton is only consumed by request-scope
  Lazy-wrapped consumers, defer it in the parent scope too."
  That's a graph optimisation on top of explicit user intent,
  not a change to the user-facing API. The just-a-type model
  leaves room for that without prejudicing it.

- **Cycle-breaking is `weak`'s job, not `lazy`'s.** Lazy edges
  (whether via the current `@Provides Lazy<T>` pattern or a
  hypothetical future `@Inject lazy var`) still participate in
  cycle detection — they're not a cycle-break primitive.

  The combination "deferred construction + non-retaining
  reference" on the *same* binding doesn't usefully exist:
  deferring construction of something you'll then only hold
  weakly means materialising it and then immediately allowing
  it to deallocate — the lazy cache defeats itself because
  the weak slot can zero between construction and any reader.
  The only scenarios where the combination is meaningful at
  all involve construction side-effects unrelated to the
  returned value (registering with a service locator on
  init, opening a background connection that runs
  independently). Those edge cases aren't primary design
  drivers and don't justify a per-binding `lazy weak`
  affordance even hypothetically.

  The legitimate composite use case — "deferred construction
  of a subsystem that has internal mutual references" —
  composes cleanly from three existing primitives at *different
  granularities*: seeded scope as the atomic unit (subsystem-
  level), `weak` inside the scope for cycle-breaking with
  leak-safe lifetime semantics (per-reference), `Lazy` around
  the scope struct for deferred materialisation (subsystem-
  level). The deferral and the cycle-break apply to different
  things, which is what makes the composition coherent. See
  "Atomic-unit deferral via seeded scopes" under Idiomatic
  patterns for the worked example. This collapses the design
  space — no framework affordance for "lazy as cycle-break"
  is needed.

## Open implementation questions

1. **Failure-caching semantics.** If T's factory throws, every
   subsequent `Lazy.get()` rethrows the same error. This matches
   Kotlin's `lazy {}` and Dagger's `Provider.get()`. Alternative
   semantics — retry on next call — has been proposed in other DI
   systems but is rare; ship with cache-the-failure behaviour
   and revisit if a real case demands retry.

2. **`LazyBox` lifetime.** The `Task` stored in `LazyBox.mutex`
   captures the factory closure, which may capture other Lazy or
   binding instances. Long-lived `LazyBox` instances retain those
   captures for the process lifetime. For singletons that's fine;
   for scoped Lazy<T> in seeded scopes, the LazyBox's lifetime is
   the scope's lifetime. Worth pinning that the LazyBox doesn't
   outlive its containing scope's instance.

3. **`@unchecked Sendable` audit.** `LazyBox` uses
   `@unchecked Sendable` because we manage Mutex correctness
   manually. Worth a careful review during implementation to
   confirm there are no concurrency holes — the standard "lazy
   task" pattern is well-known but each implementation deserves
   its own check.
