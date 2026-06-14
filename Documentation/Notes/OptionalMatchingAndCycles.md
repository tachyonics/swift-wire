# Optional Matching and Cycle Breaking

Pins two entangled design decisions:

1. **How Wire matches a dependency's type to a producer with respect to
   optionality** — exact identity plus Swift's *asymmetric* optional
   promotion, and nothing else (no implicit "absent → nil").
2. **The cycle-breaking taxonomy** — `weak var` (the breaker; `T?` or
   `T!`), `weak let` (lifetime-only, *not* a breaker), and `Lazy`
   (deferral, *not* a breaker) — and why, under ARC, `weak` is the only
   leak-free breaker.

The two are entangled because `weak`'s storage is forced to `T?` by the
language, so the cycle story is the single largest consumer of the
optional-matching rule.

Companion to [`VisibilityModel.md`](VisibilityModel.md),
[`WeakInjectionSupport.md`](WeakInjectionSupport.md), and
[`LazyTypeSupport.md`](LazyTypeSupport.md). This note supersedes the
ad-hoc optional handling those describe (the discovery-time `?`-strip)
with a single resolver rule — see *Implementation* below.

---

## Part 1 — Type matching and optionals

### The invariant

> A producer of `U` satisfies a binding of `V` **iff `U` is assignable
> to `V` in Swift.**

For non-optional types that is exact spelling identity (Wire's existing
structural string match). For optionals it is Swift's implicit
promotion, which is **directional**:

| Producer `U` | Binding `V` | Satisfies? | Why |
|---|---|---|---|
| `T`  | `T`  | ✅ | exact |
| `T`  | `T?` | ✅ | **promotion** — a non-optional fills an optional slot, exactly as `let x: T? = aT` |
| `T?` | `T`  | ❌ | the asymmetry — you cannot silently force-unwrap; `let x: T = aTOptional` is an error |
| `T?` | `T?` | ✅ | exact |

This is the rule every Swift developer already carries in their head for
parameter passing and assignment. Wire mirrors it rather than inventing
a parallel notion of compatibility.

### Normalization

- **`T!` (IUO) normalizes to `T?`** before matching, as the language
  treats it. Implementation detail: `T!` is a *different* syntax node
  from `T?` — `ImplicitlyUnwrappedOptionalTypeSyntax` vs
  `OptionalTypeSyntax` — so the normalization must strip **both**.
  Today's weak `?`-strip only handles `OptionalTypeSyntax`, so a
  `weak var x: T!` would currently miss the `T` producer; the promotion
  work must cover the IUO node too. This is what makes `weak var x: T!`
  (below) resolve.
- **One level of optionality.** `T??` is not special-cased; document it
  as "strip at most one `?`." Nested optionals effectively never appear
  in a binding type and are not worth the matrix.
- Everything else matches by spelling. Typealias / collection-sugar
  normalization (aliases, `[Int]` vs `Array<Int>`) is a **separate,
  pre-existing limitation** of the structural matcher and is explicitly
  **out of scope** here. Optional promotion is *not* normalization: `T`
  and `T?` are different types with potentially different intent, whereas
  those are spelling synonyms for the *same* type. Conflating the two
  would be a category error. (Module-qualified forms — `MyModule.Logger`,
  SE-0491 `Module::Logger` — are *disambiguators*, not synonyms, and
  belong to multi-module composition, not normalization. See
  [`MultiModuleComposition.md`](MultiModuleComposition.md).)

### Ambiguity: a `T?` consumer with both candidates is an error

When a consumer asks for `T?` and, **under the same key**, both an exact
`T?` producer and a promotable `T` producer exist, Wire does **not**
silently rank one over the other. It is a **binding-ambiguity error**,
and the user disambiguates with keys — the same mechanism that resolves
any duplicate binding.

This deliberately diverges from Swift's own overload ranking, which
silently prefers the exact match. Swift *must* pick — it cannot error on
every promotable overload without breaking the language. Wire is under
no such constraint: it is a build-time graph validator whose job is to
surface ambiguity, and it already errors on duplicate bindings. So Wire
mirrors Swift for *what satisfies what* (the assignability direction in
the table above) but **not** for *tie-breaking* — there the
explicit-over-implicit posture wins, consistent with the rest of this
note. No silent precedence the user has to memorize.

