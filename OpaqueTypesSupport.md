# Support for Opaque Types — design note

> **Status:** implemented in iteration 9 — `@Singleton(as: P.self)` opaque
> identities, the constrained-parameter bridge, and `_WireGraph` lifting ship,
> and task-cluster's chain is migrated (its `CompositionRoot` collapsed).
> Consumers inject **constrained generic parameters**, not `some P` at the
> injection site (see *The closure invariant*); the literal `some P` init/var
> form does not compile. The model deliberately stops short of conformance-based
> resolution (see *Identity model*); it is opaque *nominal identity* plus a
> small, closed set of promotion rules. Deferred within it: the `some P`
> satisfies `any P` promotion, nested-position lifting, and multi-identity
> aliasing (each marked below).

## The pattern

Opaque-type syntax — `some P` — hides a concrete type behind a protocol
while preserving its concrete identity at compile time, with no
existential boxing. Two positions use it:

**Producer-side**, where the concrete type is hidden in the body:

```swift
@Provides
func makeDatabase() -> some DatabaseClient {
    PostgresClient(host: "...", port: 5432)
}
```

**Consumer-side**, where a binding is injected through the protocol it
conforms to rather than its concrete type:

```swift
@Singleton(as: TaskRepository.self)        // declares graph identity `some TaskRepository`
struct DynamoDBTaskRepository<Table: …>: TaskRepository { … }

@Singleton struct CompositionRoot {
    @Inject var repository: some TaskRepository   // not DynamoDBTaskRepository<…>
}
```

The consumer-side case is what iteration 7's task-cluster adoption
surfaced, and it is *not* the `@Provides -> some P` shape this note was
originally written around. It is treated below as a first-class form, not
a footnote.

`some P` is the middle ground between two existing options:

- **`any P`** — type-erased existential; runtime virtual dispatch.
- **Concrete type at both ends** — full specialisation, zero abstraction;
  the consumer names the concrete type directly.

`some P` keeps the abstraction at the source level while preserving
compile-time identity through the type system.

## Identity model: `some P` is an opaque *nominal* identity

This is the load-bearing decision. `some P` is **another exact-match
identity token**, alongside `DynamoDBTaskRepository<…>`, `any P`, and the
rest. Wire matches it the way it matches everything — by canonical text.
`some TaskRepository` matches an injection point that spells
`some TaskRepository`, and nothing else.

