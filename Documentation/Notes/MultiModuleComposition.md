# Multi-module composition

> **Status:** forward-looking design. Multi-module composition is not
> implemented — Wire is per-module today (the build plugin runs WireGen
> per target; `_WireGraph` is generated into, and references types
> within/imported by, that one module). This note records the design
> direction so two coupled decisions — cross-module **naming** (SE-0491
> module selectors) and cross-module **visibility** — aren't relitigated
> when composition is taken on. Nothing here is built yet, and nothing
> needs building until there's a composition feature to consume it.

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
