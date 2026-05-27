# Weak-reference injection — design notes

> **Status:** forward-looking design for iteration 4e (or later).
> Captures the shape so the work is ready to start when the
> iteration begins. Not yet implemented.

## Motivation

Cycle-breaking in DI graphs. The canonical case: two
`@Singleton`s reference each other, where one side is naturally
an "owner" and the other is naturally a "back-reference":

```swift
@Singleton
final class Coordinator {
    @Inject var view: View
}

@Singleton
final class View {
    @Inject weak var coordinator: Coordinator?
}
```

Without weak, the graph has `View → Coordinator` and
`Coordinator → View` strong edges, topological sort detects a
cycle, build fails. With weak, the back-reference is no longer
load-bearing at construction time: `View` constructs without
`Coordinator`, `Coordinator` constructs (taking `View` strongly),
and `View.coordinator` is assigned afterwards.

This is also a tidy answer to the runtime retain cycle that
would otherwise leak both instances. Swift's `weak` is the
language-level mechanism designed for exactly this.

## Why `weak` and not a `Weak<T>` framework type

Wire avoids shipping a `Weak<T>` wrapper-marker for the same
reason it stepped back from `Lazy<T>` as a wrapper-marker (see
`LazyTypeSupport.md`'s "Why not wrapper-marker recognition"):
framework-magic types that look like ordinary Swift types but
mean something specific to the build plugin are exactly the
surface the Wire-as-thin-DSL philosophy steers away from.

`weak` is different from `Lazy` in one important way: it has no
producer-side meaning. A producer always returns a strong
reference; "I produce a weak ref to X" isn't a sensible
statement. So the wrapper-marker pattern has no two-paths
ambiguity for weak — there's only one resolution shape (find a
T binding, store it weakly at the consumer's slot).

That makes Swift's `weak` keyword the natural mechanism:

```swift
@Inject weak var coordinator: Coordinator?
```

Every Swift dev already knows what `weak var x: T?` means. Wire
just respects it.

## Implementation shape

Four pieces. None of them are large, but they're spread across
the macro, discovery, graph, and codegen layers.

### Macro

`SingletonMacro` / `ScopedMacro` (and any future scope macros)
synthesise an init from the type's `@Inject` stored properties.
The macro change: when an `@Inject` property has the `weak`
modifier, **exclude it from the synthesised init's parameter
list**. The property stays as Swift-native `weak var x: T?`
storage. The init body doesn't assign it.

```swift
// Source:
@Singleton
final class View {
    @Inject var name: String
    @Inject weak var coordinator: Coordinator?
}

// Macro synthesises (roughly):
init(name: String) {
    self.name = name
    // self.coordinator left as nil — assigned post-construction
    // by the generated bootstrap
}
```

If the macro doesn't exclude weak props from the init, the init
parameter still includes `coordinator: Coordinator`, the
construction edge still exists, and the cycle persists. The
exclusion is the load-bearing piece.

#### Coexistence with `@Inject init`

Wire's existing rule is that `@Inject init` and `@Inject`
properties are mutually exclusive — a type uses one form or the
other, never both. The macro can't safely merge a user-written
init's body with property assignments it would need to splice in.

**Weak `@Inject` properties are the one exception** that may
coexist with `@Inject init`. The exception isn't a Wire policy
choice — it falls out of Swift's own rules:

- Init parameters can't be `weak` (the modifier requires a `var`
  property slot for the zeroing-weak-storage runtime hook).
- Weak storage therefore must live in a property.
- So if a user wants a weak dep at all, it must be a property. If
  they also want a custom `@Inject init` (e.g. for non-trivial
  construction on the strong deps), they have no choice but to
  combine the two forms.

Without the exception, weak refs would be silently incompatible
with custom inits — a constraint Wire imposed beyond what Swift
itself requires.

Macro logic: when scanning `@Inject` properties, partition them
into `{ weak, non-weak }`. **Non-weak `@Inject` properties retain
the original mutual-exclusion rule** (error if combined with
`@Inject init`); the weak ones don't. Codegen treats both
partitions the same way — both get assigned in the post-init
block.

Worked example:

```swift
@Singleton final class View {
    @Inject weak var coordinator: Coordinator?

    @Inject init(name: String, theme: Theme) {
        self.name = name
        self.theme = theme.appearance == .dark ? DarkTheme(theme) : theme
    }

    let name: String
    let theme: Theme
}
```

