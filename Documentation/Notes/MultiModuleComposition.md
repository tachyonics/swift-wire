# Multi-module composition

> **Status:** forward-looking design. Multi-module composition is not
> implemented — Wire is per-module today (the build plugin runs WireGen
> per target; `_WireGraph` is generated into, and references types
> within/imported by, that one module). This note records the design
> direction so two coupled decisions — cross-module **naming** (SE-0491
> module selectors) and cross-module **visibility** — aren't relitigated
> when composition is taken on. Nothing here is built yet, and nothing
> needs building until there's a composition feature to consume it.
>
> **Now being taken on:** M1_PLAN iteration 7 implements this note across
> sittings 7a–7g. The two foundations it calls out land first — single-
> `BindingKey` tracking (7a) and origin-module metadata per binding (7b) —
> before the cross-target reading, activation, and naming/visibility work.

## What composition is

A dependency graph that spans **several modules**: module `A` and module
`B` each declare `@Singleton`/`@Provides`/`@Inject`, and a higher-level
graph composes them — `B` consuming `A`'s bindings, an app module
composing both. (Dagger does this with component dependencies /
subcomponents; Needle with its component hierarchy.) Wire's `@Container`
is *within*-module grouping, not this.

Composition changes one fundamental thing: **the generated bootstrap
references types from modules other than its own, and is consumed across
module boundaries.** That breaks two assumptions the single-module model
bakes in — naming and visibility.

## Naming — use SE-0491 module selectors

In a single module the generated file lives in that module, so a bare
type reference resolves by Swift's normal rules (own-module types win by
local precedence). Compose `A` and `B` where **both define a `Logger`**,
and the composed graph genuinely references `A.Logger` *and* `B.Logger`
in one generated file — a real cross-module name clash. This is exactly
what [SE-0491 module selectors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0491-module-selectors.md)
exist to resolve: emit `A::Logger` / `B::Logger` to pin each reference to
its module.

**The load-bearing insight: Wire can qualify correctly without name
resolution — the knowledge is *structural*, not semantic.** Wire ran
discovery on `A`'s sources, so it *knows* `A`'s `@Singleton`/`@Provides`
types are from `A` — not by type-checking, just by "I parsed `A`'s
files." A dependency reference resolves to a producer binding whose
origin module is likewise known. So `A::Logger` / `B::Logger` come
straight from per-module-discovery metadata.

This is why the earlier "Wire can't auto-emit `::` usefully" conclusion
(see [`OptionalMatchingAndCycles.md`](OptionalMatchingAndCycles.md)) was
**specific to single-module**: there, the only real ambiguity is two
*imported* types colliding, whose modules Wire genuinely can't determine
(no name resolution), so auto-qualifying buys nothing. Composition flips
it: the collisions are between modules Wire *discovered itself*, so it
has exactly the information needed.

**Prerequisite (the actual work, when the time comes):** the discovery
model must carry **origin-module metadata per binding**. It doesn't
today — a single module doesn't need it. That metadata is load-bearing;
the `::` emission is mechanical once it exists. (Note also: module
selectors disambiguate, they don't *normalize* — `A::Logger` and
`Logger` may be different types, so they stay distinct graph identities.
Module qualification is therefore a composition concern, not part of the
deferred typealias/collection-sugar normalization.)

## Visibility — the cross-module threshold

The sibling break, easy to forget. [`VisibilityModel.md`](VisibilityModel.md)'s
rule is "a binding must be at least `internal`," because the generated
bootstrap lives in the **same module** (a separate file). Under
composition a binding consumed by **another** module's composed graph
must be at least `public` (or `package`, within the same package) — the
consuming bootstrap can't reach `internal` declarations across the module
boundary.

So the declaration-too-private threshold becomes **context-dependent**:
`internal` for in-module consumption, `public`/`package` for
cross-module-consumed bindings. Whether a binding is cross-module-
consumed is, again, knowable structurally from the composition graph.

## Multibinding key references across modules

Iteration 5β's multibindings reference a key by name — `@Contributes(to:
X)` on a contributor, `@Inject(X)` on a consumer — and 5β validates that
`X` resolves to a discovered key declaration (a `CollectedKey` /
`MappedKey` / `BuilderKey` `static let`). That "must exist" check is
scoped to **the plugin's parse set**, which is one module today.

Composition widens the parse set, not the rule: a contributor in module
`B` may legitimately `@Contributes(to: A.serviceKey)` for a key declared
in `A`, and an app module may aggregate contributors from both. The
missing-key diagnostic stays "no such key *in the parse set*" and
loosens automatically as more packages are parsed — no special-casing.
Two constraints ride along, both already covered above:

- **Visibility** — the key declaration must be reachable from the
  contributing/consuming module (≥ `public`, or `package` within a
  package), the same cross-module threshold as any other binding.
- **Naming** — a key referenced across modules qualifies via SE-0491
  (`A::serviceKey`) from origin-module metadata, like any other
  cross-module reference.
- **`withOrder:` uniqueness** — iteration 5β requires globally-unique
  ranks per key (duplicate `withOrder:` is an error, keeping "ranked" a
  strict total order). That's fine in one module but hard to coordinate
  across independently-authored modules contributing to a shared key.
  When composition lands, revisit: either relax to ties-allowed with a
  documented tiebreak (origin module, then source location — both already
  known structurally), or scope rank-uniqueness per contributing module.

This makes cross-module multibindings the *motivating* case for
composition: aggregating contributions a host module can't see is a
thing DI users reach for (plugin registries, feature-module roundup),
and it falls out of the parse-set framing without new mechanism.

## Single-key (`BindingKey`) tracking rides here too

Today Wire tracks *multibinding* keys (it must — the type lives on the
key) but not single `BindingKey`s (the type lives producer-side, so the
compiler enforces it via generated `_check`s). That asymmetry is fine
single-module, but composition already forces Wire to discover keys
across the parse set — and once it tracks single keys too, they become
**self-describing** (type + identity from one reference), which unlocks
consistent single/multi key diagnostics and a value-level scope-input
key. Tracking single keys is a **behavioural change** (Wire would begin
diagnosing them), so it's deliberately bundled here — landed *before*
library behaviour expectations lock in, and on the same key-discovery
work composition needs anyway. See
[`ScopeAndKeyModelEvolution.md`](ScopeAndKeyModelEvolution.md).

## Summary

Composition is "the bootstrap now lives in / is consumed by a different
module," and it has a naming half and a visibility half:

| Concern | Single-module (today) | Multi-module (future) |
|---|---|---|
| Cross-type **naming** | bare references; own-module wins | `A::Logger` (SE-0491), qualified from origin-module metadata |
| Binding **visibility** | ≥ `internal` | ≥ `public` / `package` when cross-module-consumed |

Both are driven by the same structural per-module-discovery knowledge;
neither needs a Swift name-resolver. SE-0491 is the right tool for the
naming half — deferred because there's no composition yet, **not**
because it's useless. The toolchain floor it implies (consumers on
Swift 6.3+) is acceptable, since composition would itself be a new
feature.
