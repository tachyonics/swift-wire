# Opaque types in context — how other DI frameworks solve the same problem

> **Status:** comparative research, July 2026. Companion to
> [`OpaqueTypesSupport.md`](OpaqueTypesSupport.md), which specifies Wire's model;
> this note places that model against the rest of the field and records what the
> comparison implies for Wire's public claims. Framework behaviour is cited from
> primary docs and issue trackers as of the research date.

## The question

Every DI framework must answer: **how does a consumer depend on an abstraction
rather than a concrete type, and what does that abstraction cost?** Wire answers
with `some P` as a nominal binding identity plus the constrained-parameter
bridge. Nobody else answers it that way, and the reason is not that Wire is
cleverer — it is that the question means something different in Swift.

## Wire's shipped model, in one table

Grounded in `BindingIdentity.swift`, `Graph.swift`'s `partitionBindings`, and
`DiscoveredBindingAccessors.isLiftNode`.

| Capability | Status |
|---|---|
| `some P` as an exact nominal identity token | Shipped |
| `@Singleton(as: P.self)` → self-producer under `some P` | Shipped |
| Constrained-parameter bridge (rule 2a: bare `T: P` → `some P`) | Shipped |
| Transitive lift (rule 2b: `Box<Element>` → `Box<some P>`) | Shipped |
| Structural identity + minimal `_WireGraph<T0…>` lifting | Shipped (iteration 10) |
| Undetermined generic `@Singleton` → error steering to `@Provides func` | Shipped |
| Generic `@Provides func` as the specialise-per-consumer template | Shipped |
| `some P` satisfies `any P` promotion | Designed, not implemented |
| Multi-identity aliasing / conformance-derived aliases | Deferred |
| `some P<A, B, C>` (parameterized opaque) | Deferred to M2 |

The framing that makes this legible against the field: **Wire has split "generic
binding" into two concepts that other frameworks conflate or lack.** A generic
`@Singleton` is *one instance*, lifted onto the graph, never specialised. A
generic `@Provides func` is a *template*, specialised per consumer. Every
framework surveyed below has at most one of these, and most call it "generics
support" without distinguishing them.

## Against Swift DI

| Framework | How abstraction is expressed | Generic self-production | Runtime cost |
|---|---|---|---|
| **swift-wire** | `some P` identity + constrained-parameter bridge | Generic `@Singleton` lifted as a `_WireGraph` parameter; real type preserved | None — static specialisation |
| **SafeDI** | `fulfillingAdditionalTypes:` on `@Instantiable` | Extension with `static func instantiate() -> GenericType<ConcreteType>` — one overload per closed type argument | `any P` boxing + witness dispatch |
| **Needle** | Dependency protocols (`var repo: TaskRepository { get }`) | Closed types only | Existential |
| **Swinject / Factory / Resolver** | Runtime container keyed by `Service.Type` | One registration per closed generic type | Existential + runtime lookup |
| **swift-dependencies** | `DependencyKey.Value` reached by keypath | A generic dependency in `DependencyValues` isn't expressible type-safely | Struct-of-closures (sidesteps protocols entirely) |

Two things fall out.

**SafeDI's `fulfillingAdditionalTypes` is the direct analogue of Wire's deferred
multi-identity aliasing** — same idea, same bounds (one instance, several
*declared* identities, nothing derived from conformance). It is shipped there and
deferred here, so their diagnostics are worth reading before Wire builds its own.

**No Swift DI framework other than Wire treats `some P` as a binding identity.**
SafeDI's manual mentions opaque types only as function parameters; the others
resolve through existentials or runtime type keys. This is the narrow claim Wire
should make, and it is stronger than a claim about other ecosystems.

## Against non-Swift DI

| Framework | Open generic binding | Generic-aware resolution | Cost of abstracting, vs. the concrete alternative |
|---|---|---|---|
| **Spring** | Yes | Full — generics act as implicit qualifiers via `ResolvableType`; `Store<String>` and `Store<Integer>` disambiguate with no explicit qualifier | Dispatch-path only |
| **.NET MS.DI** | Yes — `AddScoped(typeof(IRepo<>), typeof(Repo<>))`, first-order only | Closed-type lookup | Dispatch-path only |
| **Autofac** | Yes — `RegisterGeneric`, respects type constraints; a closed registration overrides the open one | Closed-type lookup | Dispatch-path only |
| **Guice** | **No** — the FAQ states it cannot bind or inject a generic type such as `Set<E>`; all type parameters must be fully specified | `TypeLiteral` for closed generics | Dispatch-path only |
| **Dagger** | **No** — a generic class hits *"has type parameters, cannot members inject the raw type"* | Closed keys only | Dispatch-path only |
| **Koin** | No — the `KClass` key erases type parameters | — | Dispatch-path only |
| **Kodein** | Partial — `generic()` TypeTokens survive erasure by reflection (slow); `erased()` is fast but erasure-prone | Reflection | Dispatch-path only |
| **Fruit (C++)** | No | Compile-time-checked graph, interface-bound | Real — heap + vtable, from a baseline that has neither |

