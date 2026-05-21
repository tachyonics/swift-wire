# Choosing a DI framework — working draft

> **Status:** working notes, captured during iteration 4a's design
> discussions. Not the final README section; framings here will be
> revisited when M1 ships and the seed-typed-scope model has been
> validated against real adoption. The point of this draft is to
> preserve conceptual work before context drifts, not to commit to a
> public position.

## Core thesis

The right DI framework for a codebase is determined less by personal
preference or surface-level ergonomics than by the **shape of the
application's dependency structure**. Three properties of that shape
matter most:

1. **Tree depth.** Is the application a deep nested hierarchy where
   each level introduces new contextual state? Or a shallow structure
   where most things sit at one logical layer beneath a single scoped
   region?
2. **Scope composition.** Does the application have a single
   long-lived scope (singletons) plus one or two short-lived scopes
   (request, job) that don't nest? Or do scopes nest deeply
   (session > request > sub-request > view-state)?
3. **Source of external values.** Are runtime values (the logged-in
   user, the HTTP request, the active job) seeded at well-defined
   boundaries the developer owns? Or are they ambient context the
   framework supplies through an integration layer?

Once you can describe a codebase's shape along these axes, the right
DI model is often forced. The remainder of this doc maps shapes to
frameworks and to the design choices that distinguish them.

## Shape patterns

### Pattern A — Deep view hierarchy (iOS / SwiftUI / AppKit)

A modern iOS app has views nested 5–10 levels deep. Each level may
introduce new contextual state:

- App root introduces session state and global services.
- A logged-in subtree introduces the authenticated user.
- A "selected document" subtree introduces a document model.
- An "edit mode" subtree introduces edit-mode flags.
- Each modal/sheet/navigation push may open another subtree with its
  own forwarded value.

The dependency tree mirrors the view tree closely. The DI framework's
job is to plumb values through the hierarchy so each view receives
exactly what it needs. The natural shape is *per-node tree position*:
each property declares whether the value originated here, was
inherited, or is owned locally.

### Pattern B — Server request handling (Hummingbird / Vapor / Smithy)

A server has a long-lived process scope (database pools, HTTP
clients, configuration, base loggers) and short-lived per-request and
per-job scopes. The per-request scope is *not* a deep hierarchy: a
typical request handler reaches singletons for services, the request
itself for context-specific data, and a per-request logger. Two or
three logical layers, not eight.

The interesting structural property is *scope siblinghood*: request
scope and job scope don't see each other and are activated
independently. Multiple job-type adapters (SQS, Redis, scheduled
tasks) typically run alongside a single HTTP scope. These siblings
share the singleton scope but never see each other's bindings.

External values (HTTP request, SQS message) are seeded by adapter
integrations at scope entry — not by deeply-nested view-tree
forwarding.

### Pattern C — Service-locator / runtime resolution (TCA-style)

Some codebases — especially those using The Composable Architecture
or modern SwiftUI with `@Dependency` — treat DI as a value-lookup
mechanism rather than a graph construction mechanism. Dependencies
are looked up at the point of use via property wrappers; the graph
is implicit and the lookup is at runtime via task-local overrides.

This pattern is well-suited to apps where dependency-overlay (for
testing, previews, alternative implementations) is the dominant
concern and where the graph itself is small enough not to need
build-time validation.

### Pattern D — Long-running daemons with mixed lifetimes

Some applications (data pipelines, IDE tooling, complex CLIs) have
neither a clean request/response shape nor a view hierarchy. They
have a startup phase, a steady-state phase that runs for hours or
days, and complex internal state. Lifetimes are heterogeneous —
some services are singletons, some are tied to documents/workspaces,
some are per-operation.

These are typically best served by a flexible mid-weight DI
framework (Swinject, Factory, Resolver in Swift; Guice, Spring in
Java) that doesn't lock into a specific scope hierarchy.

## Framework mapping

These mappings are rough — most frameworks can be made to work
across shapes, but each was designed with a specific shape in mind
and shows it.

### SafeDI

**Designed for:** Pattern A. The `@Forwarded`/`@Received`/
`@Instantiated` annotations make tree position explicit at every
property. Sub-tree boundaries via `Instantiator<T>` map directly
to view-hierarchy push points (modal, navigation, sheet).

