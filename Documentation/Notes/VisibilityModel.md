# Wire's visibility model — design notes

> **Status:** 5α implemented — the declaration-too-private error, the
> dead-binding warning (`DeadBindingDiagnostics.swift`, gated by
> visibility, judged per container), and the `allowUnused:` silencer on
> `@Singleton`/`@Scoped`/`@Provides`. Locks the conceptual model that 5β
> (multibindings) + future container composition both build on.

> **See also:** the "must be at least `internal`" threshold below assumes
> the bootstrap is generated into the *same* module. Multi-module
> composition raises it to `public`/`package` for cross-module-consumed
> bindings — see
> [`MultiModuleComposition.md`](MultiModuleComposition.md) (the naming
> half of the same shift uses SE-0491 module selectors).

## What this note is for

Wire reads source-level access modifiers (`public`, `package`,
`internal`, `fileprivate`, `private`) on binding declarations to
drive two policies:

1. **Diagnostic strictness** — how aggressively Wire warns about
   "declared but never consumed" patterns. Non-public bindings
   are within Wire's full build-time view; public bindings aren't.
   Visibility is the signal for "do I have enough information to
   make a confident call?"
2. **Container composition contract** (future) — which bindings
   are exposed across composed containers. Access modifiers
   become the composition boundary markers, with no separate
   annotation surface required.

Both policies key off the same signal. That's the load-bearing
choice this note pins.

## The post-`package` access-modifier triad

Swift 5.9 added `package` as the cross-target-within-a-package
access modifier. Wire's model assumes the post-`package`
convention:

| Modifier        | Meaning                                                         |
|-----------------|-----------------------------------------------------------------|
| `public`        | External / published API. Downstream consumers may exist.       |
| `package`       | Within-package, cross-target. Same-package consumers may exist. |
| `internal`      | Within-target (the default).                                    |
| `fileprivate`   | Within the source file.                                         |
| `private`       | Within the declaration scope.                                   |

Pre-`package`, `public` did double duty — both "publish externally"
and "share across targets within my package." Many older Swift
codebases overuse `public` as a result. Wire's policy assumes the
precise triad: a developer who marks a binding `public` is
asserting "this is exposed externally; downstream consumers may
exist." Wire stays permissive for `public` declarations because
that assertion implies Wire's view of the build is incomplete.

Developers transitioning from older conventions may initially mark
bindings `public` when they meant `package`. Wire's policy gives
those bindings permissive diagnostics, which prompts the question
"do I actually intend this externally?" — pushing the developer
toward the precise modifier they want. The friction lands at
exactly the right point.

## Policy 1: diagnostic strictness

### What Wire diagnoses

Two sibling diagnostics. The dead-binding warning is the
empty-consumer policy described below; the declaration-too-private
error is a structural prerequisite that fires regardless of
consumer count.

**Declaration-too-private error** (severity: `.error`) — fires
when a source-level name that Wire's generated bootstrap will
emit a textual reference to is declared at `fileprivate` or
`private` visibility. Wire's generated `_WireGraph.swift` lives
in a separate file from the user's source, so any such
declaration more restrictive than `internal` is invisible to the
generated code. Swift would catch this eventually with "cannot
find 'X' in scope" pointing at the generated file, but Wire
catches it at discovery time and anchors the error at the
declaration's actual source line. Build-blocking, same shape as
iteration 4e's `@Inject mutating func` on struct diagnostic.

The unifying principle: **any name Wire's bootstrap textually
references must be at least `internal`.** Macro-synthesized
members inside the user's host type aren't subject to this rule
because they live in the host type's scope; only the *host
type's* visibility constrains what the bootstrap can see.

**Which slots in which annotations:**