Detection is **consumer-driven** — the collision is a resolution
ambiguity at the `T?` site, not a duplicate *registration* (`T` and `T?`
are distinct keys, so there is no duplicate to catch producer-side):

- The error fires only when resolving a `T?` dependency that finds both
  a `(key, T?)` and a `(key, T)` producer.
- A `T` consumer is never ambiguous — the asymmetry means a `T?`
  producer cannot promote *down* to it.
- Two producers with no `T?` consumer are not ambiguous; the `T?`
  producer is simply its own (possibly dead) binding, covered by the
  existing dead-binding warning.
- Keys partition the space, and promotion still applies *within* a
  matched key (`@Inject(key: K) x: T?` resolves against
  `@Provides(key: K) -> T` by promotion). The ambiguity arises only when
  two producers share one key.

### What Wire deliberately does NOT do

**No "optional dependency" semantics.** A `V?` binding with no producer
is a **missing-binding error**, never a silent `nil`. `nil` enters the
graph *only* through an explicit `@Provides` that returns `T?`.

This is the explicit-over-implicit stance. Contrast:

- **Micronaut / Koin** resolve an absent dependency to `nil`/`empty()`
  automatically. Wire does not — absence is always an error.
- **Dagger** has a first-class "binding may be absent → empty optional"
  concept (`@BindsOptionalOf`). Wire does not build this either; we have
  no notion of an absent-but-tolerated binding. The only source of
  `nil` is a producer that explicitly makes one.

So `T?` is a perfectly legitimate, *intentional* binding: a
`@Provides func currentUser() -> User?` is a real optional producer, and
a `@Inject let user: User?` matches it exactly. "Be explicit" means we
never *fabricate* an optional from a missing producer — not that
optionals are banned.

### Why promotion (and why it is novel)

Mirroring the language is the obvious choice, yet no DI framework does
it — which is worth understanding so this reads as deliberate, not
naive (see *Prior art*). The short version:

- Wire's two closest peers, **Needle** and **Weaver**, are
  string/structural matchers exactly like Wire, and both keep `T` and
  `T?` strictly distinct with no promotion. They got away with it only
  because **neither has weak post-construct injection** — nothing in
  those frameworks forces `T?` onto a user. Wire has weak, so the
  language forces the question on us.
- The one framework that felt the same pull, **Swinject**, unifies
  `T`/`T?`/`T!` *symmetrically* (a `T?` registration can satisfy a `T`
  request) — which is unsafe (it hands a possibly-`nil` value to a
  non-optional consumer). Wire's **asymmetric** promotion forbids
  exactly that. So we are not copying the language blindly; we are
  taking the *safe direction* of its rule.
- Promotion **subsumes the weak `?`-strip** into one general resolver
  rule. Without it, `weak var x: T?`, `weak var x: T!`, and `weak let`
  would each need their own optional handling. With it, there is one
  rule and no per-feature special cases.

### Implementation

Promotion lives in the **graph resolver** (`Graph.swift`, the
dependency→producer matching), **not** in discovery.

This **replaces** the current discovery-time `?`-strip for weak
(`InjectMemberDiscovery.propertyAssignmentInjection`, which unwraps
`OptionalTypeSyntax` so a `weak var x: T?` resolves against a `T`
producer). Under the new model:

- Discovery keeps the **real declared type** (`T?` / `T!`) end to end —
  type identity stays honest.
- The resolver applies promotion when matching. `weak var x: T?`,
  `weak var x: T!`, `weak let x: T?`, and `@Provides -> T?` all flow
  through the same rule.

This is a behavior change to existing weak handling; the weak strip
tests move from "discovery emits `T`" to "resolver matches `T?`/`T!`
against a `T` producer."

### Diagnostics

