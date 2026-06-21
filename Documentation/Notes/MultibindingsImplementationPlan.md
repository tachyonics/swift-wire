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
2. **BuilderKey emission shape.** ✅ **Done** — `BuilderKeyFoldSpike.swift`.
   **Finding:** the result-builder attribute is *not* supported on a
   closure, so the originally-planned IIFE form
   (`let x: R = { @Builder () -> R in a; b }()`) does **not** compile.
   The working shape is a `@resultBuilder`-annotated **local function**
   that captures the (already-constructed) contributor locals and is
   invoked at the binding site:

   ```swift
   @MiddlewareBuilder
   func fold() -> [any Middleware] {   // explicit R read from buildBlock
       auth                            // contributor locals, in order
       log
   }
   let chain = fold()
   ```

   Step 5 codegen emits this per `BuilderKey` aggregate. Local-function
   capture (rather than passing contributors as parameters) preserves
   each contributor's concrete static type into the builder, which
   matters for order-/type-sensitive builders.
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

### Step 1 — discovery: key-declaration scanner ✅ **Done**
- **Added** `DiscoveredMultibindingKey { keyReference, flavour,
  typeArguments, location, accessLevel }` + `MultibindingKeyFlavour`
  (`Discovery.swift`). Scans `static let X = CollectedKey/MappedKey/
  BuilderKey<…>(…)` and the explicit-annotation form; flavour + generics
  read from the annotation when present, else the constructor call.
