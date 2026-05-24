# `BuilderKey<B>` — design notes

> **Status:** working notes captured during iteration 4d / pre-
> iteration-5 design discussions. Not the final form of any public-
> facing doc; intended to preserve the design space before context
> drifts. The concrete iteration-5 plan in `M1_PLAN.md` references
> this for the depth that doesn't fit in the iteration sketch.

## Architectural principle (carried over from the rest of Wire)

The binding type is declared producer-side. Consumers `@Inject`
against it and Wire validates the match; the consumer's annotation
cannot influence what the producer emits. This holds across
`@Provides`, `@Singleton`, `@Scoped`, `CollectedKey<T>`,
`MappedKey<K, V>`, and `BuilderKey<B>` alike. The asymmetry —
producer drives, consumer matches — is the same direction of
dependency that drives the rest of the framework's diagnostics
(missing-binding, duplicate-binding, key-checks). `BuilderKey`'s
design honours it: the fold function's return type comes from
the builder's source or from the `BuilderKey` declaration, never
from consumer annotations.

## What `BuilderKey<B>` is

The third multibinding key flavour alongside `CollectedKey<T>` (set/
list-style) and `MappedKey<K, V>` (map-style). Where the first two
fix the aggregation shape (concatenate-into-set, insert-into-map),
`BuilderKey<B>` lets the consumer define *how* contributors compose
by supplying a `@resultBuilder` type. The collected contributors
are folded through that builder; the consumer receives the built
artifact.

This is the multibinding feature that no other DI framework offers
because no other language has Swift's `@resultBuilder` machinery at
the language level. Dagger's `@ElementsIntoSet` is the closest
equivalent in the JVM world and is fixed to set concatenation.

## Core emission shape

User declares:

```swift
@resultBuilder
struct MiddlewareBuilder {
    static func buildBlock(_ components: any Middleware...) -> [any Middleware] {
        Array(components)
    }
}

extension Application {
    static let middleware = BuilderKey<MiddlewareBuilder>("middleware")
}

@Singleton @Contributes(to: Application.middleware)
struct AuthMiddleware: Middleware { ... }

@Singleton @Contributes(to: Application.middleware)
struct LoggingMiddleware: Middleware { ... }

@Singleton
struct Application {
    @Inject(Application.middleware) var middleware: [any Middleware]
}
```

Wire emits a per-`BuilderKey` fold function annotated with the
user's result-builder attribute, taking the known contributor list
as parameters and listing them as expressions in the body:

```swift
@MiddlewareBuilder
private func _wireBuildApplicationMiddleware(
    _ authMiddleware: AuthMiddleware,
    _ loggingMiddleware: LoggingMiddleware
) -> [any Middleware] {
    authMiddleware
    loggingMiddleware
}

// In the bootstrap:
let middleware = _wireBuildApplicationMiddleware(authMiddleware, loggingMiddleware)
```

The body is a list of expressions; Swift's compiler transforms it
using whichever result-builder methods the user happens to have
defined. Wire doesn't enumerate or care which ones — `buildBlock`,
`buildPartialBlock`, `buildExpression`, `buildArray`,
`buildOptional`, `buildFinalResult`, anything. The compiler
dispatches.

This is the central design decision: **delegate all result-builder
machinery to Swift**. Wire's codegen knows nothing about result-
builder protocol surface. Doing the work the language already
designed handlers for would couple Wire to a specific result-
builder method set, version that requirement, and break when Swift
adds new methods (e.g., `buildPartialBlock` landed in Swift 5.7).

## Determining the fold function's return type

`@resultBuilder`-annotated functions need a return type
annotation. The annotation is the binding type — what consumers
`@Inject` against. Wire's producer-side principle (the same one
that drives `@Provides` and `CollectedKey<T>`) says the binding
type is declared at the producer, not inferred from consumers.
Two paths, both producer-side:

### 1. Implicit from the builder's signature

For builders whose `buildBlock` / `buildFinalResult` return type
is unambiguous, Wire reads it directly from SwiftSyntax — no
declaration needed beyond `BuilderKey<MyBuilder>("name")`:

- `buildBlock(_ components: any P...) -> [any P]` → Wire emits
  `-> [any P]`.
- `buildBlock<T: P>(_ component: T) -> T` where `P` has no primary
  associated types → Wire emits `-> some P` (or `-> any P` in
  pre-OpaqueTypesSupport-iterations; see below).
- `buildFinalResult<T: P>(_ component: T) -> any P` → Wire emits
  `-> any P`.

This covers the common cases (set/list-style folds, plugin
registrations, service aggregations where contributors share one
non-parameterized protocol) end-to-end with no extra declaration.

### 2. Explicit on the `BuilderKey`

When the builder's signature underspecifies — most commonly,
parameterized protocols with primary associated types whose values
the builder constrains generically (`<T: MiddlewareProtocol>` says
the result conforms to `MiddlewareProtocol` but not which
`<Input, Output, Context>`) — the `BuilderKey` declaration carries
the explicit result type:

