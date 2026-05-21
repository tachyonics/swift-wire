# Support for Opaque Types — design note

> **Status:** design spec for deferred work. The pattern described here
> is not implemented in M1's current iteration plan. Implementation
> timing is tied to iteration 9 (task-cluster migration) — if migrating
> task-cluster surfaces real `@Provides -> some P` cases, the work
> lands there. Otherwise it slips post-M1 with no demand-pull.

## The pattern

A `@Provides` function whose return type uses Swift's opaque-type
syntax — `some P` — to hide a concrete type behind a protocol while
preserving the concrete identity at compile time:

```swift
@Provides
func makeDatabase() -> some DatabaseClient {
    PostgresClient(host: "...", port: 5432)
}

@Singleton
struct UserService<DB: DatabaseClient> {
    @Inject var db: DB
}
```

The mechanics:

- `makeDatabase()` returns a concrete type (`PostgresClient`) but
  exposes it through the protocol with a stable opaque-type identity.
- A generic consumer (`UserService<DB: DatabaseClient>`) is
  specialised by Wire using the opaque type as `DB`, producing
  `UserService<some DatabaseClient>` — a fully concrete instantiation
  in the graph.
- The consumer's source references the protocol only; the concrete
  type stays hidden from the consumer's code but specialised through
  the type system. No existential boxing.

This is a middle ground between two existing options:

- **`any P`** — type-erased existential. Standard hex/ports pattern,
  runtime virtual dispatch, consumer doesn't know the implementation.
- **Concrete type at both ends** — full specialisation, zero
  abstraction; the consumer references the concrete type directly.

`some P` keeps the abstraction at the source level (provider returns
through the protocol, generic consumers depend only on the protocol)
while preserving compile-time identity through the type system.

## How it fits Wire's binding model

Wire's binding identity is text-based: two `@Provides` with the
same canonical-text return type are duplicates (ambiguity error,
requires keying). For opaque returns this means:

- `@Provides -> some DatabaseClient` produces a binding with key text
  `some DatabaseClient`.
- Two such providers without disambiguating keys are a duplicate-
  binding error — same as any other duplicate. The keys-disambiguation
  pattern handles it.
- A binding `@Provides -> MySDK<some DatabaseClient>` produces a
  *different* key text (`MySDK<some DatabaseClient>`) and is a
  distinct binding from `some DatabaseClient`. The opaque types
  inside the two return positions are independent — Swift's
  semantics, not just Wire's matching.

Generic-specialisation already handles the lookup-through-constraint
case: a consumer `Foo<T: P>` with `@Inject var x: T` matches against
any binding whose bound type satisfies `T: P`, including `some P`
bindings. The existing specialisation machinery is sufficient for
the resolution side; the new work is in code emission.

## Codegen requirements

The complication is that Swift's `some P` opens a fresh opaque-type
abstraction at every declaration position. Two stored properties
declared as `some DatabaseClient` get *different* opaque types even
when initialised from the same expression. So Wire's generated
`_WireGraph` can't just spell `some P` at multiple property positions
that should refer to the same opaque-type identity. The shape that
works:

```swift
// Generated for a graph with @Provides -> some DatabaseClient
// plus UserService<DB: DatabaseClient> as a generic consumer:
struct _WireGraph<DB: DatabaseClient> {
    let db: DB
    let userService: UserService<DB>
}

func _wireBootstrap() throws -> _WireGraph<some DatabaseClient> {
    let db = makeDatabase()
    let userService = UserService(db: db)
    return _WireGraph(db: db, userService: userService)
    //                ^ Swift infers DB from the value's opaque type
}
```

Rules for the codegen pass:

1. **Every distinct opaque-typed binding lifts a generic parameter
   on `_WireGraph`.** With N opaque-typed bindings (after key
   disambiguation), the graph type is `_WireGraph<P1, P2, ..., PN>`.
   Each Pᵢ corresponds to one opaque-typed binding's concrete
   identity. The bootstrap returns
   `_WireGraph<some P1, some P2, ..., some PN>`.

2. **Lifting applies to nested positions, not only top-level.** A
   `@Provides -> MySDK<some P>` binding lifts the inner opaque type
   to a generic parameter even though `MySDK` wraps it. Two stored
   properties declared as `MySDK<some P>` would otherwise open two
   independent opaque-type abstractions; lifting forces a single
   identity through the generic parameter.

3. **Generic-specialised consumers reference the lifted parameter.**
   `UserService<DB>` in the example above uses the same `DB` symbol
   that's the lifted parameter on `_WireGraph`. Wire's codegen
   substitutes consistently across the graph.