Wire does **not** do conformance-based resolution. There is no "find the
binding whose concrete type conforms to `P`." That would require
reimplementing a meaningful slice of the type system (conformance
checking, including inherited/conditional/retroactive conformances Wire
can't see syntactically) and would make ambiguity the *default* — every
type conforming to `P` would contend for one slot. Keeping `some P` a
nominal token avoids all of that: there is exactly one binding per
`some P` identity (subject to the duplicate/collision rules below), so
resolution stays exact and unambiguous.

The consequence for self-production: **a `@Singleton` has one graph
identity by default** — its concrete type. `@Singleton(as: P.self)` lets a
self-producer instead declare that identity as `some P`, the library
inferring the `@Provides -> some P` wrapper the user would otherwise
hand-write, with no second instance. A binding may also declare
*additional* explicit identities so it is reachable under more than one
token (see *Multiple explicit identities*). What Wire never does is
*derive* an identity from conformance — the set is always exactly what the
author declared.

## The closure invariant: opacity is viral, and the chain is `some` end-to-end

Because matching is nominal and there is no conformance resolution, an
abstract consumer can only be fed by a producer that declares the *same*
abstract identity. You cannot splice a concrete-identity producer into a
`some P` slot — that hop is exactly the conformance lookup we rejected.

So opacity is **contagious upward**: the controller, the repository, *and*
the leaf all declare opaque identities, and the chain stays abstract from
top to bottom, bottoming out at a single concrete initialiser. Each hop
injects its collaborator as a **constrained generic parameter**, which Wire
bridges to the matching `some P` binding (see *Resolving consumers* rule 2
and *Self-production: lift, don't specialise*):

```swift
@Provides let table: some DynamoDBCompositePrimaryKeyTable & Sendable
    = InMemoryDynamoDBCompositePrimaryKeyTable()

@Singleton(as: TaskRepository.self)
struct DynamoDBTaskRepository<Table: DynamoDBCompositePrimaryKeyTable & Sendable>: TaskRepository {
    @Inject init(table: Table) { … }
}

@Singleton(as: APIProtocol.self)
struct TaskController<Repository: TaskRepository>: APIProtocol {
    @Inject init(repository: Repository) { … }
}

// No composition root: the controller is already a graph node under its
// `some APIProtocol` identity — read it straight off the bootstrapped graph.
let controller = graph.someAPIProtocol
```

**Injection uses a constrained generic parameter, not `some P` at the
injection site.** `@Inject init(table: some P)` does *not* compile: `some P`
in a parameter opens a fresh implicit generic (SE-0341) decoupled from the
type's own `<Table>`, so it can't be stored into the `Table` field; and a
stored `var x: some P` has no initialiser expression from which to infer its
underlying type. The shape that compiles keeps the type generic
(`<Table: P>`) and injects the bare parameter; Wire passes a `some P` value
and the compiler infers the argument. This is the constrained-parameter
bridge — Swift's opaque-type semantics, not a Wire quirk. The leaf's
constraint must match the parameter's *exactly*, `& Sendable` included, since
matching is textual (`some DynamoDBCompositePrimaryKeyTable & Sendable` here).

The concrete type `InMemoryDynamoDBCompositePrimaryKeyTable` appears
**exactly once**, as the leaf initialiser — the genuine composition-root
choice, not a wart. The nested spelling
`TaskController<DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>>`
that the pre-lift `CompositionRoot` was forced into collapses entirely.

**The leaf must be `some`, not the bare protocol (`any`).** Writing
`@Provides let table: DynamoDBCompositePrimaryKeyTable = …` makes it an
existential, which fails twice: it reintroduces boxing at the bottom of an
otherwise zero-cost chain, and `any P` generally can't satisfy a generic
constraint `Table: P` (protocols with `Self`/associated-type/static
requirements don't self-conform), so it can't be the generic argument at
all. `some` conforms normally. This isn't a Wire rule — it falls straight
out of Swift's own opaque/existential semantics; users obey it whenever
they hand-write this code.

## Multiple explicit identities

A binding may declare more than one identity and satisfy consumers of
each — for example the in-memory table as both
`InMemoryDynamoDBCompositePrimaryKeyTable` and
`some DynamoDBCompositePrimaryKeyTable`, from one instance. This is
*explicit aliasing*, not conformance: the author lists the identities and
Wire matches each by exact token; nothing is derived.

It is the sanctioned way to **bridge the concrete and opaque sub-graphs**.
The closure invariant makes opacity viral — a `some P` consumer needs a
`some P` producer all the way down. A multi-identity binding is the one
place that virality is deliberately broken: a single node living in both
worlds, so most of the graph can stay concrete while one seam is exposed
opaquely (or vice versa).

It supersedes the wrapper workaround (`@Singleton` for the concrete
identity plus a thin `@Provides -> some P` that injects and returns it),
and beats it on two counts:

- **One instance, declared once** — no second binding to keep in sync.
- **Cheaper codegen.** The wrapper's `@Provides -> some P` *hides* the
  type, forcing the `_WireGraph<DB>` lifting. A native alias keeps the
  type known (it came from the `@Singleton` / `@Provides let`), so the
  `some P` consumers are served by the bridge/promotion rules with no
  lifting.

Bounds that keep it safe:

- **No new ambiguity class.** Each declared identity goes through the
  existing duplicate/collision detection independently — two bindings
  claiming `some P` is the ordinary duplicate error, whatever else either
  one declares.
- **Known-type bindings only.** A genuinely-hidden `@Provides -> some P`
  cannot also claim a concrete identity (Wire doesn't know the concrete
  type). Aliasing applies where the type is known — self-producers and
  `@Provides let x: some P = Concrete()` — which is also the no-lifting
  case.

**Status: deferred, not yet needed.** Task-cluster's opaque chain consumes
each binding under a single identity, so there is no live forcing case.
The model leaves room for aliases (single identity is a *default*, not a
cap), but the machinery waits for a real binding consumed under two
identities, where the wrapper boilerplate starts to grate.

## Resolving consumers

Three rules, in precedence order. None require conformance search.

1. **Exact token.** `some P` is one graph slot: two producers declaring the
   same `some P` identity collide as a duplicate, and a dependency already
   carrying the `some P` token resolves to it directly. But a consumer can't
   *write* `some P` at an injection site (SE-0341, above), so in practice
   consumers reach a `some P` binding through rule 2, not this one.

2. **Constrained-parameter bridge.** A generic dependency whose type is a
   bare type parameter constrained to `P` — `repository: Repository`
   where `Repository: TaskRepository`, with no concrete instantiation
   requested — resolves to the unique `some P` binding. This is the one
   conformance-*aware* step, and it stays bounded: it reads the
   parameter's declared constraint and maps it to the `some P` token; it
   does not search conformers. The single-identity rule guarantees at most
   one `some P` binding, so there is no ambiguity to resolve. The closure
   invariant guarantees the binding exists (every hop up the chain offers
   one). Codegen then emits the construction with the opaque value and the
   Swift compiler specialises the generic — Wire never names the hidden
   type.

3. **Qualifier promotion: `some P` satisfies `any P`.** A `some P` binding
   may feed an `any P` consumer (the concrete-underlying value boxes into
   the existential). One-directional: `any P` can never feed `some P` (an
   existential has erased the single underlying type `some P` requires).
   The boxing cost lands at the `any P` consumption site — the consumer
   that chose the existential pays for it; the binding stays zero-cost for
   its `some P` consumers.

   This is the second member of a **closed set** of qualifier promotions,
   alongside `T` satisfies `T?` (see
   [`OptionalMatchingAndCycles.md`](Documentation/Notes/OptionalMatchingAndCycles.md)).
   The set is deliberately closed — there is no `X` satisfies `any P`
   (that is the conformance lookup we rejected; it is safe for `some P`
   precisely because `some P` already names `P` in its identity, whereas a
   concrete `X` would have to be *discovered* to conform), and no
   `any P` satisfies `some P`. Promotion is only ever between qualifier
   variants of the *same named protocol*.

## Disambiguation is producer-side

Consistent with the optional rule (which this note's promotion set mirrors),
conflicts are caught at declaration, not at a consumer:

- **Two bindings with the *same* `some P` identity** (e.g. two unkeyed
  `@Provides -> some DatabaseClient`) are a duplicate-binding error, the
  same as any duplicate. Disambiguate with keys.
- **A `some P` binding and an `any P` binding** are distinct identities but
  lower to the same generated name, so declaring both at one key is an
  identifier collision — exactly as `T` and `T?` collide. Keys give them
  distinct names and let them coexist.

Both fire when the producers are declared, independent of any consumer, so
adding a consumer later can never turn a valid graph ambiguous.

## Codegen: lifting opaque bindings onto `_WireGraph`

Whenever an opaque binding is *exposed as a graph property* (read off the
bootstrapped graph, or stored across the `_WireGraph` boundary rather than
consumed only within `_wireBootstrap`), the concrete identity has to be
carried as a generic parameter. Swift opens a fresh opaque type at every
`some P` declaration position, so a stored property typed `some P` would
not refer to the same type the bootstrap produced. The shape that works:

```swift
// @Provides -> some DatabaseClient, plus a generic consumer:
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

1. **Every distinct opaque-typed binding exposed on the graph lifts a
   generic parameter on `_WireGraph`.** With N such bindings (after key
   disambiguation) the graph type is `_WireGraph<P1, …, PN>` and the
   bootstrap returns `_WireGraph<some P1, …, some PN>`.

2. **Lifting applies to nested positions, not only top-level.** A
   `@Provides -> MySDK<some P>` binding lifts the inner opaque type so two
   `MySDK<some P>` properties don't open two independent abstractions.

3. **Generic-specialised consumers reference the lifted parameter.**
   `UserService<DB>` uses the same `DB` symbol lifted onto `_WireGraph`;
   codegen substitutes consistently across the graph.

4. **Per-container graphs apply the same rule.** Each
   `_<ContainerName>WireGraph` lifts its own opaque set.

A `@Singleton(as: P)` self-producer whose concrete type Wire already knows
(it is declared) does not strictly need lifting for *construction* — the
bootstrap can build it concretely — but it does need it for any *exposure*
as a `some P` graph property, so the same machinery applies uniformly.

Opaque bindings are skipped from `_WireKeyChecks` type assertions: the
build plugin can't unify the hidden concrete type, so it emits no
compile-time check for them (the existing `!type.hasPrefix("some ")` guard
in code emission already does this).

## Self-production: lift, don't specialise

The lifting above isn't special to `@Provides -> some P` — it's the general
rule for any **generic `@Singleton`**. A `@Singleton` is a graph node whether
generic or not; the generic case just lifts its parameter onto `_WireGraph`.

The distinction that matters:

- **`@Singleton` (self-production) is *not* specialised.** Wire never computes
  or spells `TaskController<DynamoDBTaskRepository<InMemoryTable>>`. It resolves
  each `@Inject` dependency to a binding **by identity** (an abstract dep like
  `repository: Repository: TaskRepository` matches the `some TaskRepository`
  binding, via the constrained-parameter → `some P` bridge), emits
  `TaskController(repository: r)`, and lets the **compiler infer** the type
  arg — which Wire lifts onto `_WireGraph<…>`. Resolution by identity +
  compiler inference + lifting, never Wire-computed specialisation.
- **`@Provides func` is the only thing Wire specialises** — a parameterised
  factory, where Wire computes the concrete type args and spells
  `makeRepo<InMemoryTable>()`.

Because a generic `@Singleton` just exists (like every singleton), nothing
needs to *demand* it into the graph by spelling its concrete type. Consumers —
including adapter sinks (`@RoutedBy`) — **read** the constructed member; they
don't drive its construction. That is why the adapter chain resolves without a
CompositionRoot: the controller is already a node; `_wireRegister` consumes it.

`CompositionRoot` in task-cluster, and today's generated bootstrap spelling
`DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>(table:)`, are
the **pre-lift stopgap**: M1 has no opaque identities, so the abstract deps
can't resolve by identity, so the chain is held together by a concrete request
(CompositionRoot) driving specialisation. The target model is lift +
resolve-by-identity; the stopgap goes away when opaque identities land.

Iteration 9 lifts *every* `some P` binding as its own parameter (flat lifting);
iteration 10 refines this to lift only what's consumed abstractly — see below.

## Iteration 10 — lift the minimum (parameters for bridge targets, structural spelling for the rest)

> **Status:** planned. Iteration 9 shipped *flat* lifting — every binding with a
> `some P` identity gets its own `_WireGraph` generic parameter. This refines it
> to lift only bindings consumed abstractly, and records the plan.

### The problem with flat lifting

A self-producer that is only *read off the graph* — a root, like task-cluster's
controller handed to `buildApplication(controller: some APIProtocol)` — is
forced to declare `@Singleton(as: APIProtocol.self)` purely to get lifted, and
is then exposed as an anonymous `some APIProtocol`, hiding its real type. But
nothing *resolves* the controller abstractly; only its dependencies (the leaf
and the repository) are consumed through the constrained-parameter bridge. So
the controller shouldn't need an opaque identity, or a parameter, at all.

### The refined model

**A binding has one identity:**

- `@Singleton(as: P.self)` → `some P`.
- plain `@Singleton` → **structural**: `TypeName<…>` with each generic argument
  replaced by its resolved dependency's identity. `TaskController<Repository>`
  whose `Repository` resolves to the `some TaskRepository` binding has identity
  `TaskController<some TaskRepository>` (property `taskControllerOfSomeTaskRepository`).

(A binding carrying *both* `some APIProtocol` **and**
`TaskController<some TaskRepository>` is **aliasing** — the separate deferred
feature in *Multiple explicit identities*, not part of this.)

**A `_WireGraph` parameter is materialised only for a bare `some P` identity** —
the bindings consumers bridge to. A structural identity is *spelled* with those
parameters substituted for its `some P` sub-terms; it gets no parameter of its
own. So `some TaskRepository` becomes parameter `T1`, and the controller's field
is `TaskController<T1>` — its identity `TaskController<some TaskRepository>` with
that sub-term written as its parameter. Same identity, two spellings (graph
token vs generated Swift), not two identities.

For task-cluster this drops the controller's `as:` and one parameter:

```swift
// iteration 9 (flat): three parameters, controller anonymous `some APIProtocol`
struct _WireGraph<T0: …, T1: TaskRepository, T2: APIProtocol> {
    let someDynamoDBCompositePrimaryKeyTableSendable: T0
    let someTaskRepository: T1
    let someAPIProtocol: T2
}

// iteration 10 (minimal): two parameters, controller keeps its real type
struct _WireGraph<T0: DynamoDBCompositePrimaryKeyTable & Sendable, T1: TaskRepository> {
    let someDynamoDBCompositePrimaryKeyTableSendable: T0
    let someTaskRepository: T1
    let taskControllerOfSomeTaskRepository: TaskController<T1>
}
```

`graph.taskControllerOfSomeTaskRepository` is a real `TaskController<…>`, and
`TaskController` is a plain `@Singleton` again.

### What it requires

1. **Non-bridge-target generic `@Singleton`s become nodes spelled `TypeName<args>`**,
   each generic argument substituted by its resolved dependency's identity —
   not given an opaque identity, and not specialised to a concrete stack.
2. **Single-identity computation.** Resolution computes each binding's identity:
   `some P` when declared, else the substituted structural spelling; property
   names derive from it as usual.
3. **Codegen materialises `some P` identities as `_WireGraph` parameters** and
   renders every other identity with those parameters substituted for their
   `some P` sub-terms. Parameters are introduced in dependency order (a
   structural field references only parameters already declared).
4. **The bootstrap return erases only the parameter slots** (`_WireGraph<some P0,
   …>`); structural fields are inferred from the constructed values.

This is the *nested-position lifting* the codegen section defers, generalised
from "`Foo<some P>` within one binding" to "reuse another binding's parameter."

### De-risk first

Spike the shape before building (as spike-6 did for flat lifting): confirm

```swift
struct _WireGraph<T0, T1: TaskRepository> { let c: TaskController<T1> }
func _wireBootstrap() -> _WireGraph<some …, some TaskRepository> {
    let repo = …; let c = TaskController(repository: repo)
    return _WireGraph(…, c: c)
}
```

typechecks — the compiler should unify `T1` from the `repo` argument and match
`TaskController<T1>` against the concrete value, but opaque unification in a
nested position is the thing to prove first.

### Deferred / adjacent

- **Conformance-derived identity.** Could the *repository* also drop `as:`,
  deriving `some TaskRepository` from its sole `: TaskRepository` conformance?
  That reads a declaration rather than searching conformers, but reintroduces the
  ambiguity `as:` sidesteps (multiple conformances, marker protocols like
  `Sendable`). Separate decision; `as:` stays the explicit form.
- **Aliasing** (one binding under more than one identity) — the existing deferred
  *Multiple explicit identities* feature.

## Multiple opaque bindings via keying

Keys disambiguate same-identity bindings exactly as elsewhere:

```swift
extension Database {
    static let primary = BindingKey<some DatabaseClient>("primary")
    static let replica = BindingKey<some DatabaseClient>("replica")
}

@Provides(Database.primary) func primaryDB() -> some DatabaseClient { PostgresClient() }
@Provides(Database.replica) func replicaDB() -> some DatabaseClient { PostgresClient(readonly: true) }
```

Both have canonical text `some DatabaseClient` but distinct keys, so they
coexist; each lifts its own generic parameter.

## Forcing function

Iteration 7's incremental task-cluster adoption surfaced the need, and in
the consumer-side shape above rather than `@Provides -> some P`:
`CompositionRoot` is forced to spell
`TaskController<DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>>`
because the self-producing `@Singleton` repository and controller have
only concrete identities. `@Singleton(as:)` + the closure invariant
collapse that to `@Inject var controller: some APIProtocol` with the
concrete type named once at the leaf.

The cost is real and worth stating: adopting opacity means changing the
form of the layers involved (the chain becomes `some` end-to-end), the
same kind of shape-shift adopting any Wire feature can require. It buys
removing the nested concrete spelling and the manual composition root, at
the price of declaring opaque identity at each hop.

Scheduling stays around iteration 9 (the broader task-cluster migration),
but the case is now concrete rather than speculative, so this is the
design to implement against, not a hypothetical.

## What this note deliberately does NOT add

- **Conformance-based binding.** No resolving a protocol dependency to an
  arbitrary conformer. The closed promotion set is the only loosening of
  exact matching, and it is restricted to qualifier variants of one named
  protocol. Reasserted because it is the line that keeps this feature from
  becoming a type-system reimplementation.
- **Silent precedence.** Conflicts are producer-side errors resolved with
  keys, never silent tie-breaks.
- **Fabricated optionals / absent bindings.** Unchanged from the optional
  note: absence is always an error.

## Second forcing condition: `BuilderKey<B>`

Iteration 5's `BuilderKey<B>` (result-builder-driven multibinding fold)
couples into this spec for the parameterized-opaque case. A `BuilderKey`
whose result type the producer wants to declare as `some P<…>` — typically
a typed middleware-style builder — declares the opaque shape at the key
(producer-side, same dependency direction as everywhere else) and routes
through the same parameter-lifting mechanism:

```swift
static let middleware = BuilderKey<MiddlewareBuilder>.opaque(
    MiddlewareProtocol<String, String, MyContext>.self,
    "middleware"
)
```

`_WireGraph` lifts a generic parameter for the opaque slot; consumers
reference it via their generic constraint. Iteration 5 ships `BuilderKey<B>`
with the non-opaque cases (implicit result type derived from the builder,
and the explicit `any P<…>` form); the parameterized-opaque case lands
when this spec does. See
[`BuilderKeyDesign.md`](Documentation/Notes/BuilderKeyDesign.md) for the
coupling in full.