| Annotation                                | Slot the bootstrap references            | Must be `internal+`?              |
|-------------------------------------------|------------------------------------------|-----------------------------------|
| `@Singleton` / `@Scoped` type             | Type name + macro-synthesised init       | Yes — the type                    |
| `@Provides let foo`                       | Property name                            | Yes                               |
| `@Provides func makeFoo()`                | Function name                            | Yes                               |
| `@Provides static let foo` on a type      | `Type.foo` reference                     | Yes — both the type and the property |
| `@Container enum Foo`                     | Enum name + static members it carries    | Yes — enum + members              |
| `@Inject init(...)`                       | Init signature                           | Yes                               |
| `@Inject var x: T` (constructor-injected) | None directly — macro generates init inside host scope, bootstrap only calls the init | No — property visibility is irrelevant |
| `@Inject weak var x: T?`                  | `consumer.x = ...` post-init assignment  | Yes — property                    |
| `@Inject func receive(x:)`                | `consumer.receive(x: ...)` call          | Yes — method                      |
| `BindingKey<T>` / `CollectedKey<T>` / `MappedKey<K, V>` / `BuilderKey<B>` | Static declaration referenced by qualified name in key-check + lookup code | Yes |

The constructor-injected `@Inject var x` row is the one
counterintuitive case: `@Inject private var` works fine, because
the macro generates `init(x: T) { self.x = x }` inside the host
type at expansion time (it can see private storage), and the
bootstrap only ever calls the init. `@Inject weak var` and
`@Inject func` differ because the bootstrap directly references
the property / method post-construct, so their visibility *is*
constrained. Worth flagging because the asymmetry would be a
surprising footgun otherwise.

### Error message shapes

The standard form, used for declarations whose constraint is
self-explanatory (the bootstrap references them, so they need
to be visible):

*"`@Singleton` types must be at least `internal` — Wire's
generated bootstrap is in a separate file and can't reference
`fileprivate`/`private` declarations. Change to `internal`,
`package`, or `public`."*

Adapted per annotation (`@Provides let`, `@Provides func`,
`@Container`, `@Inject init`, `BindingKey<T>`, etc.). The fix-it
is the same shape in every case: bump visibility to `internal`
or higher.

