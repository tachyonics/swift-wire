# Scope & key-model evolution — design exploration

> **Status:** forward-looking design, not implemented. Captures an
> exploration of three related extensions (scopable `@Provides`, a
> value-level scope-input key, and unified key tracking) and the
> sequencing decided for them. Nothing here is built; it exists so the
> reasoning isn't re-derived later.

## Where it started: two single-vs-multi inconsistencies

1. Wire **warns on dead/empty and errors on missing** multibinding keys,
   but does none of that for single-binding (`BindingKey`) keys — and it
   *requires* a multibinding key to be Wire-discovered (scanned), with no
   such requirement on single keys.
2. `allowUnused:` sits on the **annotation** for single bindings
   (`@Singleton(allowUnused:)`) but on the **key** for multibindings
   (`CollectedKey(allowUnused:)`).

## The principle that justifies them

Both follow from **where the type lives**:

- A single binding's type is **producer-side** (`@Provides(K) -> Database`);
  the key is just a discriminator. Wire never needs to read the
  `BindingKey` — it matches by the key's canonical text and lets the
  compiler unify the type (the generated `_check`). So Wire doesn't track
  single keys, can't diagnose them, and they can live anywhere visible
  (incl. a library).
- A multibinding's type is **key-side** (`CollectedKey<any Service>`'s
  element type is on the key, not on any one contributor). Wire *must*
  read the key declaration to build the aggregate → it tracks them →
  diagnoses dead/empty/missing → requires them discoverable.

> **Unifying rule:** Wire tracks — and applies visibility / `allowUnused`
> to — the *unit that carries the type*: the **binding** for single
> bindings, the **key** for multibindings.

`allowUnused` placement follows directly (it goes on the warned/tracked
unit), and `@Singleton` having no user-facing key (its `key` is
macro-generated) makes the annotation the only possible home there. Prior
art agrees that self-producing bindings are unkeyed: Dagger's
`@Inject constructor` and Guice's JIT bindings can't be qualified — only
explicit producers (`@Provides`/`@Binds`/`bind()`) can. So
`@Singleton`/`@Scoped` unkeyed, `@Provides` keyed, is conventional.

## Axis A — scoping `@Provides` via a scope block

> **Status: implemented.** `@Scoped(seed:)` on a namespace enum is a scope
> block; its `@Provides` route into the seed scope, consumed end-to-end by
> `ScopedProvidesExample`. Discovery-only — no graph or codegen change.
> `@Singleton` inside a block is a diagnosed error. The deferred items
> below (bare `@Scoped`, the self-production/scope separation) remain open.

Wire can scope a *type* (`@Scoped`) but not a `@Provides`. Dagger keeps
scope orthogonal — `@Provides @RequestScope @Named("x")` (scoped + keyed)
is expressible; Wire can't express a scoped keyed binding at all.

### The standard triangle, and Wire's missing corner

DI scoping separates three things that Wire fuses into two annotations:

- **Self-production** — "construct this from its `@Inject` members"
  (Dagger: `@Inject constructor`).
- **Scope membership** — which scope a binding lives in (Dagger: the
  `@Scope` annotation, e.g. `@Singleton` / `@RequestScoped`).
- **Scope definition** — declaring that a scope *exists*, with an extent
  (Dagger: `@Component` / `@Subcomponent`).

Wire fuses self-production + membership into `@Singleton` / `@Scoped(seed:)`
and had **no** source-level scope-*definition* surface. `@Container` is the
definition surface for the *container* axis; nothing existed for the
*scope* axis.

### The model: `@Scoped(seed:)` on a namespace enum

A **scope block** is the scope-axis sibling of `@Container`:
`@Scoped(seed: X.self)` on a caseless namespace enum routes the
`@Provides` declarations inside it into the `X`-seed scope, without
repeating the seed on each producer.

```swift
@Scoped(seed: RequestSeed.self)
enum RequestProviders {
    @Provides static func makeContext(seed: RequestSeed) -> Context { ... }
    @Provides static let tag: Tag = Tag()
}
```

Same spelling as the type form, because conceptually it's the same act
(declaring a seed scope); on a type it scopes the instance, on a namespace
enum it defines the scope for the block. It maps 1:1 onto the existing
`Partition(container, scope)`: discovery tracks an enclosing `seedScope`
on the visitor frame (mirroring `containerName`), `record()` reads it for
providers, and `orchestrateSeedScope` consumes the partition unchanged.
Composes with `@Container` for `(container, seed)` cells for free.

### Why a block, not per-producer `@Provides @Scoped`

