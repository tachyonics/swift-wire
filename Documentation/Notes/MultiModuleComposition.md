# Multi-module composition

> **Status:** in progress. M1_PLAN iteration 7 implements multi-module
> composition across sittings 7a–7g. Landed so far: single-`BindingKey`
> tracking (7a), origin-module metadata per binding (7b), same-package
> cross-target source reading (7c), direct-dependency activation (7d),
> cross-library validation + origin-module-aware ambiguity (7e), and the
> cross-module visibility threshold + cross-module key references (7f).
> SE-0491 `::` naming is **deferred** out of 7f (see "Naming" below for
> why). Remaining: the two-package integration gate (7g), which also
> exercises 7d's external `.product` path and 7e's missing-transitive-
> activation hint end-to-end. This note records the design — the
> **activation model**, cross-module **naming** (deferred), and cross-module
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

Guidance for that case: a multibinding key is a *global extension point*,
so injecting a key you don't own means any activated package may
contribute to it (the collection grows with your dependency set). If you
need a known, complete contributor set, declare the key in a target you
control — most strongly the leaf app target, which nothing depends on, so
only your own code can reach it. (Order-sensitive collections also need
`withOrder:`; cross-module element order is otherwise unspecified — see
the `withOrder:` cross-module note below.)

### The marker is detection-only — and can't be auto-generated

`_WireExports.swift` does exactly one thing: signal Wire-awareness so a consumer
re-parses (later: references) a direct dependency. It is **not** a future readable
export interface, and it **can't be plugin-generated** — a consumer's plugin reads a
dependency's committed *sources*, never its plugin *outputs*. Spike-1's check (4)
(inspecting which plugins a dependency applies) is unavailable, and a 2026-07 re-check
confirmed the consequence directly: emitting `_WireExports.swift` from the contributor
plugin instead of hand-declaring it made the dependency **invisible** to the consumer's
`sourceFiles` scan — the build succeeded but the dependency's bindings silently dropped
out of the graph. So there is no plugin-generated export *file* a consumer can read
(see *M7a* below); composition works by re-parsing committed sources for the data and
referencing the dependency's public symbols **by derivable name** (compiler-linked) —
which is exactly what the `@Factory` factory-lift does (`_WireFactory_<key>` is public
in the template's module; the consumer emits a reference resolved at compile time).

**Retirement plan.** The marker's whole job is replaceable by a signal the consumer
*can* read: **a direct dependency that depends on the `Wire` product**. That drops the
hand-declared file — a contributor applies `WireContributorPlugin` only when it declares
`@Factory` templates (a missing plugin is a loud, local compile error, `cannot find type
'_WireFactory_<key>'`); a pure-`@Singleton` contributor declares nothing. The catch is
that the marker currently also *bounds* what composes, so its removal is **coupled to
reachability pruning (M7b)** — the prerequisite, not a nicety: without a bound, every
direct Wire-dependency's bindings are pulled in and eagerly constructed, so an
incidentally-scanned binding with a consumer-unresolvable dep would break; reachability
strips the unreachable before resolution. That work's bulk lands with **M5.4
(request-scoped controllers)**. A public-keyed multibinding is the documented
non-prunable exception (a public collection key can gain contributors outside the
analysed graph, so it survives with no local consumer — the same rule as a public unused
binding).

## Deferred optimizations (M7a / M7b)

Two perf optimizations are split out of M1; each keeps the surface
contract unchanged and lands when its cost is felt:

- **M7a — manifest-based discovery.** M1 re-parses dependency sources at
  the consumer's build; M7a has each library emit a per-library
  compile-time manifest of its bindings, which the consumer reads instead
  of re-parsing. The seam is the discovery-output model
  (`[DiscoveredBinding]` + key lists): M1 produces it by parsing, M7a by
  deserializing a manifest. Everything downstream (merge, graph, codegen,
  diagnostics) is unchanged — `originModule` is already per-binding and
  serializable, so it rides into the manifest exactly as stamped today.
  **Constraint (2026-07):** the manifest can't be a per-build *plugin
  output* — the consumer can't read another target's plugin outputs (see
  *The marker is detection-only* above). So M7a's manifest is either a
  **committed** artifact the consumer re-reads, or the library exposes its
  contribution as **public symbols** the consumer references by name
  (compiler-linked) rather than a file it parses — the direction the
  `@Factory` factory-lift already takes. `_WireExports.swift` doesn't
  "become the manifest"; it's retired (detection moves to the Wire-product
  dependency).
- **M7b — reachability pruning (bulk lands with M5.4).** M1 eager-
  constructs *every* binding in the merged graph, including a library
  binding nothing reaches — so a large dependency costs all its singletons
  even when the consumer uses a few. Beyond the perf win, reachability is
  the **prerequisite for retiring the marker** (it's what bounds
  auto-composition once opt-in is manifest-derived). M7b computes the
  bindings reachable from the home package's roots
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

> **Status: deferred past 7f / M1.** Working it through during iteration 7
> surfaced that `::` is *not* "mechanical once origin-module metadata
> exists." Two bindings both named `Logger` from different modules have the
> **same** textual `BindingIdentity` (`base: "Logger"`), so today they're a
> duplicate/ambiguity (7e names the conflicting modules; resolve with a
> key) — for `A::Logger` and `B::Logger` to *coexist* the identity model
> would have to incorporate the origin module, which also changes the
> duplicate check and consumer-side matching (does bare `@Inject var x:
> Logger` match `A::Logger`?). The residual genuine clash — a binding's
> simple name colliding with a *non-binding* type another activated module
> exports — Wire can't even detect structurally (it sees bindings, not all
> exports), so the only robust fix is *always-qualify every reference*,
> which churns all codegen output and still can't qualify nested generic
> arguments. Meanwhile the common case — non-clashing foreign types —
> already works via 7c's `import <module>`. So `::` gets its own design
> pass (identity model + matching + generics) when an adopter hits the
> clash; until then it's a known limitation (a binding whose simple type
> name collides with another activated module's exported type can produce
> an ambiguous reference in generated code — rename, or disambiguate with a
> key). The design direction below is retained for that pass.

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
  **M1 decision (7f): keep the global-uniqueness rule** — a cross-module
  duplicate `withOrder:` is still an error (it already fires on the merged
  set), and cross-module *unordered* collection order is unspecified, so
  an order-sensitive cross-module collection must use `withOrder:`. The
  coordination relief — relax to ties-allowed with a documented tiebreak
  (origin module, then source location, both known structurally) or scope
  rank-uniqueness per contributing module — is deferred until an adopter
  hits it with independently-authored modules sharing a key.

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
