# Adapter model — design note

> **Status:** forward-looking design. The adapter-annotation contract is being
> built in iteration 8 (type-level, unkeyed). The producer-level forms and
> keyed dependencies described here land in iteration 9, with the task-cluster
> migration. Captures the conceptual model so it isn't re-derived.

## What an adapter is

The adapter-annotation contract is swift-wire's extension point: a third-party
package publishes its own annotation — WireOpenAPI's `@RoutedBy`, a
hypothetical WireMVC's `@Controller` — that hooks a framework integration into
the generated bootstrap, without the DI core knowing the framework. The core
does the wiring; the contract is the published, versioned surface adapters
build against.

## An adapter is a sink

An adapter is a **post-construction sink**: it consumes a single managed
instance plus Wire-resolved dependencies, performs a side effect (register a
controller with a router, a consumer with a queue, a job handler with a
scheduler), and produces no binding. It is consumer-side — the annotated thing
becomes an additional consumer of its own instance plus whatever deps the
adapter declares. Construction and this consumption are separate: the instance
exists because it's a binding; the adapter merely reads it afterwards.

## What an adapter can attach to — a single managed instance

A sink acts on *one* instance, so it attaches only to a producer that resolves
to a single managed instance:

| Producer | One instance? | Adapter | Form |
|---|---|---|---|
| `@Singleton` | yes — self-produced | ✓ | type-level (member macro) |
| `@Provides let`/`var` | yes — externally produced | ✓ | producer-level (peer macro) |
| non-generic `@Provides func -> Concrete` | yes — factory-built once | ✓ | producer-level (peer macro) |
| generic `@Provides func -> X<T>` | no — parameterised family | ✗ | — |

The line is **single managed instance vs parameterised factory** — not
let-vs-func, and not custom-construction-vs-not. A `@Provides func` with a
custom body returning one concrete type is still one instance (the
"do setup before constructing, then register it" case). Only *parameterisation*
— a generic factory specialised per consumer demand — removes the single
instance, and with it the thing a sink would attach to.

### Prior art

This is the boundary established DI already draws around instance-level
concerns. The shared concept (not the annotation contract, which is
swift-wire's) shows up as:

- **Dagger / Guice assisted injection** — parameterised factories **cannot be
  scoped**; no single instance for a scope to pin.
- **Spring prototype beans** — **no destruction lifecycle callbacks**; the
  container hands the object off and keeps no instance to manage.
- **Spring `@Bean` factory methods** — *are* managed singletons with full
  lifecycle: custom construction, one instance, hooks apply.

Scope and destruction callbacks are the canonical instance-lifecycle concerns;
an adapter sink (a once, post-construction registration) is the same category,
so it attaches exactly where they do — to a single managed instance, never to
a parameterised factory.

A *per-production* hook is a different animal that **can** apply to a factory
(Spring's `BeanPostProcessor` runs on every prototype; a decorator wraps each
produced instance). An adapter is not one of those — it registers once, so it
needs the one instance.

## Forms

- **Type-level (M1).** The annotation sits on a type (`@Singleton @RoutedBy(…)`);
  a member macro generates `_wireRegister(instance: Self, …)`; `instance:` is
  the type's graph binding.
- **Producer-level (iteration 9).** The annotation sits on a single-instance
  `@Provides let`/`var` or non-generic `@Provides func -> Concrete`; a peer
  macro generates the registration for the produced value. This is the case
  for wiring an existing instance, or one whose type you don't own (and so
  bind via `@Provides` rather than annotate `@Singleton`).

`@attached(member)` can't sit on a value declaration — that's *why* the
producer-level form is a peer macro rather than the same member macro. The
`WireAdapterAnnotationV1.Form` enum carries the form; M1 declares `.typeLevel`.

## How it works (type-level, M1)

1. The adapter package declares a `WireAdapterAnnotationV1` (discovered like a
   binding key) giving the annotation name, form, phase, and the
   `_wireRegister` signature template.
2. The consumer applies the annotation; its build plugin discovers the use-site
   and, from the manifest, knows the `_wireRegister` signature without expanding
   the macro (it runs before expansion).
3. Wire validates each declared dependency against the binding graph (missing →
   error at the annotation) and emits, post-graph,
   `Type._wireRegister(instance: <graph member>, router: <resolved dep>)`.
4. Separately, the adapter's macro (at compiler expansion) generates the actual
   `_wireRegister` body.

## The macro / Wire split

The framework logic lives in the **adapter's macro**, run by the compiler at
expansion; Wire does only DI plumbing. WireMVC illustrates it:

- `@Get`, `@Middleware`, … are WireMVC's marker macros on controller *methods*.
  Wire has no definition for them, so its scan never matches them — they're
  invisible to the DI core.
- the type-level `@Controller` adapter is Wire's *only* surface. Its macro, at
  expansion, walks the controller's methods, reads their `@Get`/`@Middleware`
  attributes, and composes the routing into the `_wireRegister` body it
  generates.
- Wire sees `@Controller`, validates its declared deps (the router) against the
  graph, and emits `Controller._wireRegister(instance: <controller>, router:)`
  post-construction. It never learns routing or HTTP.

So an adapter package can carry an arbitrarily rich internal vocabulary; the
Wire-facing surface is one annotation plus its dependency signature.

## Relationship to the rest of the model

- **Self-production.** The annotated `@Singleton` is a graph node like any
  other (a generic one lifts its parameter onto `_WireGraph`, resolved by
  dependency identity — not specialised); the adapter just consumes it
  post-construction. This is why `@RoutedBy` doesn't need a CompositionRoot to
  pull the controller in — the singleton already exists. See
  [`../../OpaqueTypesSupport.md`](../../OpaqueTypesSupport.md).
- **Keyed dependencies.** An adapter's declared deps can reference keyed
  bindings via `keyed(Type.self, with: Key)`, a member of the keyed-reference
  family. See [`ScopeAndKeyModelEvolution.md`](ScopeAndKeyModelEvolution.md),
  "Adapter dependencies."