```swift
extension Application {
    static let middleware = BuilderKey<
        MiddlewareBuilder,
        any MiddlewareProtocol<String, String, MyContext>
    >("middleware")
}
```

The second type parameter on `BuilderKey` is the binding type.
Wire emits the fold function with that return type. The opaque
variant (deferred to when `OpaqueTypesSupport.md` lands) uses an
analogous factory that captures the `some P<…>` intent producer-
side:

```swift
extension Application {
    static let middleware = BuilderKey<MiddlewareBuilder>.opaque(
        MiddlewareProtocol<String, String, MyContext>.self,
        "middleware"
    )
}
```

(Final factory shape is one of the open design questions for
iteration 5 / 9; `some` can't appear directly as a generic
argument in current Swift, hence the factory form.)

### Consumer side — match, don't drive

Consumers `@Inject(.middleware)` against the key's declared
type. Wire validates the match — same direction of dependency as
elsewhere in the framework. The consumer's annotation cannot
influence the binding type; if the annotation disagrees with the
key's declared type, that's a compile error pointing at the
consumer (the same diagnostic shape used for `BindingKey<T>`
mismatches on keyed singletons).

## What's recoverable without OpaqueTypesSupport

Iteration 5 ships `BuilderKey<B>` for the cases where Wire can
derive the return type from `buildBlock` / `buildFinalResult` alone
(path 1 above). Concretely:

- **Concrete returns**: `[T]`, `[K: V]`, any non-generic type the
  builder produces.
- **Generic returns with non-parameterized protocol bounds**:
  `<T: P>(_:) -> T` where `P` has no primary associated types whose
  values vary by contributor, or where the consumer is content with
  `any P`.
- **`buildFinalResult`-erased returns**: builders that explicitly
  erase to `any P` at the end of the fold.

These are the cases where the result-builder mechanism is the
syntactic and graph-orchestration benefit; the consumer doesn't
need opaque-type preservation. Iteration 5 ships `BuilderKey` for
this set.

## What requires OpaqueTypesSupport

`BuilderKey` declarations that want to express their result type
as `some P<…>` rather than `any P<…>` — the parameterized-opaque
case — need `OpaqueTypesSupport.md`'s machinery. The producer-
side declaration carries the opaque shape via a factory like:

```swift
extension Application {
    static let middleware = BuilderKey<MiddlewareBuilder>.opaque(
        MiddlewareProtocol<String, String, MyContext>.self,
        "middleware"
    )
}
```

For this case:

1. The `BuilderKey` declaration captures the opaque-shape intent
   producer-side (no consumer-driven type inference).
2. The opaque-binding-as-generic-parameter machinery from
   `OpaqueTypesSupport.md` applies: `_WireGraph` lifts a generic
   parameter for the opaque middleware type, consumers reference
   the same lifted parameter via their generic constraint, and
   the opaque slot threads through.
3. Swift's type checker validates the fold function's body (the
   nested `TransformingMiddlewareTuple<…>` or whatever the builder
   produces) conforms to the declared opaque return.

`BuilderKey<B>` and OpaqueTypesSupport are coupled in the design
space because the opaque-shape `BuilderKey` declaration reuses
OpaqueTypesSupport's parameter-lifting mechanism verbatim. They
land together for this case. The non-opaque cases (path 1 above
and the explicit-`any P<…>` form of path 2) ship in iteration 5
without needing this spec.

## Iteration 5 scope and forward-compat

Iteration 5 ships:

- `@Contributes(to:)` macro recognising all three key flavours
- `CollectedKey<T>` with `withOrder:` parameter
- `MappedKey<K, V>` with `atKey:` parameter
- `BuilderKey<B>` with return-type derivation from
  `buildBlock` / `buildFinalResult` (path 1 above)
- Build plugin parameter validity checks
  (`withOrder:` only on `CollectedKey`, `atKey:` required on
  `MappedKey`, no mixing)

The deferred-to-OpaqueTypesSupport case (path 2, parameterized
opaque returns) is documented as a deferred decision in
`M1_PLAN.md` and lands when OpaqueTypesSupport itself does. The
forward-compat shape:

- The `BuilderKey<B>` runtime type and `@Contributes(to:)` surface
  don't change between the iteration-5 and post-OpaqueTypesSupport
  versions.
- Iteration 5's codegen for `BuilderKey<B>` emits a fold function
  with a concrete or `any`-erased return; the post-
  OpaqueTypesSupport version adds the opaque branch as an
  additional code path, recognising when the consumer's `@Inject`
  uses a `some P<…>` annotation.
- No existing iteration-5 `BuilderKey` usage breaks when
  OpaqueTypesSupport lands.

## Forcing conditions for OpaqueTypesSupport

`OpaqueTypesSupport.md` originally named iteration 9 (task-cluster
migration) as the forcing condition. `BuilderKey<B>` adds a second
trigger: if an iteration-5 `BuilderKey<B>` adopter wants to express
a parameterized-protocol middleware chain (or similar
type-transforming builder) with generic preservation, that's an
independent reason to move OpaqueTypesSupport forward.

