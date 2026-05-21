# Wire and architectural patterns — working notes

> **Status:** working notes captured during iteration 4a's design
> discussions about how swift-wire fits with hexagonal architecture
> and Feather-style capability abstractions. Not the final form of
> any public-facing doc; intended to preserve conceptual work before
> context drifts.

## Wire and hexagonal architecture

Hexagonal architecture (Cockburn's ports-and-adapters; Palermo's
onion is the same idea with explicit layering) separates the
application's core logic from infrastructure concerns. Ports are
the protocols the application defines; adapters implement them.
Application code depends on ports, not adapters; adapter
implementations get plugged in at composition time.

Wire's role in this architecture:

- **Wire is the composition mechanism.** It validates the
  dependency graph at build time and emits the wiring code. It
  doesn't dictate architectural style — a Wire-using app can be
  hex, onion, layered, transaction-script, or any other shape.
- **Controllers are inbound adapters.** A WireMVC-style `@Controller`
  translates HTTP requests into application-service calls. It sits
  at the system's edge, depends on protocols (or generic
  parameters) defined by the application, and gets its work done
  by calling into the domain.
- **`@Provides` bindings typed as protocols are outbound ports.**
  When a user writes `@Provides func database(...) -> any DatabaseClient`,
  the consumer of that binding (the application code) depends on
  the port — `any DatabaseClient` — not on the concrete
  implementation that the function constructs internally.

In hex terms, Wire wires:

- Inbound adapters (controllers, queue consumers) to application
  services.
- Application services to outbound ports (typed-as-protocol
  bindings).
- Outbound ports to outbound adapters (concrete implementations
  supplied by `@Provides` returns).

Wire's annotations describe *what* goes in the graph; the
architectural shape (which layer each type belongs to) is the
user's design decision.

## The three-layer ecosystem

Server-side Swift applications using Wire compose three independent
concerns:

1. **Web frameworks (Hummingbird, Vapor)** own the runtime — HTTP
   server, request routing, async lifecycle, middleware chain.
   Their job is to receive requests and dispatch them.