The user controls the init body for the strong deps; Wire
post-init-assigns the weak property. The rule reads as: "weak
properties are storage that Wire fills in, not parameters Wire
threads through your init."

### Discovery

`DependencyParameter` gains a new `DependencyKind` case
(working name: `injectWeakDeferredProperty`) — or, less
disruptively, a `isWeakDeferred: Bool` flag on the existing
`injectProperty` case. The visitor sets it when the property
declaration carries the `weak` modifier.

The dep's `type` stays the inner type `T` (not `T?`). Wire
resolves against `T` bindings. The `?` is part of the storage
shape, not the resolution shape.

### Graph

Two changes:

1. **Topological-sort ordering.** Weak edges still contribute to
   ordering — the post-init assignment can only fire after the
   target has been constructed. So `View → Coordinator (weak)`
   means `Coordinator` constructs before the assignment, and the
   assignment fires after `View` exists.

2. **Cycle detection.** Weak edges are excluded from cycle
   detection. The cycle `A (strong) → B`, `B (weak) → A` is
   valid; topo sort can resolve it as `[A, B]` (A first, then
   B's normal construction, then the post-init assignment to
   B's weak slot).

Implementation-wise, the simplest shape: split the dependency
edges into "strong" and "weak-deferred" sets per binding. Strong
edges go through normal topo sort + cycle detection. Weak-
deferred edges are recorded separately and scheduled into the
post-construction assignment block.

### Codegen

After the topological construction sequence emits, append a
post-init assignment block:

```swift
let name = "main"
let view = View(name: name)
let coordinator = Coordinator(view: view)
// Post-init assignments (weak-deferred edges):
view.coordinator = coordinator
```

The assignment block emits in a deterministic order (lexical by
consumer property name, say). Each assignment uses the consumer's
local variable + the property name + the resolved local for the
target. Swift's `=` from `T` to `weak var x: T?` does the right
thing automatically (implicit wrap to Optional + weak-storage
assignment).

## Lifetime semantics

Weak refs in DI have two failure modes worth pinning:

1. **Container holds the value strongly.** A `@Singleton` is
   held by the generated `_WireGraph` for the graph's lifetime.
   So even though `View.coordinator` is weak, `Coordinator`
   doesn't deallocate while the graph is alive — the graph
   itself retains it. Weak in Wire is about **cycle-breaking at
   construction-and-ARC level**, not about extending or
   shortening the binding's lifetime.

2. **Scoped weak deps.** A `@Scoped` value's weak ref to a
   `@Singleton` is safe (the singleton outlives the scope).
   The reverse — a `@Singleton` holding a weak ref to a
   `@Scoped` value — would dangle once the scope exits. The
   cross-scope-storage validation (iteration 4c) catches this
   case under the same rules as strong cross-scope deps: a
   `@Singleton` consumer can't reach into a `@Scoped` value's
   partition. Weak doesn't paper over the partition mismatch.

## Asymmetry with `Lazy<T>`

| | `Lazy<T>` | `weak` |
|---|---|---|
| What is it? | A regular Swift type Wire happens to ship | A Swift language keyword |
| Producer-side meaning? | Yes — "I produce a deferred-construction view" | No — producers always return strong refs |
| Framework recognition? | None | The macro recognises `weak` on `@Inject` properties to exclude them from the init |
| Graph effect | None — `Lazy<T>` is just another binding type | Weak edges skip cycle detection; ordering still applies |
| Cycle-breaking? | No — construction-time edge still exists | Yes — that's the whole point |

The framing converges on one rule: lean on Swift's language
features when they fit, don't invent a framework type when a
keyword already says the same thing.

## Out of scope

- **Unowned references.** Same shape as weak in principle, but
  the runtime guarantees differ (`unowned` traps on dangling
  access instead of zeroing). Not pursuing in 4e; can be added
  symmetrically later if a real case demands it.
- **Weak `@Inject init` parameters.** Init params can't be
  `weak` in Swift — weak storage requires a `var` property
  slot. So weak injection is property-injection-only by
  language constraint. Wire just respects the constraint.
- **Optional resolution semantics.** `@Inject weak var x: T?`
  resolves T against the graph and stores it weakly; the `?` is
  for Swift's weak-storage requirement, not for "T binding may
  be absent". If T isn't bound, that's a normal missing-binding
  error. Optional-binding semantics (i.e., "satisfy this dep
  with nil if no binding exists") is a different feature
  orthogonal to weak.

## Prior art: Carpenter's two-phase build

The two-graph construction-then-late-init model has direct
precedent in the Carpenter Swift DI framework
([github.com/TizianoCoroneo/Carpenter](https://github.com/TizianoCoroneo/Carpenter)).
Carpenter is a runtime DI framework that builds dependency
graphs explicitly, and its `Factory<Requirement, LateRequirement,
Product>` type carries two closures:

```swift
public struct Factory<Requirement, LateRequirement, Product> {
    var builder: (Requirement) throws -> Product
    var lateInit: (inout Product, LateRequirement) throws -> Void
}
```

Carpenter's `build()` topo-sorts a `dependencyGraph` of `builder`
edges, constructs every product, then topo-sorts a separate
`lateInitDependencyGraph` of `lateInit` edges and runs the
late-init closures in order. Both graphs are checked for cycles
independently — `dependencyCyclesDetected` and
`lateInitCyclesDetected` are distinct error cases. A cycle that
closes through `lateInit` is legal; cycles within a single phase
are not.

This is structurally identical to what Wire's weak-injection
iteration does, modulo two differences:

1. **Where the late-init is declared.** Carpenter has the user
   write a `lateInit:` closure at the factory site. Wire infers
   the late-init from `weak` on `@Inject` properties — the user
   declares intent with a Swift language keyword instead of a
   framework-specific API.

2. **When the work happens.** Carpenter is runtime — graph build,
   topo sort, and execution all happen at app startup. Wire is
   compile-time — graph validation and code emission at build
   time, with the generated bootstrap doing only the construction
   + post-init assignment work at runtime.

The Cleanse experimental compiler (`cleansec`) has a similar
shape going the other direction: it recognises a `WeakProvider<T>`
type and explicitly excludes it from cycle-detection traversal
(`cleansec/CleansecFramework/Resolver/Resolver.swift:203`,
`TypeKey.swift:42-69`). That's a third precedent for "compile-time
cycle-break via weak", though Cleanse ships the mechanism as a
framework wrapper type rather than respecting Swift's `weak`
keyword.

So Wire isn't inventing a new mechanism — the weak-as-cycle-break
pattern is established in both runtime (Carpenter) and
compile-time (Cleanse's experimental compiler) Swift DI prior art.
Wire's contribution is the specific expression: a Swift language
keyword instead of a framework wrapper type, and macro-driven
inference of the late-init step instead of an explicit closure at
the registration site.

## Iteration scope

The full feature is small but touches every layer of Wire:

1. Macro change (~10 lines + tests).
2. Discovery change (recognise the `weak` modifier — ~5 lines +
   a new test in DiscoveryTests).
3. Graph change (partition edges by strong/weak-deferred, skip
   weak in cycle detection — ~20 lines + cycle-detection tests).
4. Codegen change (emit post-init assignment block after the
   construction block — ~30 lines + emission tests).
5. Integration test: a `@Singleton` cycle that compiles by
   virtue of one side being `weak`; assert the runtime
   reference works.

Pragmatically: a few hundred lines including tests, mostly
spread thin. Schedule as 4e if iteration 4 has room, or push to
a follow-up iteration if 4 is running long. Not on the M1
critical path — the feature is quality-of-life for adopters who
hit cycle situations, not a blocker for the minimum viable DI
goal.

## Open implementation questions

1. **Macro recognition through SwiftSyntax.** The macro sees
   `weak var x: T?` as a `VariableDeclSyntax` with `weak` in
   `modifiers`. Confirm that `accessorBlock` interactions
   (computed properties marked `weak`?) don't trip up the
   "exclude from init" logic. Probably not an issue — weak is
   storage-only — but worth a test.
2. **Diagnostic for `weak` on a value-type binding.** If a user
   writes `@Inject weak var x: SomeStruct?`, Swift will reject
   the property declaration ("'weak' may only be applied to
   class and class-bound protocol types"). Wire doesn't need to
   add its own check; Swift's error is precise enough. But it's
   worth confirming with a test that the macro doesn't swallow
   the Swift diagnostic by failing earlier.
3. **Property-name collision in the post-init block.** The
   assignment `view.coordinator = coordinator` assumes `view`
   and `coordinator` are unambiguous local-variable names in
   the bootstrap. The existing identifier-collision detector
   should already catch the case where two bindings share an
   identifier; confirm it still applies after the weak-codegen
   work and add a test if there's a gap.
