# WireMVC abstraction — working notes

> **Status:** design-space exploration for HTTP-framework integration
> across M2 (framework-specific adapters) and M5 (cross-framework
> WireMVC). Captures both tiers of integration plus the
> progressive-adoption story for existing codebases. Not a committed
> plan; intended to preserve thinking from iteration 4a's discussions
> so M2's and M5's implementation work don't start from scratch.

## Two tiers of HTTP-framework integration

Wire offers two distinct levels of automation for HTTP-framework
integration, with meaningfully different trade-offs:

- **Tier 1 — framework-specific adapters (`WireHummingbird` /
  `WireVapor`, planned for M2):** the controller stays in its
  native framework form (Vapor's `RouteCollection`, Hummingbird's
  router-registration style). The adapter automates the
  application-level wiring — constructing the controller from
  Wire's graph and registering it with the framework — without
  abstracting routes themselves. The controller's *routes* and
  *handler signatures* stay framework-shaped.
- **Tier 2 — `WireMVC` (planned for M5):** declarative
  cross-framework routing. The controller uses Wire-published
  annotations (`@Controller`, `@Get`, `@Post`, parameter
  annotations) and the build plugin generates route registration
  for whichever HTTP framework adapter is activated. The
  controller's source is portable across frameworks.

The two tiers coexist as separate adapter packages. Tier 1 is the
natural on-ramp for users committed to one HTTP framework who want
compile-time-validated DI without changing their controller style.
Tier 2 is for users who want cross-framework portability, prefer
declarative-routing annotations over imperative
`boot(routes:)`-style registration, or are starting fresh without
an existing framework attachment.

## Tier 1: framework-specific adapters

For Vapor (or any framework with mature MVC idioms), tier 1 is the
realistic on-ramp. The controller preserves its native framework
form; the adapter adds compile-time-validated dependency injection
without displacing the framework's routing model.

### Tier 1, first step: automate the registration call

The minimal adoption: a single annotation tells Wire to register
the controller with Vapor's `Application` at bootstrap. The
controller body is otherwise untouched — services come from
Vapor's request-based service container as usual, the
`boot(routes:)` method is exactly what the user already writes.

```swift
import Vapor
import Wire            // @Singleton
import WireVapor       // @VaporRouteCollection

@Singleton
@VaporRouteCollection
struct TodosController {
    func boot(routes: any RoutesBuilder) throws {
        let todos = routes.grouped("todos")
        todos.get(use: index)
        todos.post(use: create)
        todos.group(":todoID") { todo in
            todo.delete(use: delete)
        }
    }

    func index(req: Request) async throws -> [Todo] {
        try await req.service.list()   // Vapor's request-based service access
    }
    // ...
}

@main
struct App {
    static func main() async throws {
        let env = try Environment.detect()
        let app = try await Application.make(env)
        app.databases.use(.postgres(...), as: .psql)

        // Wire's generated bootstrap constructs every
        // @VaporRouteCollection-annotated type and calls
        // app.register(collection:) for each.
        try await Wire.vapor(app).run()
    }
}
```

The `@VaporRouteCollection` macro adds the `RouteCollection`
conformance (the `boot(routes:)` method already satisfies it) and
registers the type for automated Vapor wiring. Almost nothing else
changes — existing Vapor controllers can adopt this with a
one-line annotation, no rewrite required.

What this first step contributes:

- **Automated `app.register(collection: ...)`** for every
  `@VaporRouteCollection`-annotated type. Removes the
  bootstrap-time `try app.register(collection: TodosController())`
  list-keeping.
- **The controller is now part of Wire's graph.** Even if its
  body doesn't use `@Inject` yet, the type is wired and available
  for future incremental migration.

What stays Vapor (everything, at this step):

- Request-based service access (`req.service`,
  `req.application`, etc.).
- `boot(routes:)`, route grouping, handler signatures, middleware,
  request scope, session handling.
- Vapor's standard runtime setup.

### Tier 1, deeper adoption: move services to `@Inject`

