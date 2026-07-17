# Phase A build plan — plugin-generated route contributor

The sequencing to move route-witness generation from the `@Controller` macro to plugin-orchestrated
codegen (consumer-module), eliminating library mode. Design record:
[WireMVCCodegenFoundation.md](WireMVCCodegenFoundation.md). Feasibility:
[spike-22](../../../swift-wire-spikes/spike-22-plugin-generated-proxy/) — the emitted shape compiles,
serves cross-module, and threads the injected-axis factory. Same discipline as the archived plans: each
increment runs end-to-end and has a gate; swift-wire changes land + push, the adapter picks them up.

## What Phase A delivers

- `@Controller` becomes a **marker**; the proxy + witness + factory types are emitted under **plugin
  orchestration**, in the **consumer** module, with the plugin's global knowledge.
- **Library mode + `WireContributorPlugin` removed** — one plugin, one parse of each controller.
- **Behaviour is identical** — every example serves exactly as today.
- **3.3 (injected axis) is unblocked** and lands on this foundation as its validation.

## The linchpin — domain codegen vs. a domain-free WireGen  ·  **[A0, RESOLVED]**

> **Decision (A0):** mechanism **1** (domain codegen tool, plugin-orchestrated) with an
> **adapter-owned build plugin**. WireGen emits the structural half (proxy struct + generic factory
> fields + `T0` threading + graph) with a **body hole**; a WireMVC codegen tool emits the witness body
> as an `extension` on that struct, in the same consumer module, meeting it only on the deterministic
> field names (`_wireFactory_<key>` / `controller`). The **build plugin moves to the adapter (wire-mvc)**
> and runs both tools; swift-wire's one change is to **expose WireGen as an executable product** so the
> adapter's plugin can `context.tool(named: "WireGen")` it. De-risked by
> [spike-23](../../../swift-wire-spikes/spike-23-two-tool-codegen/) (**passed**): two tools, one module,
> compiles + serves, and the field-name handshake is compiler-enforced (a desync fails the build at the
> reference site). Rationale for adapter-owned over "WireGen gains a generic run-adapter-tools hand-off":
> orchestration is itself domain knowledge, so it belongs in the adapter; keeping it there lets WireGen
> stay strictly structural instead of growing a tool-registration surface (which would drift toward
> mechanism 3). The reasoning that led here is preserved below.

This was the real problem, and it had to be settled before the increments were concrete:

- The route witness is WireMVC **domain** codegen — verbs → `builder.register`, `@Path`/`@Query`/…
  bindings, response modes, the `~Copyable` middleware fold. WireGen is deliberately **domain-free**
  (adapters are external repos; WireGen understands only *generic* capabilities — contribute / inject /
  map-roles / contributes-proxy). Teaching WireGen "routes" would be exactly the domain-leak the
  architecture avoids.
- Yet the witness must be emitted with the plugin's **global** knowledge (the generic factory field
  types, the `T0` threading) the macro can't reach — and the body must be **inline in / on the
  plugin-emitted struct**, because it accesses `self._wireFactory_<key>` and `self.controller` by field,
  whose generic types only the plugin can spell.

So WireGen has to **orchestrate domain codegen it does not itself contain.** Candidate mechanisms:

1. **Domain codegen tool, plugin-orchestrated (lean).** The plugin emits the *structural* half — the
   proxy struct, its generic factory fields, the `T0` threading, the graph wiring — and a
   WireMVC-provided codegen tool emits the *witness body* as an `extension` method on that struct (same
   consumer module), referencing the struct's fields by their **deterministic names**
   (`_wireFactory_<key>` / `_wireSubject` — the field-name handshake). They compose on field names + same
   module. WireGen stays domain-free; WireMVC owns route codegen.
2. **Descriptor + template.** WireGen discovers routes as generic descriptors; WireMVC ships a fill-in
   template. Likely too weak for the `~Copyable` fold + binding variations.
3. **Extensible WireGen.** WireGen loads a WireMVC codegen library. Powerful, but turns WireGen into a
   codegen framework — a large architectural addition.
4. **Pragmatic coupling.** WireGen hardcodes route codegen. Fast, but the domain-leak the architecture
   explicitly avoids. A deliberate stopgap only.

**Open sub-questions under mechanism 1** (why A0 needs a spike, not just a decision):

