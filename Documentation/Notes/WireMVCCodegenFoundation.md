# WireMVC codegen foundation — moving route-witness generation from the macro to the plugin

> **Status:** proposed direction (design record), captured before implementation. The vehicle for
> M5.3's **3.3 (injected axis)** and the prerequisite for pluggable parameter decomposition +
> `@Configuration`. Supersedes the macro-generated route witness of 3.1c. Build sequencing at the end.

## The move, in one line

Route-contributor **generation migrates from the `@Controller` macro to the plugin (WireGen)**. The
macro becomes a thin marker that *declares* "this type contributes routes"; the plugin, which already
parses the controller for the graph and synthesises the factories, writes the proxy + witness with
**global knowledge**.

3.1c was a step toward this: making the proxy a *separate* peer type (not the controller itself)
already turned it into a plugin-owned coordination artifact. This completes it by moving the
*generation* into the plugin.

## Why — the threads it resolves

1. **The macro is blind to everything outside the attached declaration.** It can't see the graph, other
   modules, the factory templates, or a registry of anything. Every coordination is forced through a
   deterministic-name handshake (`_WireFactory_<key>`).
2. **The proxy is never anyone's public API** — the graph constructs it, the runtime consumes it as
   `any RouteContributor`, its type (`_WireRouteContributor_<C>`) is internal. So it has no reason to be
   macro-generated *in the controller's module*; the only thing that forces it there is that a
   macro-generated proxy referencing `_WireFactory_<key>` needs that type local → **library mode** →
   the contributor plugin. Remove the macro's role and the whole 3.1b workaround (library mode, the
   contributor plugin, the name handshake, the factory-here/controller-there edge case, the cryptic
   "you forgot the plugin" failure) dissolves.
3. **Double parsing.** Today the macro parses the controller for the witness *and* the plugin parses it
   for the graph. Plugin-owned generation collapses this to the plugin's single parse.
4. **Parameter bindings are not pluggable.** `@Path`/`@Query`/`@Header`/`@JSONBody` are enumerated in the
   macro's `bindingWrappers`; a new binding means editing the macro. They are really *decomposition
   transformers* — `(input type, config) → value` — and so is a future `@Configuration(binding,
   "config.item.path")`. A plugin that owns generation can consult a **registered set** of transformers.
5. **The bindings assume the input is a `RequestResponseMiddlewareBox`.** They decompose it to a path
   parameter / header. A transforming middleware can hand the terminal a *different* final box (only its
   `withPendingContents(request, context, reader, sender)` shape is required — see
   [spike-21](../../../swift-wire-spikes/spike-21-wiremvc-transforming-rawroute/)). Decomposition keyed
   by the input type the handler actually receives is the general form.

## Why now — it dissolves 3.3

3.3's one hard sub-problem is the proxy's **generic factory-field type** `_WireFactory_<key><Injected>`,
which the macro can't spell because it can't do either half:

- **Decomposition** — *which* controller generic parameter is the injected backend? The macro is blind
  to the template's injected axis, so today's fallback assumes a single-generic controller (multi-generic
  gets diagnostic-gated).
- **Positional threading** — *where* does the graph-resolved backend go? The macro can only thread the
  written parameter; it doesn't know what the graph resolves it to.

Both are exactly what the plugin knows: it discovers the template (so it knows the injected axis) and
threads the resolved backend through the graph's lift parameter — the **same transitive-lift machinery
3.1c already uses** for `TodosController<T0>` / `_WireRouteContributor_<C><T0>`. So plugin-generated
proxy → 3.3's field-naming problem vanishes: `_WireFactory_<key><T0>`, single- *and* multi-generic, no
macro hack, no limitation. 3.3 becomes "register the factory generic over its injected axis and let
demand-driven specialisation thread it."

The macro workaround for 3.3 would therefore be **throwaway** (the pivot replaces exactly that code), so
the pivot is the right vehicle for 3.3 rather than a detour after it.

## The open decision — where the witness lives

Both options kill the two-plugin split and the name handshake; they differ on accessibility:

- **Consumer module** (per-consumer): the witness calls the controller across the module boundary, so a
  library controller's **route methods must be `public`**. Natural for a shared `Controllers` library.
  Factory types move back to the consumer (per-consumer duplication — harmless: independent graphs, and
  3.1b deduped only to kill the cross-module *reference*, which is gone).
- **Owning module** via one unified plugin (generates witnesses everywhere, graphs on consumers): keeps
  `internal` routes and no cross-module call, but a per-module run survives (merged into the single
  plugin, not a separate contributor plugin).

## Phases

- **Phase A — relocate codegen (macro → plugin), eliminate library mode.** Keep today's *fixed* parameter
  bindings, just moved. Delivers threads 1–3, 5–6 and — as its first validation — **3.3** (injected axis,
  clean). This re-touches the route-witness codegen 3.1c reworked (route walk, param bindings, response
  modes, `@RawRoute`, the `~Copyable` fold), now emitted by WireGen.
- **Phase B — pluggable decomposition transformers + `@Configuration`.** A uniform decomposition
  protocol + a registration/discovery path (adapter-annotation style); bindings register, the generator
  attaches them as parameter bindings (which also fixes the raw-route role/position problem — see below).
  Forward-facing (`@Configuration` is not here yet); builds on A.

## Captured findings that motivate Phase B

From the transforming-middleware / `@RawRoute` threads:

- **Transforming middleware works against the real box** (spike-21): `Box<Ctx>` → `Box<AuthContext>`,
  read by a raw terminal off the final box's `withPendingContents`. The terminal's requirement is
  *structural* (a `withPendingContents(request, context, reader, sender)`), **not** "the final box is a
  `RequestResponseMiddlewareBox`."
- **`@RawRoute` role detection can't be inferred for concrete parameters.** Examples:
  `stream(requestContext: AuthRequestContext, responseSender: consuming Sender)` (concrete enriched
  context) and `jsonMultipart(responseSender: consuming JsonMultiPartSender)` (concrete sender). The
  macro identifies context/reader/sender by *generic-constraint substring* (`rawGenericRoles`,
  `ControllerMacro.swift`), so concrete role parameters fall through to `unsupportedRawParameter`, and no
  heuristic (constraint or elimination) can rescue them — only **conformance** would, which a syntactic
  macro can't check. So the robust answer is **explicit, positional roles** (`@RawRoute(.requestContext,
  .responseSender)`) — a decomposition-transformer instance. `HTTPRequest` / `[String: Substring]` stay
  type-detected; roles only ever concern context/reader/sender.

These are the concrete cases the pluggable, plugin-generated decomposition system (Phase B) is meant to
handle uniformly.

## Sequencing

- **3.2** — done (on main): `@MiddlewareFactory` role mapping + role-ordered `create` + library
  composition of adapter annotations.
- **3.3 (injected axis)** — **parked**, pending Phase A; it rides Phase A as the validation case, rather
  than being built on a throwaway macro workaround.
- **Phase A** — the foundation. De-risked by
  [spike-22](../../../swift-wire-spikes/spike-22-plugin-generated-proxy/) (**passed**): a consumer-module
  proxy holding `_WireFactory_<key><T0>`, its `create` threading the graph-resolved backend, calling a
  `public` library controller's routes across the module boundary — the accessibility model *and* 3.3's
  injected-axis threading both hold, factory in the consumer, no library mode. The one requirement:
  shared-library route methods must be `public` (their API anyway). Implementation = teach WireGen to
  parse the controller's routes and emit the proxy + witness + factory (replacing the `@Controller`
  macro's codegen).
- **Phase B** — pluggable decomposition transformers + `@Configuration`, later.