Plan-level note: leave the iteration-9 timing as-is; pulling it
forward is a reactive decision based on whichever adopter (task-
cluster migration *or* a `BuilderKey` adopter) hits the case
first.

## Design axes settled by the result-builder-attribute approach

Several axes that looked open before we settled on emitting the
attribute are now non-questions:

- **Which result-builder methods does Wire consume?** Moot — Wire
  emits the attribute, the compiler dispatches whichever methods
  the user defined.
- **Injection-type derivation rules.** Covered by the priority
  list above (builder signature, consumer annotation, explicit
  declaration).
- **Empty contributor handling.** Falls out naturally: Wire emits
  a function whose body is empty if no contributors exist. If the
  builder defines `buildBlock()` (zero-arg), it works. If not, the
  compile error fires at the user's builder source, which is the
  right place.
- **Contributor type uniformity.** The user's `buildExpression`
  overloads handle coercion. Wire doesn't need to type-check
  contributor uniformity; Swift does.
- **Build-time vs runtime fold.** Always runtime — contributors
  are instances constructed in the bootstrap. The build-plugin
  knows the contributor list at build time but the fold itself
  evaluates at runtime against constructed values.

## Ordering of contributors (required, shared with `CollectedKey<T>`)

Result builders evaluate body expressions in order, and for many
realistic builders the order is type-relevant — not just runtime-
relevant. The middleware example's
`buildPartialBlock(accumulated: M0, next: M1) -> TransformingMiddlewareTuple<M0, M1>`
accumulates the type chain in contributor order, so reordering
contributors changes the resulting nested-tuple *type*, not just
its evaluation sequence. Order-sensitive folds are the typical
`BuilderKey` case, not an edge case.

`BuilderKey<B>` reuses the same `withOrder:` parameter that
`CollectedKey<T>` gets, on the `@Contributes(to:)` annotation:

```swift
@Singleton @Contributes(to: Application.middleware, withOrder: 10)
struct AuthMiddleware: Middleware { ... }

@Singleton @Contributes(to: Application.middleware, withOrder: 20)
struct LoggingMiddleware: Middleware { ... }
```

Wire sorts contributors by `withOrder:` ascending, then emits the
fold function with parameters in that order and the result-builder
body listing them in the same sequence. `buildPartialBlock` and
similar order-sensitive methods accumulate in the user-specified
order.

For order-irrelevant builders (Set-style folds), the user can
omit `withOrder:`. The fallback ordering for unranked contributors
is one of the iteration-5 open decisions — the realistic options:

- **Source order** (file path + line within module, then
  alphabetical across modules) — deterministic but arbitrary.
- **Stable but unspecified** — Wire picks a deterministic order
  but doesn't guarantee what it is, treating absence of
  `withOrder:` as "I don't care."
- **Compile error when mixed** — if any contributor specifies
  `withOrder:`, all of them must.

Probably the third — explicit ordering is opt-in but binary; once
you ask for it you ask for it everywhere on that key. Same posture
as `CollectedKey<T>` should take.

## Other open design axes for iteration 5

The substantive remaining decisions:

### Whether to subsume `CollectedKey<T>` under `BuilderKey<B>`

`CollectedKey<T>` is structurally a `BuilderKey` with a
concatenate-into-list builder. Could be expressed as
`BuilderKey<ConcatenateBuilder<T>>` with a stdlib-provided builder
type.

Trade-offs:
- Keeping both: better ergonomics (the common `Set`/`List` case
  doesn't make the user write a builder), more familiar to
  Dagger users (mirrors `@IntoSet`).
- Folding into one: simpler conceptual model, fewer surface
  primitives.

Probably keep both for iteration 5's gate; ergonomics matter for
the common case, and the surface symmetry with Dagger is a
deliberate positioning choice.

### Scope crossings

A `@Singleton`-scoped builder can include `@Singleton`
contributors but not `@Scoped` ones (scope-storage rule). A
`@Scoped(seed: X.self)` builder pulling from `@Singleton`
contributors is fine (cross-scope read). Per-scope `BuilderKey`s
mostly behave like any other binding under the scope rules, but
worth a sentence in the iteration-5 validation gate so the rule
is explicit.

### Interaction with `@Container`

A `@Container`-scoped `BuilderKey` builds from contributors
inside the same container. Cross-container contribution
(contributing to a builder in container A from outside it) isn't
supported by the current container model (atomic, no leakage).
Iteration 5's check should reject `@Contributes(to:)` references
that cross container boundaries, with a clear diagnostic.

## Why this design is worth shipping

`BuilderKey<B>` is one of the two features (alongside
OpaqueTypesSupport) that answer "why a DI framework *and* why
Swift" simultaneously. Most DI features are language-portable
(scopes, providers, basic multibindings); these two exist because
Swift's type system can express things other languages can't.

The result-builder-attribute approach makes the implementation
small — Wire emits a function, the compiler does the work. The
coupling with OpaqueTypesSupport is real but doesn't block
iteration 5: the common cases ship without it, the parameterized-
opaque cases ship with it. Together they form the most expressive
multibinding mechanism in any DI framework, Swift or otherwise.
