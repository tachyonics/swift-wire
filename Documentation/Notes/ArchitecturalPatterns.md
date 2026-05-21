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
2. **Capability-abstraction libraries (Feather, eventually
   swift-http-api-proposal)** define what individual dependencies
   look like — the *shape* of a database client, an HTTP executor,
   a file storage backend, a queue handler. Each capability is a
   protocol; concrete adapter packages implement the protocol for
   specific backends.
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
func database(config: PostgresConfig) -> any DatabaseClient {
    PostgresDatabaseClient(config: config)
}

@Provides
func storage(config: S3Config) -> any FileStorage {
    S3FileStorage(config: config)
}

@Singleton @Controller("/tasks")
struct TaskController {
    @Inject var database: any DatabaseClient    // depends on the port
    @Inject var storage: any FileStorage
    // ...
}
```

The controller is the inbound adapter. The Feather protocols
(`DatabaseClient`, `FileStorage`) are the outbound ports. The
`@Provides` functions constructing concrete instances are the
outbound adapters. Wire validates everything wires together at
compile time. Swapping Postgres → MySQL is one `@Provides` change;
the controller and application services don't move.

## `any P` vs `some P` vs concrete in hex contexts

Each choice has a hex-architecture interpretation:

- **`any P`** — strict port-and-adapter separation. Consumer
  depends only on the port. Existential boxing at the boundary.
  The canonical hex pattern.
- **`some P` from `@Provides` + generic consumer** — hex-style
  abstraction at the *source* level (consumer references only the
  protocol via generic constraint) while preserving concrete
  identity through the type system. Zero existential boxing,
  specialised at compile time. (See `OpaqueTypesSupport.md` for
  the design spec — deferred to iteration 9.)
- **Concrete type at both ends** — no abstraction. The consumer
  knows the implementation. Strictly speaking, breaks hex purity
  for that binding, but acceptable when the abstraction would
  cost more than it returns (e.g., a `Logger` from `swift-log`
  where there's only one canonical implementation pattern).

The choice is the user's per binding, not Wire's. Wire supports
all three.

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

Feather currently doesn't publish a server-side HTTP capability
(its `feather-http` is client-side). When/if a server-side
abstraction emerges — either through `swift-http-api-proposal`,
a future `feather-http-server`, or another effort — WireMVC
targets it as the cross-framework port. Until then, WireMVC ships
per-framework adapters (WireMVCHummingbird, WireMVCVapor) as the
M5-timeframe implementation.

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

## What this isn't

- A claim that Wire *requires* hex architecture. Wire works for
  any architectural shape; this doc captures how the hex shape
  composes cleanly because that's the architecture much of the
  README's audience (server-side Swift developers coming from
  JVM/backend ecosystems) thinks in.
- A prescription about which capability libraries to use.
  Feather is the most-developed example today; the architectural
  pattern works with any capability-protocol library.
- A specification of WireMVC's adapter contract. That's
  WireMVCAbstraction.md's territory.