The natural next step is to migrate services from request-based
access to constructor-injected dependencies. The controller keeps
its Vapor shape; Wire builds it with its dependencies wired:

```swift
@Singleton
@VaporRouteCollection
struct TodosController {
    @Inject var service: TodosService    // wired by Wire's graph
    @Inject var logger: Logger

    func boot(routes: any RoutesBuilder) throws {
        let todos = routes.grouped("todos")
        todos.get(use: index)
        // ...
    }

    func index(req: Request) async throws -> [Todo] {
        try await service.list()         // injected service
    }
}
```

This is identical to the first step except for the `@Inject`
properties. The migration is incremental and per-controller —
nothing forces all controllers to switch at the same time.

What the deeper-adoption step contributes:

- **Build-time validation of service wiring.** Missing bindings
  fail at compile time rather than runtime resolution.
- **Composable scope, multi-module composition, key-based
  disambiguation.** Standard Wire features apply.
- **Test substitution.** A `@Container TestContainer { ... }` can
  swap service implementations atomically at the entry point.

What still stays Vapor:

- Routing, handler signatures, request scope, middleware
  composition. The controller's body that touches HTTP is still
  Vapor-shaped; only the dependency wiring moves.

### Request-scoped controllers via `@Scoped`

A further deepening: when the controller wants to inject
request-scoped services directly (a request-tagged logger, a
tenant context derived from the authenticated request, etc.),
the controller itself can be `@Scoped` against the request seed
that `WireVapor` publishes. Wire constructs a fresh controller
per request inside the request scope, and request-scoped
services inject naturally without needing `Provider<T>` or
manual request-scope entry:

```swift
@Scoped(seed: VaporRequest.self)
@VaporRouteCollection
struct TodosController {
    @Inject var seed: VaporRequest               // the Vapor Request
    @Inject var requestLogger: RequestLogger     // @Scoped, request-tagged
    @Inject var service: TodosService            // @Singleton — still injects

    func boot(routes: any RoutesBuilder) throws {
        routes.get("todos", use: index)
    }

    func index(req: Request) async throws -> [Todo] {
        requestLogger.log("listing todos")
        return try await service.list()
    }
}
```

`WireVapor`'s integration handles the difference between
`@Singleton`-scoped and `@Scoped`-scoped controllers
transparently: a `@Singleton` controller is constructed once at
startup and registered with the application; a `@Scoped`
controller's route handlers are wrapped to enter the request
scope, construct the controller fresh, and dispatch.

This pattern is what makes request-scoped services
naturally usable from controllers — no cross-scope-crossing
mechanism is needed because the controller is already inside
the request scope. The pattern composes with `@Singleton`
controllers in the same application; users pick per-controller
which lifetime makes sense.

A side benefit: it reduces what has to live globally on
Vapor's `Request`. Idiomatic Vapor accumulates services on the
request — `req.databases`, `req.auth`, `req.tenant`, custom
extensions — making `Request` a de facto god object that every
controller knows the shape of. With `@Scoped` controllers,
those services get injected into the controllers that
specifically need them; `Request` reverts to carrying just the
HTTP transport state. Each controller's dependency list reads
as a precise statement of what request-scoped state that
controller actually depends on, validated at build time.

### Hummingbird parallel

The same progression applies for Hummingbird via `WireHummingbird`.
Hummingbird's idiom is a `Sendable` controller that exposes
`addRoutes(to:)`, taking a `RouterGroup<some RequestContext>`,
and registers handlers by chaining HTTP-verb methods. The
first-step example looks like:

```swift
import Hummingbird
import Wire                 // @Singleton
import WireHummingbird      // @HummingbirdRoutes

@Singleton
@HummingbirdRoutes(at: "todos")
struct TodosController: Sendable {
    func addRoutes(to group: RouterGroup<some RequestContext>) {
        group
            .get(use: self.list)
            .post(use: self.create)
            .delete(":id", use: self.delete)
    }

    func list(
        _ request: Request,
        context: some RequestContext
    ) async throws -> [Todo] { ... }

    func create(
        _ request: Request,
        context: some RequestContext
    ) async throws -> Todo { ... }
    // ...
}
```