| Situation (all "same key") | Outcome |
|---|---|
| `T?` consumer, only a `T` producer | resolves via promotion — no diagnostic |
| `T?` consumer, only a `T?` producer | resolves exact — no diagnostic |
| `T?` consumer, **both** a `T?` and a `T` producer | **ambiguity error** — disambiguate with a key (see above) |
| `T?` consumer, neither `T` nor `T?` producer | missing-binding, listing *both* `T` and `T?` as candidate spellings |
| `T` consumer, only a `T` producer | resolves exact — no diagnostic |
| `T` consumer, only a `T?` producer | missing-binding with the asymmetry hint: a `T?` producer exists but can't satisfy a non-optional `T`; add a `T` producer or make the consumer `T?` |
| `T?` producer with no `T?` consumer | existing dead-binding warning — not new here |

---

## Part 2 — Cycle breaking

### Two cycles, two mechanisms

A reference cycle in a DI graph is really *two* cycles. The second is
**Swift-specific**, and conflating them is the trap most of the
cross-language prior art falls into:

1. **The construction-order cycle** — "can the graph even be built?" A
   needs B at init, B needs A at init: neither can go first. Severed by
   **post-construct delivery** (a *timing* property): construct one end
   without the back-edge, deliver the back-edge after. This cycle is
   **universal** — every DI framework, in every language, faces it.
2. **The reference-counting cycle** — "does it leak?" A retains B, B
   retains A: under ARC neither ever reaches refcount zero. Severed by a
   **weak / unowned** back-edge (a *retain* property). This cycle is
   specific to **refcounted memory** (ARC, Objective-C, C++
   `shared_ptr`). **GC languages do not have it** — a garbage collector
   reclaims a strong reference cycle, so Java/Kotlin DI (Dagger, Guice)
   only ever faces cycle #1.

The axes are orthogonal, and **in Swift a usable cycle-breaker must
sever both**. That single fact — together with the fact that cycle #2 is
ours to worry about and Dagger's is not — determines the whole taxonomy,
and is exactly why Dagger's strong lazy/provider indirection (perfectly
safe under GC) does not port to ARC.

### The taxonomy

| Form | Severs construction cycle? (timing) | Severs retain cycle? (weak) | Usable breaker? |
|---|---|---|---|
| `@Inject weak var b: B?` / `b: B!` | ✅ post-construct | ✅ weak | **yes — the breaker** |
| `@Inject weak let b: B?` | ❌ init edge | ✅ weak | no — cycle-checked |
| `@Inject unowned (let/var) b: B` | ❌ init edge | ✅ unowned | no — cycle-checked |
| strong post-construct (`@Inject func` into strong storage) | ✅ post-construct | ❌ strong | no — *builds, then leaks* |
| `Lazy<B>` (produced) | ❌ init edge | n/a | no — cycle-checked |

The distinctions:

- **`weak var` — the breaker.** It is the *only* form that severs both
  cycles: post-construct delivery breaks construction order, and `weak`
  breaks the retain cycle. This is the canonical delegate / parent
  back-reference, and the reason Wire chose post-construct delivery over
  Dagger-style lazy indirection — one keyword the user already writes
  does both jobs, with no wrapper type in the property. It pays the
  post-construct mutation tax (must be `var`, must be ≥`internal`,
  setter restrictions) — see [`VisibilityModel.md`](VisibilityModel.md).

  **Non-optional access:** if `weak var x: B?` ergonomics grate (you
  want `x.foo()`, not `x?.foo()`), use `weak var x: B!` — the IBOutlet
  idiom. Same weak storage and the same break of both cycles; the IUO
  just implicit-unwraps on access and **traps if touched after the
  target deallocates**. It is the user's contract ("alive when I touch
  it"). Wire handles it via the same weak path once the matcher
  normalizes `T!` (see Part 1, *Normalization*). (For a non-optional
  non-owning reference that is *constructor-injected* rather than a
  post-construct breaker, see `unowned` below — a different shape.)

