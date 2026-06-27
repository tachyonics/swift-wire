# Multi-module composition

> **Status:** in progress. M1_PLAN iteration 7 implements multi-module
> composition across sittings 7a–7g. Landed so far: single-`BindingKey`
> tracking (7a), origin-module metadata per binding (7b), and same-package
> cross-target source reading (7c). Remaining: external-package activation
> (7d), cross-library diagnostics (7e), SE-0491 naming + the cross-module
> visibility threshold (7f), the two-package integration gate (7g). This
> note records the design — including the **activation model** (below),
> cross-module **naming** (SE-0491 module selectors), and cross-module
> **visibility** — so those coupled decisions aren't relitigated.

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

## Activation is the dependency (a compile-time decision)

Activation is **compile-time**, not runtime. Wire's thesis is the static
graph: the plugin emits exactly one `_WireGraph` per target, so there is
one activation set per target — *not* a per-bootstrap-call choice — and
the plugin must know it before codegen to validate the whole graph and
collate multibindings. There is no runtime composition of separately
built module-graphs; the merged graph is flat, and "runtime is just
stored properties" holds across module boundaries.

**The surface is the manifest dependency list.** A library opts into
composition with a `_WireExports.swift` marker; a consumer activates it by
**depending on it** in the target's `dependencies`. The plugin reads the
target's *direct* dependencies, keeps the Wire-aware ones, and composes
them. No call-site `.activating(X.self)` directive (that was rejected: it
can't be a per-bootstrap decision, and SPM build-tool plugins can't take
custom per-target config anyway — the dependency list is the one
plugin-readable, SPM-name-checked manifest signal). One uniform rule:
**you activate the Wire-aware libraries your target directly depends on.**
Same-package and external are identical; transitive deps are *not*
auto-activated (you add them to your own `dependencies`, which you need to
`import` them anyway), so "transitive activation is explicit" falls out
for free.

**Depend = activate** collapses the importable-vs-activated distinction
for Wire-aware libraries. That's acceptable because it isn't the bad kind
of magic: the activated set is your direct, manifest-declared deps ∩
marker-shipping libraries (both halves visible and deliberate, nothing
transitive), and every conflict is *loud* — a library shadowing your
binding is a duplicate/ambiguity compile error, a missing dep is a
compile error. The only quiet behavior change is a library `@Contributes`
growing a collection you consume, which is the intended cross-module
multibinding feature and is visible in the `_WireGraph.json` dump. A way
to depend-without-activate (types-only) is a deferred refinement.

## Deferred optimizations (M6a / M6b)

Two perf optimizations are split out of M1; each keeps the surface
contract unchanged and lands when its cost is felt:

- **M6a — manifest-based discovery.** M1 re-parses dependency sources at
  the consumer's build; M6a has each library emit a per-library
  compile-time manifest of its bindings, which the consumer reads instead
  of re-parsing. The seam is the discovery-output model
  (`[DiscoveredBinding]` + key lists): M1 produces it by parsing, M6a by
  deserializing a manifest. Everything downstream (merge, graph, codegen,
  diagnostics) is unchanged — `originModule` is already per-binding and
  serializable, so it rides into the manifest exactly as stamped today.
  `_WireExports.swift` evolves from a presence-only marker into the
  manifest.
- **M6b — reachability pruning.** M1 eager-constructs *every* binding in
  the merged graph, including a library binding nothing reaches — so a
  large dependency costs all its singletons even when the consumer uses a
  few. M6b computes the bindings reachable from the home package's roots
  and strips the rest before codegen. The hard part is defining roots:
  the plugin sees `@Inject` edges but not external `graph.x` accesses, so
  `allowUnused` becomes "I'm a root, keep me" — valid **only** in the home
  package; a library's `allowUnused` is ignored for reachability, and a
  library binding is live iff reached from a home-package root. This
  changes the construction model (construct-reachable, not construct-all)
  and adds a small annotation cost (mark externally-pulled roots), so it's
  milestone-sized. Until it lands, an expensive library binding opts into
  deferral with `Lazy<T>`.

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