`WireHummingbird`'s generated bootstrap walks every
`@HummingbirdRoutes`-annotated type, constructs each from Wire's
graph, opens the route group at the annotation's path, and calls
`controller.addRoutes(to: group)` on it. The `@HummingbirdRoutes(at:)`
argument specifies the route-group prefix the controller's routes
hang off; this is the rough equivalent of Vapor's
`routes.grouped("todos")` call inside `boot(routes:)`.

The deeper-adoption progression mirrors Vapor's: add `@Inject`
properties to move services from context-based access into the
graph; then, if needed, mark the controller `@Scoped(seed: HummingbirdRequestSeed.self)`
(or whatever seed type `WireHummingbird` publishes) so request-
scoped services inject naturally. Same three steps as the Vapor
side; different framework idioms underneath.

Both `WireVapor` and `WireHummingbird` ship as separate adapter
packages in M2.

### Progressive adoption and coexistence

Tier 1's tightest constraint is that nothing about it forces
all-or-nothing adoption. Within a single application:

- **Some controllers are Wire-annotated; others aren't.** A Vapor
  app can have ten existing `RouteCollection` controllers
  registered manually (`try app.register(collection: ...)`) and
  add `@VaporRouteCollection` to one new controller at a time.
  Wire's bootstrap registers only the annotated ones; the rest
  are user-registered as before. The two co-exist in the same
  `Application`.
- **Annotated controllers can omit `@Inject`.** Tier-1 first-step
  controllers with no `@Inject` properties are wired (constructed
  with empty init, registered) but don't pull from Wire's graph
  beyond construction. Mixing first-step and deeper-adoption
  controllers in the same app works — they're both
  `@VaporRouteCollection`s, differing only in whether they have
  `@Inject` properties.
- **Wire's graph and Vapor's service container coexist.** Wire
  doesn't replace Vapor's runtime services; it sits alongside.
  Services accessed via `req.foo` continue to work; services
  accessed via `@Inject` use Wire's graph. The user controls the
  migration pace per controller.

This makes Wire-on-Vapor adoptable as a *gradient* rather than a
cliff. The first controller takes a one-line annotation; the
hundredth takes the same. There's never a moment where the user
has to commit the whole codebase to Wire.

## Tier 2: WireMVC for cross-framework declarative routing

When the user wants framework-agnostic controllers — or simply
prefers declarative-routing annotations over imperative
`boot(routes:)`-style registration — WireMVC is the path:

```swift
import Wire           // @Singleton, @Inject
import WireMVC        // @Controller, @Get, @Post, @Delete, @Body, @Path

@Singleton
@Controller("/todos")
struct TodosController {
    @Inject var service: TodosService

    @Get
    func index() async throws -> [Todo] { try await service.list() }

    @Post
    func create(@Body input: NewTodo) async throws -> Todo { ... }

    @Delete("/{id}")
    func delete(@Path id: UUID) async throws { ... }
}
```

Wire's build plugin reads the annotations and generates the route
registration. With `WireMVCVapor` activated, the generated code
synthesizes the equivalent of `boot(routes:)` plus the
`app.register(collection: ...)` call. With `WireMVCHummingbird`
activated, the generated code produces the equivalent Hummingbird
router-registration call. The controller's source is identical
across frameworks; only the activated adapter changes.

WireMVC is meaningfully more ambitious than tier 1: the
abstraction has to express middleware, content negotiation,
streaming responses, error mapping, and similar concerns in a way
that survives across frameworks.

### Coexistence with tier 1

Tier 1 and tier 2 controllers can coexist in the same application.
A user could have:

- A handful of `@Controller`-annotated controllers using declarative
  routing (WireMVC, tier 2).
- A handful of `@VaporRouteCollection`-annotated Vapor controllers
  using `boot(routes:)` (tier 1).
- Some manually-registered native Vapor `RouteCollection`s with no
  Wire annotation at all.

