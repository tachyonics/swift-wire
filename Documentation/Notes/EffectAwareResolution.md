# Effect-aware resolution — design notes

> **Status:** working notes capturing the conceptual framing
> and implementation trajectory for Wire's handling of `async`
> and `throws` effects on bindings. Not the final form of any
> public-facing doc; intended to preserve the design space —
> particularly the unification of DI and data resolution that
> emerges once async throws providers are supported — before
> context drifts.

## The unified DI + data resolution model

Wire is positioned as a dependency injection framework. The
README, the iteration plans, and the architectural notes all
frame it that way. But once the framework admits `async throws`
on `@Provides` functions and `@Inject init`, the conceptual line
between "capability" and "data" collapses at the type level:

- **Capability**: long-lived, configured once, consumed many
  times. `DatabasePool`, `Logger`, `HTTPClient`.
- **Data**: derived from work, ephemeral, often per-request.
  `User`, `AuthSession`, `RequestContext`.

There's nothing structural separating these. A `@Singleton struct
DatabasePool` with async setup and a `@Scoped(seed: HBRequest.self)
struct CurrentUser` with async fetch use the same machinery:
async-init providers, scope-bound lifecycle, dependency graph
resolution, validation. Users will discover this pattern —
**they will use Wire to resolve per-request data**, not just to
inject capabilities. The contract shape invites it.

Wire's seeded-scope mechanism plus `async throws` providers
already provides what unified frameworks (Dagger Producers,
remix/next loaders, GraphQL DataLoader-style libraries) offer in
their domains. The unification isn't a future feature — it's a
present consequence of design decisions already made.

The deliberate move is to **acknowledge this explicitly** and
shape the trajectory rather than treat it as accidental. This
note captures that trajectory.

## Levels of construction strategy

The framework can implement effect-aware resolution at progressively
more sophisticated levels. Each level adds capabilities; none of
them invalidate the previous level's expressiveness — they're
optimisations that make the same code faster or more
informative.

### Level 1 — correct sequential emission

Topological order, one await at a time:

```swift
let config = Config()                                    // sync
let pool = try await makePool(config: config)            // async, depends on config
let cache = try await makeCache()                        // async, no inter-dep
let app = Application(pool: pool, cache: cache)
```

Each binding's effects (`async`, `throws`) are captured at
discovery time and the call site is prefixed with the right
combination of `try ` / `await ` / `try await `. The bootstrap
function is already `async throws` (the widest contract), so any
sub-call colour is permitted.

Correct, simple, no scheduling sophistication. `makePool`
finishes before `makeCache` starts even when they're
independent — a latency cost but not a correctness cost.

### Level 2 — parallel-where-independent via `async let`

Bindings without inter-dependencies launch concurrently:

```swift
let config = Config()
async let poolTask = makePool(config: config)
async let cacheTask = makeCache()
let pool = try await poolTask
let cache = try await cacheTask
let app = Application(pool: pool, cache: cache)
```

The build plugin computes "parallel groups" from the topological
order: every binding whose deps are all satisfied at the same
level can launch together. Sync bindings emit as bare calls;
async bindings in a parallel group emit as `async let` and are
awaited just before their first consumer.

### Level 3 — structured concurrency via `TaskGroup`

Explicit control over cancellation when one parallel task fails,
and ordered error handling:

```swift
let (pool, cache) = try await withThrowingTaskGroup(of: ...) { group in
    group.addTask { try await makePool(config: config) }
    group.addTask { try await makeCache() }
    // Cancellation policy + error aggregation handled here
}
```

More expressive than `async let`; more codegen complexity.

### Level 4 — selective caching / deduplication under parallel resolution

If two consumers want the same binding via different paths (some
via `Lazy<T>`, some directly), we deduplicate so the binding
constructs exactly once even under parallel resolution. We
already have this for sequential resolution (the topological
order ensures single construction); under parallel resolution
it needs careful synchronisation. `Lazy<T>`'s
`Mutex<Task<T, Error>?>` pattern is exactly the right primitive
to generalise from.

### Level 5 — cross-binding batching (DataLoader-style)

If `User(id: 1)` and `User(id: 2)` are both injected as
scope-bound bindings, batch their fetches into a single query.
This is what GraphQL's DataLoader does. Requires the framework
to understand which bindings are "data fetches with batchable
inputs" vs "capabilities", which means new annotations
(`@Batchable`, batching collectors) and a fairly different
mental model.

## Prior art mapped to levels

| Framework | Highest level | Notes |
|-----------|---------------|-------|
| Most JVM DI (Dagger core, Spring DI, Guice) | 1 | Sequential resolution; no parallelism notion |
| Dagger Producers | 3 | Explicit `ListenableFuture` graph within a `ProductionComponent`; closest direct analog |
| Spring reactive WebFlux | 2–3 | `Mono.zip()` for parallel composition; reactive operators handle ordering + errors |
| Remix / Next.js loaders | 2 | Parallel loaders per route; errors handled at route level |
| GraphQL DataLoader (Apollo etc.) | 5 | Batching + memoization; usually hand-written on top of DI, not unified |
| swift-dependencies, SafeDI, Factory (current Swift DI) | 0–1 | Mostly sync; async support via TaskLocal or factory closures, no scheduling |

The unified-framework camp (Dagger Producers, remix loaders) makes
parallel data resolution a first-class concern. The separated
camp (Spring's classic DI, Angular providers) keeps DI sync and
data fetching elsewhere. Wire — by virtue of Swift's
concurrency-first language design — naturally lands in the
unified camp once `async throws` providers are supported.

## Swift DI prior art specifically

Worth pinning separately because it's strikingly different from
the JVM/JS picture above: **no current Swift DI framework treats
async construction as a first-class concern, and none attempts
the unified DI + data resolution model**.

- **swift-dependencies (Point-Free)**: TaskLocal injection,
  no graph/topological resolution, dependencies-can-have-async-
  methods but the framework itself doesn't schedule async-init
  setup. Level 0 in our framing.
- **SafeDI (Cash App)**: compile-time-validated, macro-based —
  closest conceptual neighbour to Wire. Hierarchical scopes are
  supported. **Constructors are sync.** No async resolution path;
  users pre-construct async deps and feed them in via
  `@Forwarded`. Level 1 for sync, no async story.
- **Factory (Michael Long)**: registration-based container; has
  `LazyInjected` (similar to Wire's `Lazy<T>` concept) and
  `asyncFactory()` for explicitly-async factories — a recent
  addition. **No topological resolution**, no scheduling
  sophistication, no compile-time validation of the dep graph.
  Level 0–1 with async as an escape hatch rather than graph-
  integrated.
- **Older / mostly dormant** (Resolver, Cleanse, Needle,
  Swinject): all Level 0–1 for sync only; some have hierarchical
  scopes (Needle's scope tree, Cleanse's subgraphs) but no async
  resolution.

Concretely, the things we've discussed in this note that exist
elsewhere but **not yet in Swift DI**:

- Topologically-sorted, compile-time-validated dependency graph
  with async support.
- Effect-aware codegen that propagates `try await` correctly
  across binding call sites.
- Parallel-where-independent construction.
- DataLoader-style batching unified with DI.
- Request-scoped data resolution as a first-class graph node.

The closest direct analog isn't a Swift framework — it's
**Dagger Producers** on the JVM or **remix/next.js loaders** in
the JS world. Both arrived at the unified-resolution model
deliberately because their core DI/data-fetching split wasn't
serving them; Wire would arrive there from the opposite
direction, with the unified model emerging from Swift's
concurrency-first language design rather than being
retrofitted.

Implication for Wire's design: **the trajectory beyond Level 1
is unclaimed territory in Swift specifically**. There's no
precedent to lean on — semantic choices for parallel error
handling, cancellation policy, deduplication, batching are
ours to make, and the bar is "what fits Swift's concurrency
model" rather than "what matches existing Swift DI conventions"
(because there aren't any to match). The cost is no community
familiarity to draw on; the benefit is no legacy semantics to
honour.

This is also part of the broader "why Wire and why Swift"
positioning. Opaque-typed providers, result-builder-folded
multibindings, and effect-aware unified resolution are three
distinct features that share a structure: each exploits a Swift
language capability that other ecosystems can't natively
replicate, and each is currently absent from the Swift DI
landscape. Together they justify a framework that isn't trying
to be "Dagger ported to Swift" — it's trying to be what a DI
framework looks like when designed *for* Swift's type system
and concurrency model.

## Wire's trajectory

**Ship Level 1 now, defer Levels 2+ until concrete workloads
make the case.**

Rationale:

1. **Level 1 is correct.** Sequential async resolution gives
   users a working program; latency is the only cost. Any user
   pattern that runs under Level 2+ runs under Level 1, just
   slower.

2. **Levels 2+ are optimisations.** They speed things up; they
   don't change what's expressible. Postponing them doesn't deny
   any user pattern.

3. **Semantic design isn't free.** Parallel resolution's error
   aggregation, cancellation policy, and deduplication semantics
   need real workloads to validate. Designing speculatively risks
   committing to a model that doesn't fit when the workload
   arrives.

4. **The forcing function is observable.** When task-cluster's
   request handlers spend significant wall-clock time on
   sequential async deps that could parallelise, the case for
   Level 2 becomes concrete and the right design choices become
   obvious from real benchmarks.

5. **The building blocks are already in place.** Effect-spec
   capture during discovery (the Level 1 work) is the prerequisite
   for every higher level. Once it's in, advancing to Level 2 is
   a focused codegen change.

## What "Level 1" actually adds — iteration 4b-pre

The current implementation does **not** emit `try`/`await` at
binding construction sites. This is a latent gap from iteration
2's `@Provides func` work — captured neither in discovery nor in
emission. `Lazy<T>`'s design depends on the gap being fixed (the
deferred construction is async by contract).

The prerequisite work splits cleanly into one focused chunk:

**4b-pre — effect-aware emission for bindings.**

- Discovery extension: capture `effectSpecifiers` from
  `FunctionDeclSyntax` (`@Provides func`),
  `InitializerDeclSyntax` (`@Inject init`), and
  `AccessorDeclSyntax` (`@Provides` computed properties).
  Record `isAsync: Bool` and `isThrowing: Bool` on the matching
  `DiscoveredProvider` / `DiscoveredScopeBoundType`.
- Emission extension: `constructionExpression` prefixes the call
  with `try `, `await `, `try await `, or nothing based on the
  captured flags.
- Tests: each colour (sync, async, throws, async throws) for
  `@Provides func`, `@Provides` computed property, `@Inject
  init`; both unit tests on the rendering and integration tests
  exercising a real async binding through bootstrap.

After 4b-pre lands, the codebase is at Level 1: every effect
combination renders correctly and the construction order is
sequential. `Lazy<T>`'s 4b work can then build on top.

## Open design questions for Levels 2+

The questions to resolve when the forcing function arrives:

1. **Parallel-group identification.** Topological-order
   "parallel groups" — sets of bindings whose deps are all
   satisfied at the same level — can be computed at build time.
   But edge cases: bindings with the same dep set; bindings
   sharing a dep with sync + async mixed members. The exact
   rule for "what runs together" needs pinning.

2. **`async let` vs `TaskGroup`.** `async let` is simpler but
   has rigid two-or-three-binding ergonomics; `TaskGroup` scales
   to arbitrary parallel sizes. Likely: `async let` for small
   groups, `TaskGroup` above some threshold. Or always
   `TaskGroup` for uniformity.

3. **Error semantics under parallel resolution.** If two
   parallel tasks fail, which error wins? Swift's `async let`
   rethrows the first awaited; `TaskGroup` lets you choose.
   Dagger Producers aggregates errors. Wire's choice should
   match user mental model — likely "first awaited wins" with
   structured cancellation of siblings (Swift's default).

4. **Cancellation policy.** If one parallel binding fails, do
   its siblings cancel? Default Swift structured concurrency
   says yes; some users may want the siblings to complete (so
   their errors aren't lost). Probably stick with structured-
   concurrency default unless a real case pushes otherwise.

5. **Lazy<T> + parallel.** A `Lazy<T>`'s factory may be
   triggered concurrently by multiple consumers. The existing
   `Mutex<Task<T, Error>?>` pattern handles this — it
   generalises to Level 4 deduplication.

6. **User control.** Should users be able to opt out of
   parallelism for predictability (logging order, side-effect
   sequencing)? An annotation like
   `@Provides(execution: .sequential)` is conceivable but adds
   surface area. Probably defer unless real cases demand it.

7. **Batching annotations (Level 5).** What does a
   `@Batchable` `@Provides` look like? How does it interact
   with scope boundaries? Pure speculative design at this
   point; revisit if the case becomes concrete.

## Interactions with existing design

- **`Lazy<T>` (`LazyTypeSupport.md`)** depends on Level 1 effect-
  aware emission (the deferred construction is async). Builds
  on the same effect-spec infrastructure. At higher levels,
  Lazy<T>'s `Mutex<Task<T, Error>?>` becomes the pattern for
  deduplicated parallel construction.

- **Seeded scopes (`@Scoped(seed:)`)** provide the per-request
  lifecycle that data resolution needs. Async-init scoped
  bindings are the bridge between the DI graph and per-request
  data.

- **Hierarchical scopes (`@Scoped(within:)`, deferred)** are
  exactly the shape per-endpoint data composition wants:
  request scope → session scope → endpoint-specific data
  scope. Each level adds derived data; child levels inject
  parent data through normal scope rules. When hierarchical
  scopes land, the data-resolution use case becomes especially
  expressive.

- **OpaqueTypesSupport (`OpaqueTypesSupport.md`)** lets data-
  resolution graphs preserve concrete identity through
  abstractions — e.g., a `some Repository<User>` opaque return
  on a `@Provides` with a generic consumer.

- **`BuilderKey<B>` (`BuilderKeyDesign.md`)** composes
  multibinding contributors into a result, which composes
  naturally with async-data contributors at higher levels (a
  middleware chain assembled from async-fetched configurations,
  for instance).

The features all reinforce the unified-resolution direction
without requiring it to ship as a single deliverable.

## Why this positioning matters

The README currently positions Wire as a DI framework with
hex-architecture support and an adapter-annotation contract.
That's accurate as far as it goes. But the conceptual move
above — that effect-aware emission turns DI into
graph-resolution-where-construction-is-computation — is
genuinely different from "Dagger ported to Swift":

- **Most JVM DI frameworks separate DI from data fetching.**
  When they unify, it's via reactive extensions (Spring
  reactive) or separate modules (Dagger Producers). The core
  isn't unified.

- **Wire's core IS unified**, because Swift's concurrency model
  doesn't impose the sync/async separation. Once effect-aware
  emission lands, the same machinery serves both.

This is a positioning territory worth claiming:

> Wire is a graph-resolution framework where construction is
> computation. The same machinery resolves capabilities
> (long-lived, configured once) and data (derived, async,
> per-request), validated at compile time against the same
> type-safe binding graph. Effect-aware emission today supports
> sequential async resolution; the architecture is positioned
> for parallel and batching strategies as workloads demand them.

Whether to land this framing in the README now or wait until
Level 2 ships is a separate call. The conceptual territory is
real either way; documenting the trajectory in this note
preserves the option to claim it explicitly later.

## Decision triggers

- **task-cluster's request handlers show measurable latency
  improvement under Level 2.** Trigger: implement parallel
  resolution.
- **An adopter reports cancellation or error-aggregation pain
  with sequential async.** Trigger: design Level 3 semantics
  against their use case.
- **Multiple scope-bound bindings make redundant DB queries.**
  Trigger: explore Level 5 batching.
- **None of the above ever happens.** Outcome: Wire ships Level
  1, the unified-resolution direction stays a documented
  possibility, the framework remains a clean DI library that
  happens to handle async cleanly. Equally valid landing.
