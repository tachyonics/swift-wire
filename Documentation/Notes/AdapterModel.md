# Adapter model — design note

> **Status:** the adapter-annotation contract as shipped in **M2.3** — a
> *contribution alias*. This **supersedes the earlier `_wireRegister` side-effect
> "sink" model** (post-construction registration, `registerSignature`/`form`/`phase`,
> `adapterAnnotatedIdentities`), which collation replaced — see *What changed*.

## What an adapter is

The adapter-annotation contract is swift-wire's extension point: a third-party
package publishes its own annotation — WireHummingbird's `@HummingbirdController`,
WireOpenAPI's `@OpenAPIController` — that **aliases `@Contributes(to: key)`**. The
annotated binding collates into a multibinding key the adapter owns; a facade the
adapter ships applies the collated products to a framework object (a Hummingbird
`Router`, a `some ServerTransport`) that stays *outside* the graph. The DI core does
the collation and knows nothing about the framework; the contract is the published,
versioned surface adapters build against. (See [WireHummingbirdDesign.md](WireHummingbirdDesign.md)
and [WireOpenAPIDesign.md](WireOpenAPIDesign.md) for the two shipped adapters.)

## The contract

```swift
public let openAPIController = WireAdapterAnnotationV1(
    annotation: "OpenAPIController",         // the attribute spelling, without `@`
    contributesTo: TransportKeys.handlers    // the multibinding key `@OpenAPIController` aliases into
)
```

Read *syntactically* — like a binding-key declaration, never executed:
`contributesTo` is captured as its written key reference, not its runtime value.
Versioned by type name (a shape change ships `WireAdapterAnnotationV2`).

## How it works

1. The adapter package declares the `WireAdapterAnnotationV1` alias, **owns the
   multibinding key** (`TransportKeys.handlers = CollectedKey<any TransportContributor>`),
   and ships a **facade** that consumes the key's product (`apply(graph, to:)`).
2. The consumer applies the annotation (`@Singleton @OpenAPIController struct C {}`). The
   build plugin discovers the alias definition (by re-parsing the adapter's
   sources) and the use-site — *name-agnostically*, because the defining module may
   differ from the use module.
3. After aggregation, the plugin injects a **synthetic `@Contributes(to: key)`**
   onto each aliased binding, which then flows through the ordinary multibinding
   fan-in into the key's aggregate. **No bespoke emission** — collation is the
   whole mechanism.
4. The aggregate is consumed like any multibinding: a keyed `@Inject(key) var`, or
   the graph-conformance surface (`extension _WireGraph: HummingbirdComposable`) a
   facade reads.

## The macro / Wire split

The framework logic lives in the **adapter's macro**, run by the compiler at
expansion; Wire does only DI plumbing. The Wire-facing surface is *one annotation
plus its key*.

- The adapter's macro makes the annotated type conform to the collated element type
  — `@OpenAPIController` adds the `TransportContributor` conformance whose witness
  calls the generated `registerHandlers`; `@HummingbirdController("path")` adds the
  `RouteContributor` conformance whose witness owns the mount. Wire never reads
  this; it's the adapter's framework surface.
- Wire sees `@OpenAPIController`/`@HummingbirdController` only as the alias — a
  contribution to the key. It never learns routing or HTTP.
- An adapter can carry an arbitrarily rich internal vocabulary (`@Get`,
  `@Middleware`, … as marker macros on controller *methods*); Wire's scan never
  matches them, so they're invisible to the DI core.

## Collation, not registration

The shipped model is **collation**, not side-effect registration:

- **Contributors collate.** Each `@X` binding contributes its product into the
  adapter's `CollectedKey` (routes, controllers) or `BuilderKey` (a middleware
  fold); the graph fans them in.
- **A facade applies them.** The framework object (`Router`, `ServerTransport`)
  stays *outside* the graph; `apply(graph, to: router)` applies the collated
  products to it. Nothing in the graph consumes a *mutated* collaborator, so there's
  no ordering problem and no post-graph phase.

See [`WireHummingbirdDesign.md`](WireHummingbirdDesign.md) for the collation model
end-to-end (routes as a `CollectedKey`, middleware as a `BuilderKey`, the
graph-conformance surface).

## Dead-binding check

No adapter-specific rule. An aliased binding has a **contribution**, so it's a
multibinding contributor — live via its aggregate the same way any `@Contributes`
binding is. (The earlier sink model needed `adapterAnnotatedIdentities` to exempt an
un-consumed registered subject; collation removes the need — the contribution *is*
the consumption edge.)

## What changed (why this note was rewritten)

The earlier model made an adapter a **post-construction sink**: the annotation's
macro generated `_wireRegister(instance: Self, router: $0)`, and Wire emitted that
call after graph construction to register the instance *into* a graph-bound
collaborator (a `Router`). It carried `form`/`phase`/`registerSignature`, an ordering
concern (a consumer of the mutated collaborator had to run after registration), and
a bespoke dead-binding exemption.

Collation supersedes it: the `Router` leaves the graph, the annotation aliases
`@Contributes`, and the contributor flows through the existing multibinding
machinery. The whole `_wireRegister` path — `AdapterResolution`, the emission, the
use-site scanner, the exemption, and the `form`/`phase`/`registerSignature` fields —
retired in M2.3.

## Scopes — the contract's next axis (future)

An annotation may later declare the scopes it's valid on: `contributableScopes`
(app-scoped, direct — the M2.3 default) and `proxyableScopes` (a request-scoped
controller proxied to an app-scoped contributor that enters the scope per request —
**M5/WireMVC**, via the shared "adapter replaces the binding" primitive). Not part
of the M2.3 contract; see [`WireHummingbirdDesign.md`](WireHummingbirdDesign.md),
*Scope model*.