Wire's bootstrap walks each adapter's recognised annotation kind
and emits the appropriate registration. Tier 1 and tier 2 are
different adapter annotations targeting different `_wireRegister`
shapes; they don't conflict and there's no precedence to worry
about. The user picks per-controller which tier makes sense.

## The pattern: openapi-generator-style abstraction

`swift-openapi-generator` splits cleanly into two pieces:

1. **Generator** — reads an OpenAPI spec and produces a transport-
   agnostic `APIProtocol` plus types for routes, parameters, and
   responses.
2. **Transport adapters** — `swift-openapi-hummingbird`,
   `swift-openapi-vapor`, etc., each providing the binding between
   the generated `APIProtocol` and a specific HTTP framework.

User code conforms to `APIProtocol` (transport-agnostic); the
chosen transport adapter handles the framework specifics.

WireMVC could take the same shape:

1. **WireMVC core** — defines the MVC annotation surface
   (`@Controller`, `@Get`, `@Post`, parameter annotations) and
   the build plugin that generates registration code targeting an
   abstract server-shape protocol.
2. **HTTP-framework adapters** — `WireMVCHummingbird`,
   `WireMVCVapor`, etc., providing the conformance that registers
   routes with their specific framework.

User code writes controllers; the chosen adapter wires them into
whichever HTTP framework is active.

## Mechanism via Wire's adapter-annotation contract

The contract's `_wireRegister` mechanism supports this directly via
generic protocol parameters:

```swift
// WireMVC core publishes:
public protocol WireMVCServer {
    func register(
        method: HTTPMethod,
        path: String,
        handler: @Sendable (any HTTPRequest) async throws -> any HTTPResponse
    ) throws
}

// User writes:
@Singleton
@Controller("/tasks")
struct TaskController {
    @Get("/{id}")
    func getTask(@Path id: UUID) async throws -> TaskItem { ... }
}

// WireMVC's macro generates:
extension TaskController {
    public static func _wireRegister<S: WireMVCServer>(
        instance: Self,
        server: S
    ) async throws {
        try server.register(method: .GET, path: "/tasks/{id}") { request in
            let id: UUID = try request.path("id")
            return try await instance.getTask(id: id)
        }
    }
}

// WireMVCHummingbird publishes:
extension Router: WireMVCServer where Context: ... { ... }

// WireMVCVapor publishes:
extension Application: WireMVCServer { ... }
```

The consumer activates one HTTP-framework adapter at the entry
point. Wire's build plugin reads the activated module's
conformances, finds the `WireMVCServer` implementation, and emits
the appropriate registration call with concrete arguments.

## Two protocols this could target

WireMVC's "server-shape protocol" doesn't have to be Wire-published.
Two realistic options:

1. **Wire-published `WireMVCServer`.** Wire core (or WireMVC
   specifically) publishes the protocol. Adapter packages provide
   conformances. Self-contained but invents a parallel surface to
   anything the broader ecosystem might converge on.

2. **swift-http-api-proposal's server-side protocol.** The
   proposal explicitly includes a server protocol and a
   composable middleware system in its scope. If it stabilises
   and Hummingbird/Vapor adopt conformances by M5 time, WireMVC
   targets it directly. No Wire-specific server surface;
   ecosystem-shared. Timing depends on the proposal's pace and
   on adapter adoption.

The contract mechanism doesn't depend on which protocol gets chosen
— `_wireRegister`'s generic parameter `S: WireMVCServer` becomes
`S: SomeOtherProtocol` and the adapter publishes the appropriate
conformance. The architectural pattern is the same.

For M5's actual implementation: target option 1 if the ecosystem
hasn't stabilised; option 2 if `swift-http-api-proposal` has
shipped a usable server-side abstraction with adapter conformances.
The decision is M5-time, not M1-time. Both Wire and the proposal
are pre-1.0 efforts in the same ecosystem; co-evolution is more
likely than a clean serial dependency.

## Middleware

The middleware story is harder than route registration. Frameworks
have meaningfully different middleware models:

- **Hummingbird** — generic over context, middleware chained via a
  builder, accessed through the Router.
- **Vapor** — concrete request/response types, middleware
  registered globally or per route group.