**On the JVM and .NET, abstracting is nearly free — but "nearly", and only
because the baseline is already dynamic.** It is not that abstraction is
costless; it is that the concrete alternative costs the same. The object is
heap-allocated and reached through a pointer whether the field is typed as the
class or the interface, and the call is dynamically dispatched either way, so
what abstracting actually buys is a slightly worse dispatch path
(`invokeinterface` and its itable lookup, .NET's virtual stub dispatch) plus
whatever devirtualisation and inlining the JIT gives up — usually recovered by an
inline cache at a monomorphic call site. What does *not* happen is a change in
the value's representation.

Swift's `any P` changes the representation: an existential box, a heap allocation
for anything that doesn't fit inline, witness-table dispatch, and no
specialisation across the boundary. That is a different category of cost from
`invokeinterface`, which is why it is worth machinery that would buy a JVM
framework nothing. Fruit is the useful control here — C++ has the same zero-cost
baseline as Swift, so its interface bindings pay a real delta, and it took that
delta rather than build the template machinery to avoid it.

Those ecosystems spent their effort on the *other* axis instead: open generics
and variance-aware matching. The trade inverts cleanly:

- **They buy** open generics — `IRepo<>` bound once, resolved for every `T` — and
  pay with reflection and runtime resolution.
- **Wire buys** zero-cost abstraction and pays with **virality**: a `some P`
  consumer needs a `some P` producer all the way down, and every hop must be
  restructured as a generic type.

That virality cost has no analogue anywhere in the field. In Dagger,
`@Binds Repo bind(DynamoRepo impl)` changes nothing upstream — the consumer
injects `Repo` and every intermediate type is untouched. In Wire the consumer
becomes `TaskController<Repository: TaskRepository>` and so does everything
between it and the leaf. This belongs in the README as the honest headline trade,
because it is what an evaluator hits on day two.

Two mappings worth reusing in user-facing docs, since they reach for vocabulary
the target audience already has:

- **`@Singleton(as: P.self)` ≈ Dagger's `@Binds`** — one instance, an additional
  key, compile-time checked, no reflection. Closer than Guice's `@ImplementedBy`.
- **Generic `@Provides func` ≈ .NET/Autofac open generics** — bound once,
  specialised per consumer. The difference worth stating: Wire resolves it
  statically where .NET and Autofac resolve it reflectively. This is Wire's
  answer on the one axis the JVM/.NET world otherwise wins, and neither the
  README nor `OpaqueTypesSupport.md` currently frames it that way.

## What Spring does that Wire deliberately doesn't

Spring is the only mainstream framework doing full generic-aware matching:
`@Autowired Store<String>` picks the right bean out of several `Store<…>` beans
with no qualifier, variance included. That is *conformance-and-variance search* —
precisely what `OpaqueTypesSupport.md`'s *Identity model* section rejects, and it
is worth being explicit that the rejection is a choice made against a working
example rather than against a hypothetical. Spring can afford it because
resolution is reflective and runs at startup against loaded classes; Wire is
matching syntax at build time with no type checker, so the same rule would mean
reimplementing conformance checking (including retroactive and conditional
conformances it cannot see). The constrained-parameter bridge is the minimum
conformance-*aware* step that avoids this: it reads a declared constraint, it
does not search conformers.

## Adjacent findings from the survey

- **Composition-member order was an identity footgun.** `canonicalTypeName`
  stripped whitespace only, so `some DBTable & Sendable` and
  `some Sendable & DBTable` were distinct graph slots — one type to Swift, two
  identities to Wire, and a missing-binding error naming a type the user reads as
  the one they bound. Guice normalises `TypeLiteral` structurally for the same
  reason. Fixed by sorting depth-0 composition members during canonicalisation;
  emission is untouched (names derive from the written `boundType`).
- **No variance.** `Repo<Sub>` does not satisfy `Repo<Super>`, unlike .NET's
  covariant open generics. Almost certainly correct to skip — variance is where
  open-generic resolution rules get complicated, and .NET restricts itself to
  first-order registrations for related reasons — but it is the first question a
  .NET reader asks, so `OpaqueTypesSupport.md`'s *What this note deliberately
  does NOT add* should say so.

## Sources

- [Guice FAQ — generic types must be fully specified](https://github.com/google/guice/wiki/FrequentlyAskedQuestions)
- [Spring — using generics as autowiring qualifiers](https://docs.spring.io/spring-framework/reference/core/beans/annotation-config/generics-as-qualifiers.html)
- [Spring Framework 4.0 and Java Generics](https://spring.io/blog/2013/12/03/spring-framework-4-0-and-java-generics/)
- [Registering open generics in ASP.NET Core DI](https://ardalis.com/registering-open-generics-in-aspnet-core-dependency-injection/)
- [Autofac — registration concepts](https://autofac.readthedocs.io/en/latest/register/registration.html)
- [Dagger — DI on generic classes (issue #479)](https://github.com/google/dagger/issues/479)
- [Dagger 2 and base classes — generics and presenter injection](https://medium.com/@patrykpoborca/dagger-2-and-base-classes-generics-and-presenter-injection-7d82053080c)
- [Koin — does it support generic types? (issue #1521)](https://github.com/InsertKoinIO/koin/issues/1521)
- [Kodein — generic vs erased TypeTokens](https://kosi-libs.org/kodein/7.17/core/advanced.html)
- [SafeDI](https://github.com/dfed/SafeDI) and its [Manual](https://github.com/dfed/SafeDI/blob/main/Documentation/Manual.md)
- [swift-dependencies — protocol/generic dependencies (discussion #25)](https://github.com/pointfreeco/swift-dependencies/discussions/25)
- [Needle](https://github.com/uber/needle)
- [Fruit (C++)](https://github.com/google/fruit)