2. **Capability-abstraction libraries (Feather, also Vapor's
   Fluent / Queues / etc., eventually swift-http-api-proposal)**
   define what individual dependencies look like — the *shape*
   of a database client, an HTTP executor, a file storage
   backend, a queue handler. Each capability is a protocol;
   concrete adapter packages implement the protocol for
   specific backends. The libraries differ in whether their
   capability protocols are tied to a specific HTTP framework's
   runtime (Vapor's ecosystem) or runtime-agnostic (Feather);
   see the Vapor-ecosystem section below for the trade-off.
3. **Wire (this project)** validates and composes the graph of
   dependencies at build time. It doesn't define what dependencies
   *are* (that's the capability abstractions' job) or how requests
   get routed to handlers (the web framework's job) — it makes sure
   the dependencies wire up correctly and emits the construction
   code.

The three layers compose naturally. An app:

- Uses a web framework for its runtime.
- Depends on capability abstractions for its building blocks.
- Uses Wire to wire them together with build-time validation.

None of the layers overlap. None of them require the others to
make architectural choices on their behalf.

## Feather as the canonical capability-abstraction example

The Feather Framework (https://github.com/feather-framework)
publishes capability protocols and per-implementation adapter
packages in the canonical hex/ports-and-adapters pattern:

- `feather-database` — abstract database; concrete drivers
  implement.
- `feather-storage` — abstract file storage; S3 driver implements.
- `feather-mail` — abstract mail service.
- `feather-http` — abstract HTTP *executor* (client-side; for
  outgoing requests).
- `feather-openapi` — type-safe OpenAPI specification.

A Wire + Feather application looks like:

```swift
import FeatherDatabase
import FeatherStorage
import FeatherDatabasePostgres   // concrete adapter
import FeatherStorageS3          // concrete adapter

@Provides
func database(config: PostgresConfig) -> some DatabaseClient {
    PostgresDatabaseClient(config: config)
}

@Provides
func storage(config: S3Config) -> some FileStorage {
    S3FileStorage(config: config)
}

@Singleton @Controller("/tasks")
struct TaskController<DB: DatabaseClient, Storage: FileStorage> {
    @Inject var database: DB        // depends on the port via constraint
    @Inject var storage: Storage
    // ...
}
```

The controller is the inbound adapter. The Feather protocols
(`DatabaseClient`, `FileStorage`) are the outbound ports. The
`@Provides` functions constructing concrete instances are the
outbound adapters. Wire validates everything wires together at
compile time, and — because the providers return `some P` rather
than `any P` and the controller is generic over the port — the
concrete types specialise through the controller without
existential boxing. Swapping Postgres → MySQL is one `@Provides`
change; the controller and application services don't move, *and*
the type system stays generic-preserved through the swap.

This is the pattern that distinguishes Wire from reflection-based
JVM DI frameworks: hex-style protocol abstraction at the source,
zero runtime virtual-dispatch cost. Spring's `@Autowired
DatabaseClient database` looks similar at the source but resolves
to an `any DatabaseClient`-equivalent at runtime; Wire's resolves
to the concrete type the protocol's bound to. The trade-off costs
two things — every consumer that wants the abstraction has to be
generic over the port, and Wire's codegen has to support opaque
return types in the bootstrap (see `OpaqueTypesSupport.md` for the
spec, currently deferred to iteration 9). For consumers that can
afford to be non-generic, `any P` is the standard hex pattern and
is available prior to iteration 9.

## Wire with framework-coupled ecosystems (Vapor and similar)

Feather is one shape of capability library: protocols defined
runtime-agnostically, adapter packages per backend, no assumed HTTP
framework. The Vapor ecosystem takes the opposite stance — Fluent
(ORM), Queues, Sessions, JWTKit, and similar packages publish APIs
intentionally tied to Vapor's runtime concepts (`Application`,
`Request`, Vapor's service container). They cover similar
capability ground as Feather (database drivers, queue handling,
mail) but with Vapor's runtime as part of the contract rather
than an integration concern.

The integration shape is meaningfully different from Feather's
because of how Vapor's services are typically accessed. Fluent's
`app.databases.database(.psql, logger:, on:)` returns
`(any Database)?` — Vapor's service registry is a heterogeneous
runtime bag keyed by `DatabaseID`, so the return is existential
by construction. Generic-preserving access via `some Database`
isn't typically available; the consumer accepts `any Database`
(with its existential boxing) or reaches for a concrete driver
type when one's directly importable.

Trade-offs across ecosystem choices:

- **Vapor ecosystem**: lower friction within Vapor (rich, mature,
  integrated). Capability protocols carry Vapor's shape, so the
  application's ports are Vapor-coupled. Switching HTTP
  frameworks would require re-typing the ports against
  framework-agnostic protocols, not just one `@Provides`.
- **Feather ecosystem**: framework-agnostic protocols; swapping
  HTTP frameworks doesn't propagate into the application's
  ports. Fewer integrated packages today; the abstractions are
  newer.
- **Custom mix**: most real apps will mix — Feather (or
  framework-agnostic equivalents) for some capabilities,
  Vapor-tied for others (Fluent for the ORM), concrete types
  for things with no abstraction cost (`Logger`).

Wire's contribution is the same regardless: build-time graph
validation, generic preservation (for the cases where it
applies), scope routing, multi-module composition. The
architectural style of *what* gets wired is the user's design
decision. The README's "neutral on architecture" framing
applies all the way down — Wire isn't a hex-architecture
framework, it's a graph-composition framework that happens to
support hex cleanly when the user wants it.

The minimal HTTP-framework integration shape — for a sense of
what Wire-on-Vapor actually looks like — is a two-annotation
adoption that preserves the existing controller idiom:

```swift
import Vapor
import Wire            // @Singleton
import WireVapor       // @VaporRouteCollection

@Singleton
@VaporRouteCollection // a contributing annotation
struct TodosController {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("todos", use: index)
        // ...
    }

    func index(req: Request) async throws -> [Todo] {
        try await req.service.list()    // Vapor's request-based access
    }
}
```

The existing `RouteCollection`-style controller gains two
annotations and joins Wire's graph; Wire automates the
`app.register(collection:)` call at bootstrap. Nothing about
the routing, handler signatures, or request-based service
access changes. `WireMVCAbstraction.md` covers the rest of the
story: tiers of adapter automation (framework-specific vs
cross-framework declarative), the deeper-adoption path
(`@Inject`-driven service wiring), and the progressive-adoption
patterns for existing Vapor or Hummingbird codebases.

## `some P` vs `any P` vs concrete in hex contexts

Each choice has a hex-architecture interpretation:

- **`some P` from `@Provides` + generic consumer** — hex-style
  abstraction at the *source* level (consumer references only the
  protocol via generic constraint) while preserving concrete
  identity through the type system. Zero existential boxing,
  specialised at compile time. The most architecturally novel of
  the three options for an audience coming from reflection-based
  JVM DI — Spring/Guice can't express this; it requires a
  compile-time DI framework with generic preservation. (See
  `OpaqueTypesSupport.md` for the design spec — deferred to
  iteration 9.)
- **`any P`** — strict port-and-adapter separation. Consumer
  depends only on the port via the existential. Standard hex
  pattern with the standard existential-boxing cost. The
  workhorse for cases where the consumer can't or shouldn't be
  generic over the port (e.g., heterogeneous consumers, types
  bound to swift-log's `Logger`, or anything where the generic
  surface would cascade through the codebase awkwardly).
- **Concrete type at both ends** — no abstraction. The consumer
  knows the implementation. Strictly speaking, breaks hex purity
  for that binding, but acceptable when the abstraction would
  cost more than it returns (e.g., a `Logger` from `swift-log`
  where there's only one canonical implementation pattern).

The choice is the user's per binding, not Wire's. Wire supports
all three (the `some P` path landing with iteration 9's opaque-
types support).

## WireMVC's positioning

WireMVC (planned for M5) provides the inbound-HTTP-adapter
mechanism — `@Controller`, `@Get`, `@Post`, parameter annotations
— that generates the registration plumbing.

A framework-agnostic WireMVC would publish a server-shape protocol
that Hummingbird/Vapor adapters conform to, mirroring
swift-openapi-generator's split between `swift-openapi-generator`
(generates `APIProtocol`) and `swift-openapi-hummingbird` /
`swift-openapi-vapor` (provides transport bindings). See
`WireMVCAbstraction.md` for the design space.

Feather's `feather-http` is client-side; the natural
cross-framework abstraction WireMVC would target on the server
side is `swift-http-api-proposal` once it stabilises — its scope
explicitly includes a server protocol and middleware. Until that
proposal ships and Hummingbird/Vapor adopt it, WireMVC's M5
implementation targets the HTTP frameworks directly through
per-framework adapter packages (WireMVCHummingbird,
WireMVCVapor).

## Layer relationships at a glance

```
+--------------------------------------------------------------+
| Application code                                             |
|   @Controller, @Get, @Post              <- WireMVC           |
|   @Inject var ...                       <- Wire annotations  |
|   Domain types, application services                         |
+--------------------------------------------------------------+
| Capability protocols                                         |
|   DatabaseClient, FileStorage, ...      <- Feather, etc.     |
|   Server protocol (when published)      <- swift-http-api    |
+--------------------------------------------------------------+
| Concrete adapter packages                                    |
|   feather-database-postgres                                  |
|   feather-storage-s3                                         |
|   WireMVCHummingbird / WireMVCVapor                          |
+--------------------------------------------------------------+
| Runtime                                                      |
|   Hummingbird / Vapor / etc.            <- web framework     |
+--------------------------------------------------------------+
```

Wire wires the top layer; capability protocols and adapters
inhabit the middle; the runtime is at the bottom. The arrows
between layers all point upward (dependencies on abstractions,
not implementations).