- **swift-http-api-proposal** — includes a "composable middleware
  system for processing requests" (per the proposal README) which
  may become the ecosystem's middleware abstraction.

WireMVC's stance:

- **Don't publish a parallel middleware protocol.** Per the
  decision in iteration 4a's discussions, the right move is to let
  the ecosystem converge (swift-http-api-proposal or similar) and
  target whatever shape emerges.
- **Annotation syntax can stay framework-agnostic** even if the
  middleware *type* is framework-specific:

```swift
@Singleton
@Controller("/tasks")
@Middleware(AuthMiddleware())                  // cross-framework type
struct TaskController {
    @Get("/{id}")
    @Middleware(AuditMiddleware())             // route-specific
    func getTask(@Path id: UUID) async throws -> TaskItem { ... }
}
```

  Whether `AuthMiddleware` conforms to Hummingbird's middleware
  protocol, Vapor's, or a shared one is the user's choice; WireMVC
  validates against whichever protocol the active adapter expects.
- **Position-C tier** from the iteration 4a discussion: WireMVC
  *could* eventually publish a narrow common middleware protocol
  for the cross-cutting cases (logging, auth) while letting
  framework-specific middleware stay framework-specific. Defer
  this decision until M5; the ecosystem may have settled by then.

## Other practical complications

These are flagged as design considerations for M5; not committed:

- **Content negotiation.** Different frameworks handle this
  differently. WireMVC could publish a narrow encoder/decoder hook
  (JSON in / JSON out, content-type negotiation contract) or defer
  to framework-specific extensions.
- **Streaming responses.** Hummingbird's `ResponseBodyWriter`-style
  streaming and Vapor's `Response.body = .stream(...)` patterns are
  meaningfully different. Probably framework-specific via adapter
  extensions; not part of WireMVC's core surface.
- **WebSocket upgrades.** Different upgrade protocols and
  lifecycles across frameworks. Stay framework-specific:
  `WireMVCHummingbird.WebSocketRoute`, `WireMVCVapor.WebSocketRoute`,
  separate annotations published by each adapter.
- **Error mapping.** WireMVC defines an error-to-response shape
  (HTTP status + body); framework adapters extend it for
  framework-specific error handling.

## Validation surface

For M5, the validation gate looks like:

- A test app with WireMVC-annotated controllers (`@Controller`,
  `@Get`, `@Post`, parameter annotations).
- One or more HTTP-framework adapters (initially WireMVCHummingbird;
  potentially WireMVCVapor for parity).
- Routes register correctly against the active adapter's framework.
- Middleware annotations validate against the active framework's
  middleware protocol (or against WireMVC's published protocol if
  that direction's taken).

## Open questions for M5's first sitting

1. **Which server protocol do we target on first ship?** Option 1
   (Wire-published) is the safe choice if the ecosystem hasn't
   stabilised. Re-evaluate at M5 time.
2. **Single shared adapter package or per-framework?** A
   `WireMVCHummingbird` adapter covers the common case; a
   `WireMVCVapor` adapter adds Vapor support. Same `_wireRegister`
   contract on both sides — independent packages with no shared
   code beyond the WireMVC core.
3. **How tightly does WireMVC integrate with WireOpenAPI?**
   `@RoutedBy` (WireOpenAPI's adapter annotation, planned for M3)
   targets generated `APIProtocol` types. WireMVC's `@Controller`
   targets WireMVC's own annotation surface. They're parallel
   adapter patterns; both can coexist in the same app, registering
   different controllers via different paths. Confirm the
   adapter-contract design (iteration 8) supports this naturally.
4. **What does middleware look like by M5 time?** Tracks the
   ecosystem; revisit closer to implementation.

## Why this isn't in M1_PLAN's iteration 5 entry

M1_PLAN's M5 entry is a short paragraph capturing scope and
validation gate. The design-space exploration here is too detailed
to live in the plan — and the right design depends on what
ecosystem state we find at M5 time, which we can't predict from
M1. This doc captures the *shape* of the design space; M5's first
sitting picks the specific path against the ecosystem state at
that moment.
