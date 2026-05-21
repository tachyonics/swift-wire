# WireMVC abstraction — working notes

> **Status:** design-space exploration for M5 (WireMVC adapter).
> Captures the shape of how WireMVC could publish a framework-
> agnostic abstraction that HTTP-framework adapters target, mirroring
> the swift-openapi-generator pattern. Not a committed plan;
> intended to preserve thinking from iteration 4a's discussions so
> M5's implementation work doesn't start from scratch.

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