**Strengths in this shape:** Compile-time-resolved tree, no runtime
resolver state, position-specific factories, full static analysis of
"what's available where." Tree shape mirrors source code shape.

**Friction outside this shape:** For Pattern B, the per-property
annotations become noise — a server request handler has roughly the
same context structure as every other request handler, so declaring
each property's tree position individually is repeating the same
information at every site. For Pattern D, the deeply-structural model
doesn't fit heterogeneous lifetimes well.

### Dagger / Hilt (JVM)

**Designed for:** Pattern A and Pattern B, both. Subcomponents handle
either deep hierarchies (Android view layers in Hilt) or sibling
scopes (Spring-style request scope). `@BindsInstance` for seeded
values handles external value injection cleanly.

**Strengths:** Compile-time validation, explicit scope boundaries,
seed values supplied via builder signatures. The component-class
identity gives static analysis a hook.

**Friction:** Verbose (modules, components, subcomponents, builders
— four concepts to learn before the first working graph). The
verbosity is the cost of expressiveness across patterns A and B.

### Spring / Guice (JVM)

**Designed for:** Pattern B and Pattern D. Named scopes are
declarative (`@Scope("request")`); seeded values are ambient
(ThreadLocal). Reflection-based runtime resolution is more flexible
than build-time validation at the cost of compile-time safety.

**Strengths:** Mature ecosystem, extensive integrations, low
boilerplate, easy to retrofit.

**Friction:** Ambient seeding (ThreadLocal/RequestContextHolder)
fails at runtime rather than compile time. Named scopes don't
distinguish between, say, two job-handling subsystems with different
seed types — both are `@Scope("job")` and have to coexist by
namespacing convention.

### NestJS (TypeScript)

**Designed for:** Pattern B, with conventions borrowed from Spring
and Angular. Module-based dependency declarations, named scopes,
`@Inject(REQUEST)` for ambient request injection.

**Strengths in this shape:** Familiar to developers coming from
Angular or Spring. Module system maps to backend service decomposition.

**Friction:** Ambient REQUEST token has Spring-style failure
modes (runtime errors for misuse). Module system requires upfront
ceremony.

### ASP.NET Core

**Designed for:** Pattern B and Pattern D. Three pre-defined
lifetimes (singleton, scoped, transient); scope established by
middleware; `IServiceScope` is a value the framework or app code can
create at will.

**Strengths in this shape:** Simple, flexible, well-documented.
The "scope is a value you can hold" model is compositional in ways
Spring's named scopes aren't.

**Friction:** No type-level binding identity — registration is by
runtime type lookup, so generics and protocols can be awkward.

### swift-dependencies (PointFree / TCA)

**Designed for:** Pattern C. `@Dependency(\.key)` is a value-lookup
mechanism; `withDependencies { }` creates a dynamic-extent overlay.
Task-local-based scope passing, well-integrated with structured
concurrency.

**Strengths in this shape:** Minimal ceremony, no graph construction
to manage, excellent testability via overlay. TCA-shaped codebases
get exactly what they need.

**Friction:** No compile-time graph validation — missing dependencies
fail at runtime. Doesn't scale to graphs where validating-the-shape
is a primary value of the framework.

### swift-wire (this project)

**Designed for:** Pattern B. Seed-typed scopes mean siblinghood is
the structural rule, not nested hierarchy. Adapter integrations
publish scope kinds and seeds; consumers wire them into a flat graph
with build-time validation. Linux-first means server-side servers
can build it.

**Strengths in this shape:** Build-time validation, explicit scope
identity via seed type, multiple sibling scopes coexist cleanly,
JVM-shaped vocabulary for developers familiar with Spring/Dagger.

**Friction:** Not designed for Pattern A — adapting to deep view
hierarchies would require either composite seed types or nested
`withScope` calls, both of which are more awkward than SafeDI's
tree-positional model. For Pattern C (overlay-based testing), an
overlay primitive exists but isn't the primary design point.

## Other axes worth considering

These factor into the choice but are secondary to application shape.

### Linux-first vs. iOS-first