- **`weak let` (SE-0481) — non-owning lifetime *only*, NOT a breaker.**
  It severs the retain cycle (weak) but **not** the construction cycle:
  a `weak let` is delivered at *init* (it cannot be reassigned
  post-init), so the referent must already exist when the host is
  constructed — an ordinary init-time edge that **participates in cycle
  detection**. It is the language finally being able to express weak's
  *retain* property decoupled from the *timing* property. Wire treats it
  as a constructor-injected `T?` dependency (resolved via promotion
  against the `T` producer).

  **No blanket warning.** An acyclic `weak let` is a legitimate
  non-owning, immutable reference (exactly the case SE-0481 encourages
  for `Sendable`) — warning on every declaration would be noise, and
  discovery can't see cycles anyway. Instead, the guidance rides the
  cyclic-dependency error: when a `weak let` edge *closes a cycle*, the
  cycle error carries a `note:` at that edge —

  > `'x'` is an `@Inject weak let` that closes this cycle; change it to
  > `weak var` to break the cycle (the bootstrap then delivers it
  > post-construct, off the init-time edge).

  So the dangerous case gets precise, actionable guidance exactly when
  the build fails, and the benign case is silent. The dependency is
  flagged (`DependencyParameter.nonOwningInitForm`) so cycle reporting can
  spot the edge; the note is emitted only for the edge actually in the
  cycle, not for a `weak let` that merely points at a cycle member.