- `keyReference` reconstructed as `(enclosingType…, member)` joined by
  `.` (string-matching discipline). `accessLevel` is the effective
  access (own modifier folded with enclosing types').
- Recognition lives in `MultibindingKeyScanning.swift` (free functions,
  to keep `BindingDiscovery` under the 1000-line `file_length` cap);
  the visitor supplies enclosing-scope context and appends to
  `SourceFileDiscovery.multibindingKeys`.
- **Test:** `MultibindingKeyDiscoveryTests` — 9 tests: each flavour's
  type args + reference; module-scope vs nested; annotation form;
  no-generics empty capture; effective-access folding; non-key /
  instance-level declarations ignored.
- **Ships:** discovered, unused.

### Step 2 — discovery: contributions ✅ **Done**
- **Added** `Contribution { keyReference, order?, mapKeyExpression?,
  location }` (`MultibindingTypes.swift`) as a **list** on *both*
  `DiscoveredScopeBoundType` and `DiscoveredProvider`, plus a uniform
  `DiscoveredBinding.contributions` accessor. Provider contributors
  (`@Provides @Contributes`) are in scope — the design already lists
  `@Provides` as a valid `@Contributes` host (Step 3), so capturing it
  here keeps Step 2/3 consistent.
- Parsing lives in `ContributionScanning.swift` (free functions, shared
  by all three producer paths); `withOrder:` parsed as `Int`, `atKey:`
  rendered verbatim. Tolerates the `@Wire::Contributes` selector.
- Spike #1 resolved: repeated `@Contributes` compiles, so multiple keys
  per contributor is a real list populated from multiple attributes.
- **Test:** `ContributionDiscoveryTests` — 8 tests: key reference,
  order, verbatim atKey, multiple contributions, `@Provides`
  property/function hosts, plain-producer-empty, `Wire::` selector.
- **Ships:** captured, unused.

### Step 3 — validation diagnostics ✅ **Done**
- All diagnostics in `MultibindingDiagnostics.swift`, all `.error`.
- **Bare `@Contributes`** (no producer macro) — `strayContributesDiagnostics`
  run by the visitor from `enterTypeDecl` (one choke point covering every
  type kind + extensions, producers `@Singleton`/`@Scoped`) and from the
  var/func visits (producer `@Provides`).
- **Module-wide** `multibindingContributionDiagnostics` run by WireGen in
  `collectCrossFileDiagnostics`: undeclared-key (the parse-set-widening
  rule), mixed `withOrder:` (all-or-none), duplicate `atKey:`, and
  duplicate `withOrder:` (ranks must be unique — keeps "ranked" a strict
  total order so codegen needs no tiebreak). The duplicate-`atKey:`/
  `withOrder:` checks share one helper. Output is location-sorted for
  stable build output. The overload set already enforces per-call
  argument validity, so only cross-declaration rules live here.
- Both paths feed `failIfAnyDiagnosticIsError`, so an `.error` fails the
  build before bad code is emitted.
- To make room, the shared syntax helpers (`makeSourceLocation`,
  `accessLevel`, `setterAccessLevel`) moved to `DiscoverySyntaxHelpers.swift`.
- **Test:** `MultibindingValidationTests` — 9 tests through real
  discovery + the module-wide function, asserting message + `.error`
  severity, with accepted-case negatives.
- **Ships:** diagnostics only.

### Step 4 — graph: aggregate node + fan-in ✅ **Done** (collected + mapped)
- **Added** `DiscoveredBinding.aggregate(DiscoveredAggregate)` + the
  `synthesizeAggregates` fan-in (`MultibindingFanIn.swift`):
  one aggregate per declared key, deps = its contributors (each an edge
  to the contributing binding).
- **Simpler than originally sketched.** The aggregate is a *synthesised
  single node* with an ordinary `(collectionType, keyReference)`
  identity — not a key-primary special case. So it flows through
  `partitionBindings` → `splitUniqueFromDuplicates` → `resolveDependencies`
  → `topologicalSort` **unchanged**: it's unique (one per key), co-
  contributors keep their own identities (no false duplicate), and a
  consumer's `@Inject(key) var x: [T]` dep already has identity
  `([T], key)` so it resolves to the aggregate **by ordinary
  `matchProducer`** — no consumer-dep rewrite, no special-casing. The
  earlier "key-primary + rewrite + outside-split" framing turned out
  unnecessary.
- `collectionType` derived producer-side: `[Element]` / `[Key: Value]`.
  **Builder deferred to Step 5** — its result type comes from the
  builder's `buildBlock`, which lands with codegen; builder keys
  synthesise no aggregate yet.
- Wired into `buildDependencyGraph(…, multibindingKeys:)`. **Not** wired
  into WireGen yet (no aggregate reaches codegen until Step 5);
  `constructionExpression`'s aggregate case is a guarded
  `preconditionFailure` until then.
- **Test:** `MultibindingFanInTests` — 7 tests: aggregate sorts after
  contributors (collected + mapped), consumer sorts after aggregate,
  co-contributors aren't duplicates, contributor-only-via-aggregate is
  constructed, empty aggregate still resolves, builder produces no
  aggregate yet.
- **Ships:** graph resolves; codegen next.

### Step 5 — codegen: the three forms ✅ **Done** (5a collected/mapped, 5b builder)
- Consumer-side `@Inject` overloads for `CollectedKey`/`MappedKey`/
  `BuilderKey` added (`Macros.swift`); `multibindingKeys`/`resultBuilders`
  wired into WireGen's default-graph build.
- `boundType`/`boundTypeReference` for aggregates = the collection type
  (`[Element]` / `[Key: Value]`) or, for builder, the result type read
  from `buildBlock`/`buildFinalResult` (`ResultBuilderScanning.swift`).
- `constructionExpression`: `[a, b] as [Element]` / `[k: v] as [K: V]`
  over the contributor locals (the `as` coercion unifies the
  heterogeneous concrete contributors). **Builder** can't be a single
  expression (the `@resultBuilder` attribute is unsupported on closures —
  spike #2), so `builderFoldLines` emits a `@Builder`-annotated *local
  function* capturing the contributor locals, plus its call.
- **No `_check` extension** — multibinding-keyed sites are excluded from
  the `BindingKey` `_check` codegen; aggregates self-check via the typed
  literal / fold and the consumer's typed `@Inject` overload. (The actual
  snag in 5a was the reverse: the `_check` *did* wrongly include them —
  fixed by the exclusion.)
- Empty builder (zero contributors) synthesises no aggregate — a
  zero-component fold has no well-defined result. Empty collected/mapped
  emit `[] as …` / `[:] as …`.
- To make room, `keyIdentifier` / `parameterName` joined the other shared
  helpers in `DiscoverySyntaxHelpers.swift`.
- **Test:** `MultibindingExample` (collected + mapped), `BuilderMultibinding-
  Example` (a `BuilderKey` folding into a concrete `Pipeline`), exercised
  by `BootstrapTests`; plus `ResultBuilderDiscoveryTests` and the builder
  cases in `MultibindingFanInTests`.
- **Ships:** feature works end-to-end (default graph; container/scope
  support added in the follow-up pass below).

### Step 5γ — non-default-graph support ✅ **Done**
A follow-up pass making multibindings work in containers and seed scopes,
atomically per partition.
- `synthesizeAggregates` runs **per partition** (default, each container,
  each seed scope) — `buildAllGraphs` passes the keys/result-builders to
  every partition build, and `orchestrateSeedScope` threads them into its
  `buildDependencyGraph`. A **used-key filter** (a key is built only where
  contributed-to or `@Inject`-consumed) stops declared-but-unused keys
  leaking empty aggregates into every partition.
- Each partition aggregates its **own** contributors. Within a container
  (key + contributors + consumer co-located) and within a seed scope
  (scope-bound contributors, which may read the seed) both work.
- **Keys are global identities, not container-owned.** A multibinding key
  is a name (consistent with `BindingKey`, whose declaration location Wire
  never tracks); *any* partition may contribute to it, and each partition
  builds its own aggregate. This is what enables the production/test
  container pattern — a module-scope (or library) key with a `Prod` and a
  `Test` container each providing their own contributors, selected at the
  entry point. A stray contributor (no consumer in its partition) becomes
  a **dead binding** (Step 6's visibility-gated warning), not a hard
  error. (An earlier cross-container *rejection* was tried and reverted —
  it wrongly treated keys as owned by their declaring container and broke
  this pattern.)
- **Per-partition cross-contributor diagnostics:** mixed `withOrder:`,
  duplicate `atKey:`, and duplicate `withOrder:` are checked *per
  partition*, not module-wide — contributions to the same key in different
  partitions form separate aggregates, so e.g. a `@Singleton` and a
  `@Scoped` may both use `withOrder: 2` for the same container key without
  conflict. Missing-key stays module-wide (a key is declared once).
- **Known limitation:** a borrowed singleton's contribution stays with the
  default graph (borrow bindings don't carry contributions), so a
  `@Singleton` contributor can't fan into a *scope's* aggregate
  (cross-scope read). Within-scope contributors work; the cross-scope case
  is deferred.
- **Test:** `ContainerMultibindingExample`, `SeedScopeMultibindingExample`
  (+ `BootstrapTests`); cross-container cases in `MultibindingValidationTests`.

### Step 6 — empty / dead diagnostics (5α inheritance)

**5α prerequisite ✅ Done** (it wasn't implemented — only the
declaration-too-private error was — so it had to be finished first):
- **3-i:** the general dead-binding warning logic (`DeadBindingDiagnostics.swift`)
  — first-order liveness via `matchProducer` (optional promotion honoured),
  visibility-gated (`internal`/`package` warn, `public`/`open` silent),
  generic templates and multibinding contributors skipped.
- **3-ii:** the `allowUnused:` silencer on `@Singleton`/`@Scoped`/`@Provides`
  (defaulted param), captured in discovery, honoured by the check. Also
  fixed `keyIdentifier(from:)` to read the positional arg (a labelled
  `allowUnused:` was being mistaken for a key).
- **3-iii:** turned on — `deadBindingDiagnostics(across:)` runs per
  *container* (scopes merged, so borrowed singletons stay live) and is
  wired into WireGen's diagnostics. The 25 integration-fixture roots
  (accessed via `graph.<name>`) are annotated `allowUnused: true`.

**Multibinding-specific ✅ Done:**
- `multibindingLivenessDiagnostics` — gated by the *key's* visibility and
  `allowUnused:`. A key consumed by nothing → **dead** warning; a key
  consumed in a partition with no contributors there → **empty** warning
  (consumer gets `[]`). `public`/`open` keys stay silent. Anchored at the
  key declaration; runs per partition (the production/test pattern, where
  a key is consumed in two containers each with its own contributor, stays
  silent).
- Silencer added to the key types: `CollectedKey/MappedKey/BuilderKey(
  allowUnused: true)` (defaulted init param), read by the scanner onto
  `DiscoveredMultibindingKey.allowUnused`.
- **Test:** `MultibindingValidationTests` (empty warns, dead warns, live
  silent, public silent, `allowUnused` silent, two-container pattern
  silent) + `EmptyMultibindingExample` bootstrapping to `[]`.

### Step 7 — validation gate ✅ **Done**
The `M1_PLAN.md` gate, met by the integration fixtures collectively rather
than one monolith (the incremental per-step fixtures already prove most of
it end-to-end):
- **Collected** `CollectedKey<any Service>`, 3 contributors, ordered +
  unordered — `ServiceMultibindingExample`: Alpha/Bravo/Charlie fan into a
  `ranked` key (`withOrder: 3/1/2` → `[bravo, charlie, alpha]`, a real
  3-way sort) and a `sourceOrdered` key (no `withOrder:` → source order),
  via repeated `@Contributes` (one set, two orderings). Asserted in
  `BootstrapTests`.
- **Mapped** `MappedKey<String, any Strategy>`, 2 contributors —
  `MultibindingExample` (`StrategyRegistry`); the duplicate-`atKey:`
  **compile-error** case is `MultibindingValidationTests.duplicateMapKeyIsError`
  (a fixture that errors can't also bootstrap).
- **Builder** `BuilderKey<…>`, 2 contributors + `withOrder:` —
  `BuilderMultibindingExample` (over-covers: concrete / collection /
  existential result shapes).
- **Empty visibility policy** (internal warns, public silent, silenceable)
  — `MultibindingValidationTests` (`emptyMultibindingWarns`,
  `publicEmptyKeyIsSilent`, `allowUnusedKeyIsSilent`) + `EmptyMultibinding-
  Example` bootstrapping to `[]`.
- **Ships:** iteration 5β gate met.

## Open unknowns (resolve as the relevant step lands)

- **`atKey:` non-literal keys** — enum cases / computed `Hashable` keys
  render textually into the `[K:V]` literal; confirm the rendering round-
  trips and that duplicate detection compares rendered expressions (two
  spellings of the same key value would slip the textual check — likely
  acceptable, note it).
- ~~**Provider contributors** — whether `@Provides @Contributes` is in
  5β.~~ **Resolved (Step 2):** in scope — contributions are captured on
  `DiscoveredProvider` too, uniform with `@Singleton`/`@Scoped`.
- **Aggregate inside `@Container` / seed scope** — per-scope `BuilderKey`
  storage rules (`BuilderKeyDesign.md` "Scope crossings"); the fan-in
  pass must respect scope partitioning, and cross-container contribution
  is already rejected (Step 3).