4. **Per-container graphs apply the same rule.** Each
   `_<ContainerName>WireGraph` lifts its own opaque parameters. The
   container's opaque-type set is independent of the default graph's.

## Multiple opaque bindings via keying

Keys disambiguate duplicate-text bindings just like elsewhere in the
graph:

```swift
extension Database {
    static let primary = BindingKey<some DatabaseClient>("primary")
    static let replica = BindingKey<some DatabaseClient>("replica")
}

@Provides(Database.primary)
func primaryDB() -> some DatabaseClient { PostgresClient() }

@Provides(Database.replica)
func replicaDB() -> some DatabaseClient { PostgresClient(readonly: true) }
```

Both bindings have canonical text `some DatabaseClient` but distinct
keys, so they coexist in the graph. Each lifts its own generic
parameter on `_WireGraph`. The bootstrap return becomes
`_WireGraph<some DatabaseClient, some DatabaseClient>` — two
independent opaque type slots.

## Why iteration 9 timing

Iteration 9 (task-cluster migration) is the trigger because that's
where real `some P` cases either surface or stay hypothetical.
Task-cluster's pre-Wire code uses the pattern in `buildApplication`:

```swift
package func buildApplication<Repository: TaskRepository>(
    repository: Repository,
    configuration: ApplicationConfiguration,
    logger: Logger
) throws -> some ApplicationProtocol {
    let controller = TaskController(repository: repository)
    // ...
    return Application(...)
}
```

Wire's generated bootstrap is structurally equivalent — generic
function constructing concrete instances with opaque-return type
abstraction. The codegen described above generates exactly this
shape automatically.

If iteration 9 migrates task-cluster and the migration needs
`@Provides -> some P`, the work lands then with task-cluster as the
forcing function. If migration goes through without hitting it, the
spec stays documented here and implementation waits for an adopter's
case to surface.

## Open implementation questions for iteration 9

1. **Detection.** Which `@Provides` return types are opaque? Wire's
   build plugin recognises `some P` syntactically via SwiftSyntax.
   Confirm nested forms (`MySDK<some P>`, `(some P, some Q)`) are
   detected too — they need the same lifted-parameter treatment.

2. **Identity matching across the graph.** When a generic consumer
   has `T: P` and exactly one binding satisfies it via `some P`,
   specialisation picks the opaque type. When *multiple* opaque-type
   bindings could satisfy the constraint (different keys), Wire's
   existing ambiguity detection fires and the user resolves with
   explicit keys. No new mechanism — keys carry through the existing
   path.

3. **Visibility through nested types.** A binding bound as
   `MySDK<some DatabaseClient>` doesn't *expose* a `DatabaseClient`
   binding to the rest of the graph — the inner opaque type is
   encapsulated. Confirm Wire's graph-walking pass treats the
   wrapper's bound type (`MySDK<some DatabaseClient>`) as the only
   binding-key contribution, not the inner protocol.

4. **Generated code's interaction with consumers outside the graph.**
   `_wireBootstrap()` returns `_WireGraph<some P>`. A consumer that
   wants to thread the bootstrap's result through generic functions
   of its own works naturally (Swift's type-system propagation
   handles it). Consumers that want to *name* the concrete type
   inside the opaque slot can't (by design). Document this in the
   README so users understand the trade-off.

5. **Interaction with multi-module composition.** When an activated
   library publishes `@Provides -> some P`, the consuming target's
   build plugin must lift the same opaque type into the consumer's
   `_WireGraph`. Confirm the library's manifest format carries the
   opaque-typed binding's canonical text correctly.

## Why not in M1's current iteration plan

- **Concrete + `any P` covers the common case.** Iteration 4's
  validation gate, and the README's canonical examples, work without
  opaque returns. Users have two well-supported paths.
- **The codegen pipeline gains a new dimension.** Lifting generic
  parameters onto `_WireGraph` is mechanically straightforward but
  affects every layer of emission: type declarations, init
  signatures, container-graph variants, key-checks. Designing the
  emission against a real use case (iteration 9 or an adopter) avoids
  shipping speculative codegen.
- **Task-cluster's *current* Wire'd version (per the README) doesn't
  force this.** The README is somewhat sanitised; faithful migration
  may push toward opaque returns, but until iteration 9 runs the
  migration we don't know which specific cases.

The codegen shape is canonical Swift backend (per task-cluster's
buildApplication pattern). When iteration 9 demands it, implementing
against this spec is "wire up the codegen pipeline against the
already-designed shape," not "design from scratch."

## Decision trigger

Iteration 9 surfaces a real `@Provides -> some P` need that blocks
task-cluster migration → implement opaque-types support against this
spec in iteration 9.

Migration completes without hitting the case → spec stays documented;
implementation waits for an external adopter's case to surface.