- **`unowned` — non-owning, non-optional, also NOT a breaker.** The
  non-optional sibling of `weak let`: `@Inject unowned let/var b: B` is a
  non-owning reference (severs the retain cycle) but **must** be delivered
  at *init* — non-optional storage can't be left empty and filled
  post-construct, so unlike `weak var` it cannot be deferred. So it's a
  constructor-injected init-time edge that **participates in cycle
  detection**, sharing the `weak let` cycle-note machinery (the note names
  the form). Use it for a non-owning reference to a target the container
  keeps alive, when you want bare non-optional access and accept a
  trap-on-stale-access contract (vs `weak let`'s graceful `nil`). It needs
  no special handling beyond the cycle flag — `unowned` isn't `weak`, so
  it already flows through discovery and the macro as an ordinary
  constructor-injected dependency.

- **Strong post-construct (the `Ref`-box idea) — NOT a breaker.** A
  strong reference delivered post-construct severs the *construction*
  cycle (the graph builds) but leaves the *retain* cycle fully intact —
  it merely relocates the leak from "can't build" to "won't deallocate."
  For app-lifetime root singletons the retain cycle is benign (they live
  for the process), but there `weak var` already works *and* is cleaner:
  the container retains both ends, so the weak back-reference never goes
  `nil`. For **scoped / bounded-lifetime** instances it is an outright
  leak that survives scope teardown (`weak` unwinds cleanly; strong does
  not). So Wire has **no owning cycle-breaker**: ownership lives in the
  container, not in object-to-object back-edges, and `weak` is the
  breaker. (An earlier draft proposed a `Ref<T>` set-once box for this;
  it was dropped once the retain cycle became clear.)

- **`Lazy` — deferral of construction timing, NOT a breaker.** `Lazy<T>`
  defers *when* `T` is built, but its factory must capture its
  dependencies at creation time — to break A↔B its factory would have to
  capture a not-yet-constructed instance, which is impossible. So
  `Lazy` edges still participate in cycle detection. See
  [`LazyTypeSupport.md`](LazyTypeSupport.md).

### Why post-construct, not construction-time (Dagger's `Provider`/`Lazy`)

The dominant *compile-time* cycle-breaker in the field is lazy/provider
indirection (Dagger makes a `Provider<T>`/`Lazy<T>` edge the only legal
cycle edge). Wire deliberately chose **post-construct delivery** instead
(the Swinject/Cleanse camp). The justification:

- **Dagger's indirection relies on GC.** A `Provider<T>`/`Lazy<T>` holds
  its target *strongly*; Java/Kotlin's garbage collector reclaims the
  resulting cycle. Ported to **ARC**, a strong deferred reference has
  exactly the retain-cycle problem of the strong-post-construct box
  above — it would leak. So construction-time-vs-post-construct is a
  *timing* choice; it does **not** confer leak-safety. In ARC the only
  leak-free break is a `weak`/`unowned` edge, *regardless* of timing.
- Given that, **post-construct `weak` is the natural fit**: it delivers
  the weak edge (retain-safe) at the moment that also breaks
  construction order (timing). For the delegate case the back-edge had
  to be `weak` anyway, so one mechanism covers both — no `Provider<Foo>`
  wrapper leaking into the consumer's type.

One honest framing for future readers: the `weak var` tax (≥`internal`,
setter restrictions, `var`-not-`let`) is largely **irreducible**, not a
contingent design choice. Leak-free cycle-breaking in ARC requires a
`weak` edge, and a `weak` edge that also breaks construction order must
be delivered *post-construct* — which is what forces the mutation and
hence the visibility surface. The tax is the cost of ARC + cycles, paid
once in `weak var`.

---

## Part 3 — What ships now vs deferred

### Ship now

1. **Optional promotion in the resolver** (Part 1), replacing the
   discovery-time weak `?`-strip, handling both `T?` and `T!`, plus the
   asymmetry and ambiguity diagnostics.
2. **`weak let` handling** — constructor-injected `T?` dependency
   (resolved via promotion), cycle-participating, silent when acyclic,
   with a `note:` on the cyclic-dependency error when it closes a cycle.
   Rides on (1), so it needs no per-feature strip.
3. **`weak var x: T!`** — falls out of (1) for free once the matcher
   normalizes the IUO node; document it as the non-optional-access
   spelling of weak injection (with the trap-on-stale-access caveat).
4. **`unowned` injection** — constructor-injected, non-owning,
   non-optional reference (the non-optional sibling of `weak let`, *not* a
   breaker — non-optional storage can't be deferred). Already flows
   through discovery + the macro as an ordinary dependency; only adds the
   cyclic-dependency `note:`, shared with `weak let` via
   `DependencyParameter.nonOwningInitForm`.

### Deferred (prove the need first)
- **Construction-time / lazy-as-cycle-breaker.** Offers no leak-safety
  advantage under ARC (see Part 2) and needs `weak`/`unowned` anyway, so
  there is no compelling version of it. Deferred indefinitely.
- **Typealias / collection-sugar normalization** (aliases, `[Int]` vs
  `Array<Int>`). Pre-existing structural-matcher limitation, orthogonal
  to this note.
- **Multi-module composition** — cross-module name disambiguation via
  SE-0491 module selectors, plus the cross-module visibility threshold.
  Not a normalization concern (module selectors disambiguate; they don't
  normalize). See [`MultiModuleComposition.md`](MultiModuleComposition.md).

---

## Prior art (so the choices read as deliberate)

**Optional matching.** Compile-time DI is overwhelmingly strict-distinct
with explicit opt-in: Dagger keys `T` and `Optional<T>` separately and
requires `@BindsOptionalOf` (no promotion); Needle/Weaver/Factory/
Resolver keep them distinct via separate APIs/wrappers. No framework, in
any language, re-implements the language's asymmetric promotion in its
own resolver — Swinject comes closest but unifies *symmetrically*
(unsafe). Wire mirroring Swift's *asymmetric* promotion is novel but is
(a) the safe direction and (b) the same string/structural matcher its
peers use; the peers avoided the question only because they lack weak
injection.

**Cycle breaking.** The dominant compile-time breaker is lazy/provider
indirection (Dagger: a `Provider`/`Lazy` edge is the only legal cycle
edge) — but Dagger leans on GC to reclaim the strong cycle, an option
ARC does not have. Post-construct delivery is the *runtime* container
pattern (Swinject's `initCompleted`, where the back-edge is documented
as `weak` for leak-safety). Among Swift compile-time peers, Needle has
no cycle detection at all (its unidirectional component tree makes scope
cycles inexpressible) and Weaver *forbids* general cycles (detect +
error, self-reference only). Wire sits in the post-construct camp
(precedent: Square's **Cleanse**, per
[`WeakInjectionSupport.md`](WeakInjectionSupport.md)), and — correctly
for ARC — treats `weak` as the leak-free breaker rather than a strong
deferred reference.

**Language proposals.** [SE-0481 `weak let`] is what makes the
`weak let` row above expressible — weak's retain property decoupled from
the timing property (and hence *not* a breaker). [SE-0491 module
selectors] is not addressed here; it's a disambiguator (not a
normalization target), and its payoff for Wire is coupled to multi-module
composition — see
[`MultiModuleComposition.md`](MultiModuleComposition.md).