swift-wire and swift-dependencies build cleanly on Linux. SafeDI's
Linux CI status is untested (per its README). Needle's codegen tool
isn't packaged for Linux. If the deployment target is Linux servers,
this rules out some choices regardless of shape fit.

### Compile-time graph vs. runtime resolution

Build-time graph construction (Wire, SafeDI, Needle, Dagger) catches
missing-binding errors at compile time. Runtime resolution
(swift-dependencies, Swinject, Spring, ASP.NET Core) defers them until
the first failing resolve. For large codebases where shape errors are
the most expensive bugs, compile-time validation is worth the upfront
ceremony. For small or rapidly-evolving codebases, runtime resolution
is often the right call.

### Extension surface

Wire publishes a macro-based adapter-annotation contract that lets
third-party packages contribute framework integrations. SafeDI and
swift-dependencies don't have a published extension contract;
extending them requires changes to the upstream library. Spring's
extension model is the gold standard but reflection-driven. The
"can third parties contribute to my graph without forking the
library" question is decisive if you intend to compose multiple
framework adapters (HTTP framework + queue consumer + scheduler) at
the application level.

### Generics preservation

Some frameworks erase generics (force existentials at injection
sites) for runtime resolution. Compile-time DI typically preserves
them — the binding is specialized at the resolution point. For
performance-sensitive code, this matters; for ergonomic-only code,
less so.

## A working decision guide

Not exhaustive. Use as a starting point.

1. **Is the dependency tree deep and nested (8+ levels with
   contextual state at multiple levels)?** → SafeDI is the natural
   fit. Compile-time tree position is exactly what you want.

2. **Is the dependency structure flat-with-scopes (singletons +
   sibling scopes for request/job/etc.)?** → swift-wire (this
   project, on Linux/server-side Swift) or Dagger/Hilt (JVM).

3. **Is dependency overlay (for tests, previews, etc.) the dominant
   concern and the graph itself small?** → swift-dependencies.

4. **Are you in TCA?** → swift-dependencies (designed to integrate).

5. **Do you need compile-time validation and run on Linux server-side
   Swift?** → swift-wire is the main option. SafeDI's Linux CI is
   untested; Needle's codegen isn't packaged for Linux.

6. **Is the codebase highly heterogeneous in lifetimes, defying clean
   scope categorisation?** → A flexible runtime-resolution library
   (Swinject, Factory) is often the right call. Forcing a
   build-time-graph framework here pays the ceremony cost without
   gaining proportional safety.

7. **Are you doing iOS apps with a non-TCA architecture and want
   compile-time-safe DI?** → SafeDI.

8. **Are you doing iOS apps and the existing DI patterns are
   working fine?** → Don't introduce a DI framework just for the
   sake of one.

## Caveats and what this doesn't address

- **Maturity:** Most of the frameworks compared here are 3+ years
  old with active maintenance. swift-wire is pre-alpha; this doc
  should be re-read after real-world adoption.
- **Adoption signals:** swift-dependencies and SafeDI both have
  significant production use; Wire's value proposition rests on its
  design rather than its adoption story.
- **Ecosystem effects:** Swift's DI ecosystem is small enough that
  network effects (which framework does the library you're using
  integrate with?) can dominate the technical decision. Worth
  checking before committing.
- **Migration cost:** Switching DI frameworks mid-project is
  expensive. Most of these choices are sticky.
- **Macros vs. codegen:** Macro-based frameworks (SafeDI, Wire) tie
  themselves to a specific swift-syntax version range. Codegen-based
  frameworks (Needle) decouple from the compiler version but require
  a separate tool in the build. This is a real trade-off in CI cost
  and stability.

## What this doc is missing (TODOs)

- Concrete code snippets from each framework showing the canonical
  declaration of a "request handler with injected services" — to
  give readers a visual sense of the ergonomic cost differences.
- A more rigorous "scope composition" axis covering session-inside-
  request, multi-tenant scoping, etc. — the current doc assumes
  these patterns are out-of-scope for most servers, but real cases
  exist.
- An honest discussion of Wire's risk profile (pre-alpha, single
  maintainer) for readers evaluating production adoption.
- Cross-references to Swift Server Workgroup recommendations once
  they exist for the DI space.