- **Whose plugin orchestrates?** A SwiftPM plugin can invoke tools from *its own* package. swift-wire's
  `WireBuildPlugin` can run `WireGen` but not a wire-mvc tool it doesn't know. So either the build plugin
  **moves to the adapter** (a WireMVC plugin that runs both `WireGen` and the WireMVC codegen tool), or
  WireGen gains a generic "run these adapter codegen tools" hand-off. This is the real orchestration
  decision.
- **How the two halves meet** — an `extension registerWireRoutes` in a separate file (same module) is
  the clean seam; the struct (fields) and the body (field access) never need to see each other's source,
  only agree on names.

**A0 gate — CLEARED.** [spike-23](../../../swift-wire-spikes/spike-23-two-tool-codegen/): WireGen
(stand-in) emits the struct with a body hole, a stand-in domain tool emits the `extension` body, the
two-tool one-module output compiles + serves, and the field-name handshake holds (compiler-enforced —
a rule desync in one tool fails the build at the reference site). "Whose plugin" is answered:
adapter-owned, running both tools, with WireGen published as an executable product. A1–A5 are now
concrete.

## Increments (contingent on A0)

**A1 — the structural half (WireGen, domain-free). DONE.** A domain-free `renderContributorProxyDeclaration`
(`WireGenCore/ContributorProxyEmission.swift`) emits the proxy `struct` — stored subject (`_wireSubject`)
+ each lifted factory (`_wireFactory_<key>`) field, the initialiser the graph's construction call targets,
`Sendable`, generic exactly as the subject (constraints + `where` clause) — with a **body hole**: no
adapter conformance, no witness. The graph construction of the proxy binding already existed (contributor-
proxy + factory synthesis); A1 adds only the *type* emission plus the model support it needs
(`DiscoveredScopeBoundType.genericWhereClause`, populated in discovery, restated on the proxy).

**No capability fork.** The emission is *not* wired into the live pipeline and there is **no new adapter
capability** — `.contributesProxy` is unchanged. "Contribute a proxy" already means "WireGen owns the
structural proxy"; naming a domain-free WireGenCore capability `.contributesRoutes` would leak HTTP domain
into the domain-free layer, and forking for a transitional reason cuts against consistent-API. So the
render function stands alone, unit-tested directly (11 tests: struct shape, the `_wireSubject` /
`_wireFactory_<key>` field-name contract, and an end-to-end check that the emitted init matches the graph's
construction call). It goes **live at A3**, atomically with `.contributesProxy` switching to plugin-emitted
and the adapter macro dropping its type emission (the two structs are the same type name — they cannot
coexist, so the cutover is synchronized rather than gradual). The 3.3 generic factory rides along for free:
A1 emits each factory field's type *verbatim* from the binding, so when A5 makes it `_WireFactory_<key><T0>`
the emission follows with no change.

**A2 — the domain half (WireMVC codegen tool).** Port `ControllerMacro`'s route codegen — verbs,
`@Path`/`@Query`/`@JSONBody`/`@Header` bindings, `@JSONResponse`/`@ResponseStatus`, `@RawRoute`, the
middleware fold (concrete / generic / factory) — into the body generator, emitting the witness via the
A0 seam. The route-shape diagnostics (unannotated parameter, path mismatch, raw-route roles — see the
concrete-parameter finding in the foundation note) move here, anchored at source locations. Unit-tested
against every route shape, **asserting output parity with the current macro** to catch drift.

**A3 — cutover: `@Controller` → marker. DONE.** `@Controller` is a marker (expands to nothing); it stays
on `.contributesProxy` (unchanged name). The plugin now goes live: WireGen emits the structural half (A1's
`renderContributorProxyDeclaration`) into the consumer graph file and is published as an executable product;
the adapter-owned `WireMVCBuildPlugin` runs WireGen + `WireMVCRouteGen` (A2), which emits the witness
extension — the macro emits neither. A consumer applies `WireMVCBuildPlugin` instead of `WireBuildPlugin`.
The flip was **synchronized** across three repos (swift-wire #191 go-live → wire-mvc marker+plugin → the
three example runtimes adopt `WireMVCBuildPlugin`).