The originally-sketched `@Provides @Scoped(seed:)` (scope stacked on each
producer) is **mechanically infeasible**: a macro's `@attached` roles all
apply to the target, so a single `@Scoped` can't be a `member` macro on
types *and* a `peer` macro on producers — `@attached(member)` on a
func/var is a hard compiler error. The block sidesteps this (the marker
only ever sits on an enum, which bears members) *and* is less verbose
*and* is the proper scope-definition surface. So it's the model, not a
workaround.

### Resolved sub-decisions

- **Self-producers stay standalone.** Scopes are global identities (like
  keys), so a `@Scoped(seed: X)` type already declares its scope from
  anywhere — it never needed the block. The block exists only because
  `@Provides` had no way to name a scope.
- **`@Singleton` in a scope block is an error** — process lifetime can't
  live in a seed scope; left unflagged it would silently stay
  process-scoped.
- **Deferred:** bare `@Scoped` (no `seed:`) *inside* a block, meaning
  "self-produce, inherit the block's seed" — the ergonomic answer to
  "self-produce with scope = enclosing." Explicit `@Scoped(seed:)` already
  covers self-producers with only minor redundancy, so this waits until it
  bites. The fuller self-production/scope separation (a scope-neutral
  self-production marker) is the longer-range version of the same idea.

**Decision: do Axis A right after iteration 5**, with the scope/lifecycle
work. No dependency on anything else here.

## Axis B — scope identity vs. input, and a value-level scope key

Wire **fuses** scope identity and input: the seed type is both the
partition key and the single injectable value. Dagger **separates** them:
the `@Scope` annotation is identity, `@BindsInstance` supplies the
value(s) — so Dagger does 0/1/N inputs.

A Swift-idiomatic separation: a **value-level scope key** whose arguments
are the inputs, e.g. (sketch — syntax unresolved)

```swift
let requestScope = SeedKey(request: RequestSeed.self, userId: Request.userId)
```

- Inputs are values (metatypes / key references), labels name the
  bootstrap parameters, the generated `bootstrap` stays concrete.
- The current seed is the one-input special case
  (`@Scoped(seed: X.self)` ≈ a single-input scope key), so this *subsumes*
  rather than replaces it.

### The value-space / type-space key insight

Keyed inputs (two same-typed inputs, à la qualified `@BindsInstance`)
**don't fit a generic `ScopeKey<…>` type**: Swift won't put a custom
attribute on a generic argument, and Wire's keys are *value* references
(`Request.userId`), which can't ride in *type* parameters. A **value-level**
form escapes this — keys are just more values.

And once you're passing key references, **the key already knows its type**
(`Request.userId` is `BindingKey<String>`), so `String.self` is redundant
— *if* Wire can resolve the reference. But Wire scans text, so resolving
`Request.userId` → `(String, key)` requires **tracking `BindingKey`
declarations** — which it doesn't do today.

### `BindingKey` tracking is the linchpin

Tracking single keys flips concern 1 from "optional parity tweak" to
*foundational*:
- Keys become **self-describing** (type + identity from one reference).
- Single/multi key diagnostics become consistent (concern 1 resolved).
- Scope inputs can be named by key alone — the redundancy disappears.

i.e. `BindingKey<T>`, `CollectedKey<T>`, and a scope key all become "a
declared, type-carrying reference Wire tracks," and diagnostics, scope
inputs, and qualifiers read uniformly off that.

But it's a **behavioral change** (Wire would start diagnosing single
keys). **Decision: bundle it with multi-module composition** —
composition needs Wire to discover keys across the parse set anyway (see
[`MultiModuleComposition.md`](MultiModuleComposition.md)), and doing it
there lands the change *before library behaviour expectations lock in*.

### Open syntax wrinkles (for whoever builds it)

- Arbitrary argument labels can't be a fixed `init` — needs a positional/
  variadic form or a builder.
- Mixing a bare metatype (`RequestSeed.self`) with a key reference in one
  call needs a common parameter type (a `ScopeInput` value or a shared
  protocol).

## Sequencing summary

1. **Finish iteration 5** (multibindings) — Step 7 validation gate. Don't
   derail it.
2. **Axis A — scopable `@Provides`** — right after iteration 5, on the
   current seed model.
3. **`BindingKey` tracking + value-level scope key** — with **multi-module
   composition**, before library expectations solidify. The key-tracking
   unification, the value-level scope inputs, and concern-1 consistency
   all fall out together there.

Building on the current seed model now forecloses nothing: the
multibinding-key tracking already shipped is the same pattern this would
extend, and the value-level scope key can absorb the seed later.
