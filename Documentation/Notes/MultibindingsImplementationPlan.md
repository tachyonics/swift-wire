# Iteration 5β — multibindings implementation plan

> **Status:** working implementation plan for iteration 5β. The *what*
> and the validation gate live in [`M1_PLAN.md`](../../M1_PLAN.md); the
> design depth lives in [`BuilderKeyDesign.md`](BuilderKeyDesign.md),
> [`VisibilityModel.md`](VisibilityModel.md) (dead/empty policy), and
> [`MultiModuleComposition.md`](MultiModuleComposition.md) (cross-module
> key references). This note is the *how* — the build order. Each step is
> sized to land as one green, lint-clean, shippable commit.

## The model in one paragraph

`@Contributes` is a marker peer macro (emits nothing, like `@Provides`);
its typed `to:` parameter carries flavour/arg validity via overload
resolution. Discovery reads key declarations (`CollectedKey` /
`MappedKey` / `BuilderKey` `static let`s) uniformly for all three
flavours — producer-side type authority, forced by BuilderKey's need for
a concrete return type in the no-opaque slice. A contributor keeps its
own per-type binding identity *and* carries a `Contribution` list; a
fan-in pass groups contributions by key, matches each to its key
declaration, and synthesises an **aggregate node** whose deps = the union
of its contributors' deps. Codegen emits the aggregate as a literal over
contributor locals (`[Element]` / `[K:V]` / `@resultBuilder` fold), which
is self-checking at the construction site — so the single-binding
`_check<T>` scaffolding does **not** extend to multibindings; the lone
codegen-time diagnostic is duplicate `atKey:` (a runtime trap in a dict
literal, hence raised at plugin time).

## De-risk spikes (do these first, before Step 0 lands)

Cheap throwaway checks that retire the assumptions the plan leans on:

1. **Repeated `@Contributes`.** Confirm Swift accepts the same attached
   peer macro applied multiple times to one declaration (multiple keys
   per contributor). If it doesn't, the surface changes to a variadic
   `to:` or distinctly-named attributes — a Step 0 decision, not a
   refactor later.
2. **BuilderKey emission shape.** Hand-write the IIFE form
   (`let x: R = { @Builder () -> R in a; b }()`) against a real
   `@resultBuilder` and confirm it compiles with the explicit concrete
   `R` and that the result-builder transform fires on the statement
   list. This is the BuilderKey-minus-opaque crux; validate the literal
   before building codegen for it. Capture it as an integration example
   (mirrors `WeakLetExample.swift` / `UnownedExample.swift`).
3. **`buildBlock` return-type extraction.** Decide which signature Wire
   reads when a builder has overloaded `buildBlock` / a `buildFinalResult`
   — pick the rule (prefer `buildFinalResult` return when present, else
   `buildBlock`) and note it; don't discover it mid-codegen.

## Build order

### Step 0 — surface: key types + `@Contributes` macros (no behaviour)
- **Add** `CollectedKey<T>`, `MappedKey<K, V>`, `BuilderKey<B>` phantom
  marker structs (`Sources/Wire/`, next to `BindingKey.swift`).
- **Add** the `@Contributes` overload set as marker peer macros returning
  `[]` (`Sources/Wire/Macros.swift` + a `ContributesMacro` in
  `WireMacrosImpl` mirroring `ProvidesMacro`). Recognise the `Wire::`
  selector like the other macros (`wireMacroNameMatches`).
- **Test:** macro-expansion tests (expands to nothing); mis-shaped calls
  (`atKey:` on a `CollectedKey`, missing `atKey:` on a `MappedKey`) fail
  to compile — assert via the overload set, not the plugin.
- **Ships:** compiles, no graph behaviour yet.

### Step 1 — discovery: key-declaration scanner
- **Add** `DiscoveredMultibindingKey { keyReference, flavour, typeArgs,
  location, accessLevel }` and scan `static let X = <Flavour><…>("name")`
  declarations. Reconstruct `keyReference` as `(enclosingType, member)`
  for string-matching, same discipline as today's keyed bindings.
- Thread into `SourceFileDiscovery` (a new merged-module-wide collection).
- **Test:** `DiscoveryTests` — each flavour's type args captured; nested
  / extension declarations resolve to the right reference string.