For `@Inject weak var` and `@Inject func`, the standard message
isn't enough — adopters who already learned that `@Inject
private var` works fine will reasonably wonder why the same
modifier fails on the weak / method variants. The diagnostic
attaches a `Diagnostic.Note` explaining the asymmetry:

```
View.swift:12:5: error: '@Inject weak var' property must be at least 'internal' — Wire's generated bootstrap assigns to the property post-construct and lives in a separate file from this declaration.
View.swift:12:5: note: '@Inject var' / '@Inject let' (non-weak) can be 'private' because the macro generates the init within the host type's scope; only post-construct delivery patterns (weak, @Inject func) need broader visibility because the bootstrap references them from a separate file.
```

Same shape for `@Inject func`, with the primary line adapted
("'@Inject func' must be at least 'internal' — Wire's generated
bootstrap calls this method post-construct…") and the note
identical (the constructor-injected `@Inject var/let` is fine,
post-construct delivery isn't). The explanation captures the
*why* of the asymmetry without bloating the primary message —
matches Swift compiler convention of using `note:` lines for
related context.

**Dead-binding warning** (severity: `.warning`) — a binding is
declared but no code in Wire's visible build consumes it.
Concretely:

- A `@Singleton` / `@Scoped` type that no `@Inject` references.
- A `@Provides let` / `@Provides func` whose bound type is never
  injected anywhere.
- A `BindingKey<T>` / `CollectedKey<T>` / `MappedKey<K, V>` /
  `BuilderKey<B>` declared but no keyed `@Inject(K)` references it.

A "consumer" of a binding is any of:

- `@Inject var x: T` (or `@Inject weak var`, or `@Inject func
  receive(x: T)`) — direct consumers.
- `@Inject init(x: T)` parameters.
- `@Provides func makeFoo(x: T)` parameters.
- Multibinding contributors aggregate into a multibinding, so they
  satisfy "the multibinding key has consumers" via the
  multibinding's own consumer.

### The visibility-driven rule (dead-binding warning)

| Visibility       | Empty-consumer behavior                                                  |
|------------------|--------------------------------------------------------------------------|
| `public`         | Silent. Downstream may consume.                                          |
| `package`        | Warn — Wire sees the whole package.                                      |
| `internal`       | Warn — Wire sees the whole target.                                       |
| `fileprivate`    | Rejected upstream by the declaration-too-private error — never reached.  |
| `private`        | Rejected upstream by the declaration-too-private error — never reached.  |

`package` and `internal` share the "warn" tier because in each case
Wire's build-time view captures all possible consumers within that
visibility scope. The single permissive tier is `public`.
`fileprivate` and `private` aren't possible at this point because
the declaration-too-private error already failed the build.

### Silencer

A binding can opt out of the warning explicitly:

```swift
@Singleton(allowUnused: true)
struct DeliberatelyUnusedForNow { /* ... */ }
```

Naming TBD (`allowUnused:`, `permitMissing:`, `unusedOK:`); locked
in during 5α implementation. The signal is "I declared this
intentionally without consumers and I want Wire to stay quiet."
Same parameter shape on `BindingKey<T>` declarations and the
multibinding key flavors.

### What Wire does *not* diagnose under this policy

- A binding consumed by code Wire can't see (compiled libraries,
  Objective-C interop, runtime reflection). Wire only sees source
  it parses; anything outside is invisible. Public-tier silence
  is the conservative position for this case.
- A binding consumed only by `@Provides` whose return type Wire
  doesn't recognize as a binding type (e.g., a `@Provides func`
  returning `Foo` that's never injected anywhere — that's the
  `Foo` binding being dead, not the `@Provides func`).
- Transitively-dead bindings (a binding consumed only by another
  dead binding). 5α detects first-order dead bindings only; a
  fixed-point analysis is a future refinement if it proves useful.
- Bindings consumed only through generic specialisation. Liveness
  runs first-order on *discovered* bindings, before specialisation,
  so the generic `Foo<T>` template (consumed as `Foo<Concrete>`) and
  a `@Provides T` injected only as a generic's type parameter aren't
  seen as consumed. Generic templates are therefore skipped outright;
  a non-generic binding consumed only via specialisation may
  false-warn and is silenced with `allowUnused:`.

## Policy 2: container composition contract (future)

Container composition is a deferred decision (M2+ work, no
concrete iteration target yet). When it lands, access modifiers
become the composition-boundary contract — bindings from a
composed container's source flow to the consumer container per
their declared visibility:

| Modifier        | Composition behavior                                    |
|-----------------|---------------------------------------------------------|
| `public`        | Available to any downstream composer.                   |
| `package`       | Available within the same package's composition graph.  |
| `internal`      | Within the same target only.                            |
| `fileprivate`   | N/A — declaration-too-private error caught upstream.    |
| `private`       | N/A — declaration-too-private error caught upstream.    |

`fileprivate` / `private` rows resolve trivially: the
declaration-too-private error from Policy 1 already rejects these
visibilities at declaration time, so they never reach the
composition layer. Composition inherits the rule rather than
restating it.

The model unifies the diagnostic policy and the composition
contract under one signal. A developer who reasons about access
levels for ordinary Swift API design is reasoning about Wire's
behavior at the same time. No additional annotation surface
needed.

## Why visibility as the signal

Three alternatives were considered:

1. **Strict-default with explicit opt-in (Dagger-style
   `@Multibinds`).** Always warn on empty / dead; require a
   `permitEmpty` annotation to silence. Pro: explicit. Con:
   universal-in-library-case annotation noise; new surface to
   learn; doesn't carry information for composition.

2. **Permissive-default with explicit opt-in for strict.** Silent
   by default; require `requireNonEmpty:` to get warnings. Pro:
   no friction. Con: bugs hide silently in app-level code; not
   the post-iteration-4 "strict on ambiguity, friendly on the
   rest" posture.

3. **Visibility-driven (the chosen design).** Visibility *is* the
   signal Wire needs — public means "I can't see all consumers,"
   non-public means "I can." The policy falls out of the language
   semantic developers already use for API design. Composition
   reuses the same signal at no extra cost.

The visibility-driven model also has a property the alternatives
lack: **the policy is invariant under refactoring.** If a
developer changes a binding's visibility from `internal` to
`public` (preparing to expose an API), Wire's policy
automatically adjusts to "no warnings" — because the developer
just told Wire that downstream consumers may exist. There's no
need to remember to add or remove a separate opt-in annotation.
The single signal carries the necessary information.

## Prior art

No DI framework I'm aware of uses host-language visibility as
the diagnostic-policy driver. The closest analogs:

- **Dagger** (JVM): empty multibindings are a compile error by
  default. `@Multibinds` is the explicit opt-in for "this
  multibinding may be empty." Visibility-agnostic. The annotation
  becomes near-universal on library-declared keys, where it's
  effectively noise.
- **Spring** (JVM): empty multibindings resolve silently to `[]` /
  `[:]`. No diagnostic. Visibility-agnostic. Suits Spring's loose
  auto-conformance posture but allows silent footguns in app
  code.
- **Guice** (JVM): empty allowed when the `Multibinder` is
  declared. Declaration itself is the signal. Visibility-agnostic.
- **Cleanse** (Swift): runtime DI, multibindings via
  `.intoCollection()`. Empty handling not strongly opinionated;
  registered collection resolves to whatever's contributed.

Wire's visibility-driven approach is novel in that it ties the
diagnostic policy to a structural property of the source rather
than to an explicit annotation or runtime declaration. The closest
*spirit* match is Guice's "declaration-is-signal" — but Guice
uses the multibinder's existence, where Wire uses the access
modifier on the key declaration. Wire's variant scales further:
the same signal handles diagnostics for *all* binding kinds, not
just multibindings, and extends to composition without
modification.

## Open implementation questions for 5α

1. **Silencer parameter name.** Options: `allowUnused:`,
   `permitMissing:`, `unusedOK:`, `expectedUnused:`. Naming
   decided during 5α; design note updated to reflect the choice.
2. **`@Container enum` access semantics.** Wire's `@Container`
   currently routes bindings through a generated graph struct.
   Visibility-capture on those bindings needs verification —
   `static let` members of a container enum, `@Provides`
   declarations as static members. Probably falls out cleanly
   from SwiftSyntax's access-level inspection but worth a test.
3. **Macro-generated symbols.** Wire's macros generate `init`
   declarations, `_wireRegister` functions, setter extensions
   for actor weak vars, etc. These derive their visibility from
   the host type. Confirm Wire's discovery walks the source-level
   declarations (not macro-expanded output) so the visibility
   captured matches what the developer wrote.
4. **Transient development-state noise.** A binding declared
   before its consumer is wired produces a warning until the
   consumer lands. Acceptable for occasional cases; problematic
   if frequent. Validate against real fixtures during 5α; if
   noise is high, consider noise-reduction mechanisms (don't
   warn during partial-build states, or batch warnings).
5. **`@Inject weak var` and post-construct consumers.** Iteration
   4e's member-injection deps count as consumers (they're real
   `@Inject` references). 5α confirms the consumer-count walk
   includes both init-time deps AND member-injection parameters.

## Forward-compat commitments

This note pins Wire to:

- **Visibility as the signal** — not a separate opt-in annotation,
  not multi-tier severity flags on the diagnostic. One signal.
- **The post-`package` triad as the assumed convention.** Adopters
  using pre-`package` Swift get a warning surface that's slightly
  off (everything's `internal`/`public`); the model still works
  but is less expressive. Wire's documentation should note this.
- **Symmetry across binding kinds.** Whatever visibility policy
  applies to `@Singleton` applies the same way to `@Provides`,
  `BindingKey<T>`, and the multibinding key flavors. New binding
  kinds inherit the policy automatically.
- **The `fileprivate`/`private` declaration-too-private error.**
  Any Wire binding (`@Singleton`, `@Scoped`, `@Provides`, and
  every key flavor) declared at `fileprivate` or `private`
  visibility is a build-blocking error at discovery time. Wire's
  generated code lives in a separate file and can't reference
  declarations more restrictive than `internal`. This rule is
  permanent: composition inherits it rather than introducing it.

These shapes are load-bearing for both 5α and 5β; landing them in
this note before either iteration starts is the way to ensure
they're internally consistent.