**One defect the examples caught** (the single-module `WireMVCExample` didn't): a `public` shared-library
controller yielded a `public` proxy, but the consumer's generated file imports `Controllers` *internally*
(`InternalImportsByDefault`), so a `public` proxy can't expose the library's types. Fix (swift-wire, follow-up
to #191): the proxy is emitted **`internal`** — it's a consumer-local coordination type, never public API.
The shared-library routes are already `public` (their API anyway), so the public-route constraint held with
no diagnostic needed yet. Gate met: `WireMVCExample` + all three runtime examples serve — CI green across
swift-wire, wire-mvc, and wire-mvc-examples.

**A4 — remove library mode. swift-wire side DONE.** The graph consumer now emits every *consumed* factory
type (`renderConsumedFactoryTypes` over the synthesised set — own- and dependency-module templates alike),
`internal` for the same `InternalImportsByDefault` reason as the proxy (a `public` factory can't be built
from an internally-imported produced type). `WireContributorPlugin`, the `--library` WireGen path,
`runLibraryMode`, and `renderOwnedFactoryTypes`/`renderFactoryModule` are removed; `WireBuildPlugin` is the
only plugin. `_WireExports.swift` stays as the cross-module-composition marker (the consumer re-parses
Wire-aware deps) — its full retirement is M6, not this. 615 tests pass; a `public @Factory` template now
emits an internal `_WireFactory_<key>` (verified). **Adapter side:** the shared `Controllers` library drops
`WireContributorPlugin` (it referenced the now-removed product) — nothing in it references the factory
types any more, since `@Controller` is a marker. Synchronized cutover: swift-wire A4 + `Controllers`
plugin-drop land together. Gate: the shared `Controllers` library serves through the consumer-generated
witness + consumer-emitted factories, all three runtimes (CI).

**A5 — un-park 3.3 (injected axis). swift-wire side DONE.** A `@Factory` middleware that `@Inject`s a
generic dependency makes that parameter *injected* (`assistedParameters(of:)`'s complement — already
computed, no new annotation; the injected axis follows from `@Inject`, not a role). The synthesised factory
becomes generic over it: `SynthesizedFactory` splits `parameterNames` into injected (the factory struct's
own generics) and assisted (box roles on `create`); `renderFactoryDeclaration` emits
`struct _WireFactory_<key><Repository: TodoRepository> { let repository: Repository; func create<Ctx>(…)
-> Produced<Ctx, Repository> }`; `factoryBinding` is generic over the injected axis with the injected
`@Inject` deps as bare-parameter dependencies, so it's a **lift node** the *existing* transitive-lift
machinery threads `T0` through; and the proxy's factory field is spelled `_WireFactory_<key><Repository>`
(matched to the consumer's generic param by constraint), so it threads via the proxy's own parameter.
Verified by a manual WireGen run producing spike-22's exact shape (`_WireFactory_<key><T0>`,
`Controller<T0>`, proxy `<T0>`, sharing one backend) + 4 unit tests; 619 tests pass. No macro coordination.
**Gate (remaining):** `Controllers`' `AuditGate` gains a `Repository: TodoRepository` injected axis
(`@Inject let repository: Repository`, sharing the controller's backend); the runtimes serve end-to-end (CI).

## Cross-cutting

- **Parity is the cutover gate.** A3 must serve byte-for-behaviour-identically; A2's parity tests catch
  codegen drift *before* the cutover.
- **Names stay the handshake** — `_wireFactory_<key>` and the proxy fields — now shared between WireGen's
  struct and the domain body generator, not macro↔plugin.
- **Public routes** — the one new constraint on a shared-library controller (its routes are its API
  anyway), enforced by the A3 diagnostic.
- **This is a large, atomic cutover** (A3). The value of A0–A2 is to make everything *before* the cutover
  independently testable, so A3 flips a well-exercised generator on.

## Validation vehicles

- **swift-wire:** unit tests over the structural emission (A1) and the domain body generator (A2, parity
  with the macro).
- **wire-mvc:** `WireMVCExample` serves unchanged, built against pushed swift-wire main.
- **wire-mvc-examples:** the three runtimes + the shared `Controllers` library serve; the 3.3
  shared-repository example (A5).

## Sequencing note

A0 is the gate on committing to the rewrite — it is as much "decide + spike the orchestration" as
"design." If A0's mechanism proves heavier than expected (e.g. the plugin must move to the adapter),
that cost is Phase A's real price and should be weighed against the present library-mode pain before
A1 starts. 3.2 is done; 3.3 waits on A5.