- **Ships:** discovered, unused.

### Step 2 — discovery: contributions
- **Add** `Contribution { keyReference, order?, mapKeyExpression?,
  location }` as a **list** on `DiscoveredScopeBoundType` (and
  `DiscoveredProvider` if `@Provides @Contributes` is in scope).
- Parse `@Contributes(to:withOrder:atKey:)`, rendering `atKey:` textually.
- **Test:** `DiscoveryTests` — order/atKey captured; multiple keys per
  contributor (pending spike #1).
- **Ships:** captured, unused.

### Step 3 — validation diagnostics
- Bare `@Contributes` (no `@Singleton`/`@Scoped`/`@Provides`) → diagnostic.
- `@Contributes(to: X)` where `X` ∉ parse-set key declarations →
  missing-key diagnostic (the cross-module-widening rule).
- Cross-contributor rules the overloads can't see: `withOrder:` mixing
  (all-or-none), duplicate `atKey:` on a `MappedKey`.
- **Test:** `DiagnosticGalleryTests`.
- **Ships:** diagnostics only.

### Step 4 — graph: aggregate node + fan-in
- **Add** the aggregate node (new `DiscoveredBinding` case or sibling
  node form) carrying flavour + declared type (from Step 1) and ordered
  contributors. Identity is **key-primary**, outside
  `splitUniqueFromDuplicates`.
- Fan-in pass: group `(binding, contribution)` by key, match to the key
  declaration, add aggregate→contributor edges (deps = union), rewrite
  consumer deps referencing a multibinding key to point at the aggregate.
- **Test:** `GraphTests` — aggregate topo-sorts after all contributors;
  co-contributors raise no false duplicate; contributor reachable only
  via aggregate stays live.
- **Ships:** graph resolves; codegen next.

### Step 5 — codegen: the three forms
- `boundTypeReference` for aggregates = declared collection/result type
  (the BuilderKey read-point for the `_WireGraph` stored property).
- `constructionExpression`: `[Element]` literal / `[K:V]` literal /
  IIFE `@resultBuilder` fold — all over contributor locals, ordered.
- `identifierName` key-primary for aggregates; symmetric on the consumer
  dep so resolution lands.
- **No** `_check` extension; rely on self-checking literals + typed
  consumer calls. Duplicate `atKey:` already guarded in Step 3.
- **Test:** `IntegrationTests` fixtures exercising each form end-to-end.
- **Ships:** feature works end-to-end.

### Step 6 — empty / dead diagnostics (5α inheritance)
- Empty multibinding (consumer exists, zero contributors) → visibility-
  driven warn, silenceable via 5α's silencer. Dead key (no consumer) via
  the existing dead-binding path. Public stays silent.
- **Test:** `DiagnosticGalleryTests` — `internal` empty key warns,
  `public` stays silent.

### Step 7 — validation gate
- The `M1_PLAN.md` test app: 3 `CollectedKey<any Service>` contributors
  (ordered + unordered), 2 `MappedKey<String, Strategy>` (incl. the
  duplicate-`atKey:` error case), 2 `BuilderKey<MiddlewareBuilder>` with
  real result-builder constraints + `withOrder:` sequencing, plus the
  empty-multibinding visibility fixture.
- **Ships:** iteration 5β gate met.

## Open unknowns (resolve as the relevant step lands)

- **`atKey:` non-literal keys** — enum cases / computed `Hashable` keys
  render textually into the `[K:V]` literal; confirm the rendering round-
  trips and that duplicate detection compares rendered expressions (two
  spellings of the same key value would slip the textual check — likely
  acceptable, note it).
- **Provider contributors** — whether `@Provides @Contributes` is in 5β
  or `@Singleton`/`@Scoped`-only for the first cut (affects whether Step 2
  touches `DiscoveredProvider`).
- **Aggregate inside `@Container` / seed scope** — per-scope `BuilderKey`
  storage rules (`BuilderKeyDesign.md` "Scope crossings"); the fan-in
  pass must respect scope partitioning, and cross-container contribution
  is already rejected (Step 3).
