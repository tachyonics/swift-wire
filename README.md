<p align="center">
  <a href="https://github.com/tachyonics/swift-wire/actions/workflows/swift.yml">
    <img src="https://github.com/tachyonics/swift-wire/actions/workflows/swift.yml/badge.svg" alt="Build">
  </a>
  <a href="https://swiftpackageindex.com/tachyonics/swift-wire">
    <img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ftachyonics%2Fswift-wire%2Fbadge%3Ftype%3Dswift-versions" alt="Swift versions">
  </a>
  <a href="https://codecov.io/gh/tachyonics/swift-wire">
    <img src="https://codecov.io/gh/tachyonics/swift-wire/graph/badge.svg" alt="Code coverage">
  </a>
  <a href="https://swiftpackageindex.com/tachyonics/swift-wire">
    <img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Ftachyonics%2Fswift-wire%2Fbadge%3Ftype%3Dplatforms" alt="Platforms">
  </a>
  <a href="https://www.apache.org/licenses/LICENSE-2.0">
    <img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License: Apache 2.0">
  </a>
</p>

# swift-wire

> Compile-time-validated dependency injection for server-side Swift on Linux.

**Status:** pre-alpha. Nothing is built yet. The library is being designed and developed alongside `task-cluster`, a server-side Swift demonstration application, and a corresponding blog series. This README is the current design spec; expect it to iterate as task-cluster grows.

---

## What swift-wire is

swift-wire is a compile-time-validated dependency injection library, being built alongside `task-cluster` — a demonstration application that grows in complexity over time — and an accompanying blog series. The library lands new capabilities as task-cluster needs them: request-scoped observability when the HTTP layer gains tracing, lifecycle hooks when there's a DB pool to shut down cleanly, multi-module composition when task-cluster's library targets start shipping their own bindings.

The architectural commitment is an *adapter-annotation contract* — a published, versioned macro-based extension mechanism that lets third-party packages contribute framework integrations (Hummingbird, the OpenAPI generator, queue consumers, schedulers) by publishing their own annotations rather than being baked into the core. The DI core does the wiring; the contract is what turns that core into a platform other packages build against rather than a closed system that knows only its own concepts. The application domain is server-side Swift on Linux: scopes are seed-typed (`@Singleton` for process lifetime; `@Scoped(seed: X.self)` for any sibling lifetime keyed by the seed type, with adapter packages publishing convenience macros for common seeds like HTTP requests and job messages), the build plugin runs against the SPM toolchain on Linux as a first-class target, and the macro surface is shaped by Swift 6's concurrency model.

The design language is openly Java-DI shaped — `@Inject`, `@Provides`, scope macros, adapter annotations. The audience whose intuitions transfer cleanly is anyone working in annotation-based, container-driven backend DI: Spring and Dagger on the JVM, NestJS on Node.js, ASP.NET Core's built-in DI, or teams that want their Swift service to feel architecturally like the other server services they operate. The cross-section that targets Swift-server is small today; the project is partly a bet on Swift's continued growth with developers coming from a non-iOS background.

That Java-DI shape is the on-ramp; the differentiation comes from features designed around Swift's type system specifically. Two anchors. **Opaque returns from `@Provides`** (`@Provides -> some P`) preserve concrete type identity through the graph at compile time — hex-style abstraction with zero existential boxing, which JVM/.NET/Node DI frameworks structurally can't match because they lack opaque-type identity at the language level. **`BuilderKey<B>`** folds multibinding contributors through a user-defined `@resultBuilder` type, letting consumers express composition semantics no other DI framework offers because `@resultBuilder` machinery doesn't exist outside Swift. swift-wire isn't "Dagger ported to Swift"; it's an exploration of what a DI framework looks like when designed *for* Swift's type system rather than just what can be achieved in other languages. Both features have detailed design notes (`Documentation/Notes/BuilderKeyDesign.md`, `OpaqueTypesSupport.md`); they're deferred to later iterations but they're the architectural anchors that justify the project beyond a Java-DI port.

If you came here looking for a polished library to adopt, this isn't that yet. swift-dependencies is the fastest path to DI ergonomics today; SafeDI is the closest existing compile-time-safe option (iOS-shaped). swift-wire's reason for existing is the gap none of those fill — a compile-time graph extensible by third-party adapters, applied to server-side Swift on Linux, with task-cluster as the live test case.

---

## The diff that justifies the project

Below is `task-cluster`, an existing Hummingbird + OpenAPI-generator service in this workspace, rewritten with swift-wire. Compare against `secondary/task-cluster/` to see today's manual wiring.

### Today (manual wiring)

`Sources/TaskCluster/TaskCluster.swift`:

```swift
@main
struct TaskCluster {
    static func main() async throws {
        let config = ConfigReader(provider: EnvironmentVariablesProvider())
        let port = config.int(forKey: "HTTP_PORT", default: 8080)

        let logger = Logger(label: "TaskCluster")
        let table = InMemoryDynamoDBCompositePrimaryKeyTable()
        let repository = DynamoDBTaskRepository(table: table)
        let configuration = ApplicationConfiguration(address: .hostname("0.0.0.0", port: port))

        let application = try buildApplication(
            repository: repository,
            configuration: configuration,
            logger: logger
        )
        try await application.run()
    }
}
```

`Sources/TaskClusterApp/Application+build.swift`:

```swift
package func buildApplication<Repository: TaskRepository>(
    repository: Repository,
    configuration: ApplicationConfiguration,
    logger: Logger
) throws -> some ApplicationProtocol {
    let router = Router(context: BasicRequestContext.self)
    router.addMiddleware { LogRequestsMiddleware(.info) }
    router.get("/health") { _, _ in HTTPResponse.Status.ok }

    let controller = TaskController(repository: repository)
    try controller.registerHandlers(on: router)

    return Application(router: router, configuration: configuration, logger: logger)
}
```

`Sources/TaskClusterApp/TaskController.swift`:

```swift
package struct TaskController<Repository: TaskRepository>: APIProtocol {
    var repository: Repository
    // ... 4 OpenAPI handler methods
}
```

This is fine at this size. It doesn't stay fine. Add a JWT verifier, an S3 client, a metrics emitter, and a request-scoped tenant context — each depending on two or three of the others — and `TaskCluster.swift` plus `buildApplication` becomes hand-threaded wiring soup.

### With swift-wire

`Sources/TaskClusterDynamoDBModel/DynamoDBTaskRepository.swift`:

```swift
@Singleton
package struct DynamoDBTaskRepository<Table: DynamoDBCompositePrimaryKeyTable & Sendable>: TaskRepository {
    @Inject var table: Table
    // unchanged: methods use self.table directly
}
```

`Sources/TaskClusterApp/TaskController.swift`:

```swift
@Scoped(seed: HBRequestSeed.self)                   // request-scoped: one per HTTP request
@RoutedBy(Router<BasicRequestContext>.self)         // adapter annotation from WireOpenAPI
package struct TaskController<Repository: TaskRepository>: APIProtocol {
    @Inject var repository: Repository              // singleton — fine to inject from request scope
    @Inject var requestLogger: RequestLogger        // same scope — direct injection, no wrapper
    // unchanged: 4 handler methods, now call requestLogger.logger to emit
}
```

`Sources/TaskClusterApp/RequestLogger.swift` (new — but task-cluster *should* have this):

```swift
@Scoped(seed: HBRequestSeed.self)
struct RequestLogger {
    @Inject var baseLogger: Logger
    @Inject var requestID: RequestID         // provided by WireHummingbird's request scope

    var logger: Logger {
        var l = baseLogger
        l[metadataKey: "request-id"] = "\(requestID.value)"
        return l
    }
}
```

`HBRequestSeed` is the seed type that `WireHummingbird` publishes for the HTTP request scope. Two `@Scoped(seed: HBRequestSeed.self)` types share a request scope: both are constructed fresh per request, both can inject the seed and any other request-scoped value directly, and singletons (the repository, base logger) inject through unchanged.

`Sources/TaskCluster/TaskCluster.swift`:

```swift
import Wire
import WireHummingbird
import WireOpenAPI

@Provides let logger = Logger(label: "TaskCluster")
@Provides let table = InMemoryDynamoDBCompositePrimaryKeyTable()

@main
struct TaskCluster {
    static func main() async throws {
        let config = ConfigReader(provider: EnvironmentVariablesProvider())

        try await Wire.hummingbird()                // WireHummingbird is implied by the builder
            .activating(WireOpenAPI.self)           // pulls in @RoutedBy support
            .port(config.int(forKey: "HTTP_PORT", default: 8080))
            .health("/health")
            .run()
        // TaskController and DynamoDBTaskRepository are picked up automatically
        // (sibling targets in the same Package.swift); @RoutedBy contributes the
        // `controller.registerHandlers(on:)` call once WireOpenAPI is activated.
    }
}
```

What you actually get from this:

- **Generics are preserved.** `TaskController<Repository>` stays generic. `DynamoDBTaskRepository<Table>` stays generic. The build plugin specializes both at the resolution site — when there's exactly one binding for `DynamoDBCompositePrimaryKeyTable & Sendable` (the in-memory one), it picks `Table = InMemoryDynamoDBCompositePrimaryKeyTable`, and `TaskController` is constructed as `TaskController<DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>>`. No existential boxing introduced by the library.
- **The graph is validated at build time.** Forget to bind a `DynamoDBCompositePrimaryKeyTable` and Swift won't compile. Inject a `@Scoped(seed: X.self)` value as a stored property on a `@Singleton` and the build plugin refuses with a fix-it (make the consumer `@Scoped(seed: X.self)` too, or compose via a scope-appropriate wrapper).
- **`@RoutedBy` is the architectural feature, not a one-off helper.** It's an *adapter annotation* — a macro published by `WireOpenAPI` that hooks `TaskController` into the app's startup. The same mechanism powers `@JobHandler`, `@ScheduledTask`, `@WebSocketRoute`, etc., from any third-party adapter. The Wire core knows nothing about OpenAPI.
- **Tests select an alternative `@Container` at the entry point** instead of re-instantiating types with different generic arguments by hand. The chosen container is the whole graph for that test run.

If that diff doesn't look like a meaningful improvement to you, the project doesn't have a reason to exist and you should close this README.

---

## Concepts

### Scope annotations

Two built-in scope macros:

| Macro                          | Lifetime                                                | Typical contents                                     |
|--------------------------------|---------------------------------------------------------|------------------------------------------------------|
| `@Singleton`                   | process                                                 | DB pools, HTTP clients, config, metrics, base logger |
| `@Scoped(seed: SeedType.self)` | one instance per externally provided `SeedType` value   | request-derived state, per-job tenant context        |

`@Scoped` is *seed-typed*: every non-singleton scope is identified by the concrete type whose runtime instance opens it. An HTTP request scope is `@Scoped(seed: HBRequestSeed.self)`; a job scope is `@Scoped(seed: SQSMessage.self)`. The seed type is the only contract — anyone (the Wire user, an adapter package, a third party) can publish a seed type and the types scoped to it will compose naturally. Multiple seed types coexist; a single graph might host request-scoped, job-scoped, and WebSocket-session-scoped bindings simultaneously.

Singletons outlive everything. Scoped instances see singletons (and the seed value itself) but not each other across scope boundaries. Asking for a scoped type from a singleton — or from a scope keyed by a different seed — is a compile error pointing at the injection site; the fix is either widening the seed or scoping the consumer the same way.

Hierarchical seeded scopes (`@Scoped(seed:, within:)`) are a deferred decision: the data model reserves the slot, but no scope is hierarchical in 0.x. A real adopter case forces the design.

### `@Inject` and how the macro generates an init

`@Inject` marks an injection point on a stored property. The scope macro on the enclosing type generates an `init` that takes one parameter per injection point, in declaration order. The build plugin emits the actual call site: `TaskController(repository: ..., requestLogger: ...)`. You don't write the init.

The macro reads the property type as written. `var repository: Repository` keeps `TaskController` generic over `Repository`. `var repository: any TaskRepository` makes it an existential. The library is neutral — pick the one whose performance characteristics you want.

`@Inject` also recognises two post-construct forms that *don't* feed the synthesised init — `@Inject weak var` for weak storage and `@Inject func` for method-delivered dependencies. Those are covered in [Post-construction injection](#post-construction-injection) below; the constructor flow above is the default for everything else.

### Post-construction injection

Not every dependency fits the constructor flow. Two cases come up enough that Wire ships first-class support: **cycle-breaking** (two types mutually reference each other) and **delivery to custom storage** (a Mutex-wrapped weak ref, an actor-isolated mutator, an instrumentation hook). Both use `@Inject` on an attachment site other than a normal property; both are delivered after the consumer's `init` has run.

**`@Inject weak var x: T?`** is the compact spelling. Swift's `weak` modifier means the property is mutable storage that can't live in an init parameter, so Wire excludes it from the synthesised init and wires it post-construct instead. The graph treats the edge as cycle-breaking — topological sort doesn't see it as a constructor-time dependency.

```swift
@Singleton final class Coordinator {
    @Inject init(view: View) { /* ... */ }
}

@Singleton final class View {
    @Inject weak var coordinator: Coordinator?
}
```

Topo sort: `View` first (no strong deps), `Coordinator` second (takes `View`). Generated bootstrap: `view.coordinator = coordinator` after both exist. The runtime relationship is what Swift's `weak` keyword already means — non-owning, zeroing on dealloc. Wire just respects the language semantics.

**`@Inject func receive(_ x: T)`** is the general form. The user writes a method; the parameter list declares the deps; the build plugin calls the method with resolved arguments after construction. What the method *does* internally — Mutex-wrapped storage, actor messaging, instrumentation, anything — is the user's choice. Wire stays out of the storage decision.

```swift
@Singleton final class ConfigBoard: Sendable {
    private let storage = Mutex<ConfigData?>(nil)

    @Inject
    func apply(config: ConfigData) {
        storage.withLock { $0 = config }
    }
}
```

For consumers that need a custom `@Inject init` *and* post-construct deps, the two coexist: `@Inject weak var` and `@Inject func` are exempt from the "init OR properties, never both" rule because their delivery doesn't compete with the init's parameter list.

**Actor consumers.** `@Inject func` on an `actor` is the canonical "checked-Sendable + post-init wiring" pattern — actors are inherently `Sendable`, so the consumer slots into a `Sendable` `_WireGraph` without `@unchecked` workarounds. The build plugin emits `await consumer.method(args)` at the call site (the `await` pays for the isolation crossing, whether or not the method is itself declared `async`). `@Inject weak var` on actors works the same way at the use site; under the hood the build plugin synthesises a setter extension method (`_wireSet<Property>`) because direct property assignment from outside actor isolation isn't legal Swift.

Member-injection parameters still participate in graph validation: missing-binding diagnostics fire if a target isn't bound, and explicit-key disambiguation works the same way it does for constructor-injected deps. The only difference is cycle detection — member-injection edges are deferred, so a cycle that closes through one is legal (the canonical cycle-breaking case), while cycles entirely through constructor edges remain errors.

`@Inject mutating func` on a struct is rejected with a build-time error pointing at the func declaration: struct value-copy semantics mean consumers that received the struct via init would see the pre-mutation state, while only the graph-stored value would reflect the mutation — a silent divergence Wire refuses to emit. Three fix-it suggestions point at the alternatives: convert to a class, drop `mutating` and manage shared state through an internal reference (Mutex-wrapped, etc.), or deliver the dep via `@Inject init` instead.

### Crossing scopes

The common case for "a singleton needs request-scoped state" collapses if you scope the consumer to the seed instead. A `TaskController` that wants per-request logging is naturally `@Scoped(seed: HBRequestSeed.self)`, not a singleton with a deferred-resolution wrapper. Wire's adapter packages publish controller registration that constructs per-seed instances on demand — the controller goes in the request scope, the singleton stays in the process scope, and the boundary is never crossed at injection time.

When a singleton genuinely needs to *defer* construction of something within its own scope (an expensive resource not always exercised, a first-use-init pattern), the user writes a `@Provides` that returns `Lazy<T>`. `Lazy<T>` is a regular public Swift type Wire ships; consumers `@Inject` it as `Lazy<T>` and call `.get()` to materialise. There's no framework-magic recognition — the binding's type *is* `Lazy<T>`, and the user controls the factory closure:

```swift
@Provides
static func makePool(config: Config) -> Lazy<DatabasePool> {
    Lazy { DatabasePool(config: config) }
}

@Singleton
struct RequestHandler {
    @Inject var pool: Lazy<DatabasePool>
}
```

Bootstrap allocates the wrapper (cheap); the underlying `DatabasePool` materialises on first `pool.get()`, cached thereafter. For mutual-reference cycles where one side should genuinely not extend the other's lifetime, see the [post-construction injection](#post-construction-injection) section above — `@Inject weak var` is the cycle-break primitive, not `Lazy<T>` (whose edge participates in cycle detection like any other dep).

`Lazy<T>` and `@Inject weak var` aren't mutually exclusive — `@Inject weak var pool: Lazy<DatabasePool>?` is a legal injection point. The graph identity is `Lazy<DatabasePool>` (same as for any other `@Inject weak var`), and the producer side stays a regular `@Provides -> Lazy<DatabasePool>`. The weak slot points at the wrapper (held strongly by the graph), not at the materialised inner value (held by the wrapper's factory closure once `.get()` runs and by anything that retains the result). The framework doesn't special-case the composition — `Lazy<T>` is just a type and `weak` is just a language modifier, so combining them is the same code path as either alone. Useful when a deferred binding's factory closure captures the consumer back and you want the consumer's view of it to be non-owning; less common than the basic shapes but available when needed.

A general `Provider<T>` for cross-scope on-demand resolution is deferred; if a real case surfaces that neither seeded scopes, `Lazy<T>`, nor the post-construction injection forms handle, the design lands then.

### Adapter annotations (the extension mechanism)

The Wire core defines exactly: scope macros (`@Singleton`, `@Scoped`), `@Inject`, `@Container`, `@Provides`, `@Contributes`, `@Teardown`, `Lazy<T>`, `BindingKey<T>`, `CollectedKey<T>`, `MappedKey<K, V>`, `BuilderKey<B>`. Everything else — every framework integration — is an *adapter annotation*: a macro published by an adapter package that the build plugin recognizes by name and that emits registration code into the generated bootstrap.

Adapter annotations come in three forms, all supported by the contract:

- **Type-level only.** Annotates a type; contributes registration code that runs after the container resolves it. Example: `@RoutedBy(Router<C>.self)` from `WireOpenAPI` — for any type carrying it that conforms to a generated `APIProtocol`, the bootstrap calls `.registerHandlers(on:)` with the supplied router.
- **Type-level with member recognition.** Annotates a type, but also recognizes member-level annotations within it, walking the type's methods at compile time and generating per-method registration. Example: `@Controller("/tasks")` from `WireMVC` — paired with method-level `@Get("/{id}")`, `@Post`, `@Patch("/{id}")`, etc., and parameter-level `@Path`, `@Body`, `@Query`, `@Header`, it generates per-route registration plus the request-decoding and response-encoding adapter for each method.
- **Member-level only.** Annotates a method or property without a type-level marker. Less common; useful for cross-cutting concerns like `@Metric` or `@Cached`.

A `WireMVC` controller — the canonical type-level-with-member-recognition case — looks like this:

```swift
@Scoped(seed: HBRequestSeed.self)
@Controller("/tasks")
package struct TaskController {
    @Inject var repository: any TaskRepository
    @Inject var requestLogger: RequestLogger

    @Get("/{id}")
    func getTask(@Path id: UUID) async throws -> TaskItem {
        guard let task = try await repository.get(taskId: id) else {
            throw HTTPError(.notFound)
        }
        return task
    }

    @Post
    func createTask(@Body request: CreateTaskRequest) async throws -> TaskItem { ... }

    @Patch("/{id}/priority")
    func updatePriority(
        @Path id: UUID,
        @Body request: UpdatePriorityRequest
    ) async throws -> TaskItem { ... }
}
```

The build plugin walks `TaskController`'s methods, finds the ones tagged with `@Get` / `@Post` / `@Patch`, reads the parameter annotations, and generates the route registration plus request decoding and response encoding for each. The same controller could be written `@RoutedBy(...)` against an OpenAPI-generated `APIProtocol` instead — both styles are first-class and can coexist in the same app, mixed per controller.

Equivalent adapter annotations to expect from adapter packages:

- `@RoutedBy(Router<C>.self)` — `WireOpenAPI`, type-level: registers a generated `APIProtocol` conformance.
- `@Controller`, `@Get`, `@Post`, `@Patch`, `@Delete`, `@Put`, `@Path`, `@Body`, `@Query`, `@Header` — `WireMVC`, type-level with member recognition: Spring-MVC-style inline route declarations as an alternative to the OpenAPI-spec-first path.
- `@JobHandler(queue:)` — `WireSQS` / `WireRedis`, type-level: registers the type as a queue consumer.
- `@ScheduledTask(every:)` — `WireScheduling`, type-level: registers the type with a scheduler.
- `@WebSocketRoute(_)` — `WireHummingbird`, type-level: registers the type as a WebSocket handler.

Anyone can write one. The Wire core has a documented protocol that adapter annotations must implement; if you can satisfy it, your annotation works alongside everything else. The contract is designed up front to support all three forms, even though M1 ships no adapters — retrofitting member-level support after type-level adapters had already shipped would break every existing one, so the contract has to anticipate it.

#### How the contract works

Three pieces:

**1. The macro generates a `_wireRegister` extension whose parameter list declares the adapter's resolver-time dependencies directly:**

```swift
extension TaskController {
    public static func _wireRegister(
        instance: Self,
        router: Router<BasicRequestContext>
    ) async throws {
        try instance.registerHandlers(on: router)
    }
}
```

The function signature *is* the dependency declaration — there's no parallel metadata field. For type-level adapters like `@RoutedBy`, the body is one line. For type-level-with-member-recognition adapters like `@Controller`+`@Get`, the macro walks the type's annotated members at expansion time and generates the per-method registration in the body, using the supplied parameters. Member-level annotations on a type union their parameter requirements at the type-level signature. Wire core never sees inside the body's logic.

**2. A per-library manifest declares the exported annotations** — qualified name, form, phase, contract version. The consumer's build plugin reads dependency manifests (the same mechanism multi-module composition uses) and knows which annotations to recognise.

**3. The build plugin reads `_wireRegister`'s signature, validates each parameter is bound in the graph, and emits the call with concrete arguments.** For every adapter-annotated type, the plugin emits `try await Type._wireRegister(instance: ..., router: ...)` at the appropriate phase, with each argument resolved at compile time. M1 ships with one phase (post-graph, pre-services); per-request and per-job phases land when an adapter actually needs them.

The separation is strong: **adapters own their semantics, Wire core owns the bootstrap.** Adding `WireMVC` doesn't require Wire core to know about HTTP routing. Validation is structural — the function signature is read by the build plugin, and a missing binding for any parameter is a compile error pointing at the adapter annotation. There is no runtime `resolve(...)` inside `_wireRegister` and no separate metadata to keep in sync with the body.

Type expressions extracted from annotation arguments and `_wireRegister` parameter lists are normalised — interior whitespace collapsed — before binding lookup, so `Router<X, Y>` and `Router<X,Y>` resolve to the same binding regardless of how the source was formatted (M0 finding from Spike 3).

#### Contract versioning

The contract is versioned from M1. Adapters declare a target version in their manifest. If Wire later adds a parameter to `_wireRegister` (a bootstrap context, a logger, a phase hint), that's contract v2, and v1 adapters continue to work via a compatibility shim. Wire core supports the current version plus a deprecation window for prior ones. This is the cost of long-lived ABI compatibility for adapters; the alternative — breaking every adapter on a Wire upgrade — would kill the ecosystem.

#### Public API vs. SPI

The contract distinguishes two stability tiers:

- **Public API** (stable, breaking change requires a major version of Wire): `Resolver` protocol, the `_wireRegister` direct-injection convention, manifest format, phase taxonomy, the `@Teardown` annotation, runtime types (`BindingKey`, `CollectedKey`, `MappedKey`, `BuilderKey`, `Provider`), introspection types (`ResolverIntrospection`, `BindingDescription`, etc.), build-time graph JSON format.
- **SPI** (adapter authors only, can evolve within a major version): registry internals, phase ordering implementation, build-plugin internals, generated bootstrap structure.

Adapter authors building against public API are insulated from Wire's internal evolution.

### `@Provides` (and optionally `@Container`)

`@Provides` declares a binding for the dependency graph. It attaches to either a property or a function — pick whichever Swift construct fits. A property contributes a value with no dependencies; a function's parameters become its dependencies.

You only declare `@Provides` for things the graph can't construct on its own — framework primitives (a `Logger`, a config object), values produced by external systems, or concrete instances pinning a specific type for a generic constraint. Every `@Singleton` / `@Scoped(...)` type is automatically part of the graph and constructed by the build plugin without an explicit `@Provides`.

In the common case, `@Provides` declarations live at module scope and that's the entire graph:

```swift
@Provides let logger = Logger(label: "TaskCluster")
@Provides let table = InMemoryDynamoDBCompositePrimaryKeyTable()

@Provides
func repository(table: InMemoryDynamoDBCompositePrimaryKeyTable)
    -> DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>
{
    DynamoDBTaskRepository(table: table)
}
```

The build plugin aggregates every `@Provides` in the executable target into one graph. Most apps don't need anything more.

`@Container` is opt-in. It groups a set of bindings under a named type — useful in larger codebases for documenting which subsystem owns which bindings, and for swapping graphs at the entry point:

```swift
@Container
enum TestContainer {
    @Provides static let logger = Logger(label: "test")
    @Provides static let repository: any TaskRepository = MockTaskRepository()
    // ... other bindings the test graph needs
}

// Test entry point:
try await Wire.hummingbird(TestContainer.self).run()
```

When a `@Container` is selected at the entry point, that container's bindings *are* the graph for that run; module-scope `@Provides` aren't merged in. This keeps the swap atomic and avoids inheriting override semantics from day one.

Containers are flat — no parents, no children. Multiple `@Container`s in the same target merge their bindings; a collision between them is a compile error.

A binding that starts as a plain value and later needs computation just gains parameters and a body — the annotation stays. No migration between annotations as the graph evolves.

### Resolution and disambiguation

Bindings are looked up by type first, by key second. The rules:

1. **One binding matches the type** → bound automatically. No key needed at the injection site.
2. **Multiple bindings match** → compile error naming the candidates. The user disambiguates with an explicit key.
3. **No binding matches** → compile error pointing at the unsatisfied dependency.

Every `@Singleton` / `@Scoped(...)` macro auto-generates a `static let key: BindingKey<Self>` on the type. The build plugin uses these keys to identify bindings; users only ever *read* keys, and only when an ambiguity forces them to. In the common case, nothing in the user's code mentions a key.

When an ambiguity does arise — say, a second `TaskRepository` implementation lands in the graph:

```swift
@Singleton
package struct InMemoryTaskRepository: TaskRepository { ... }

// Build plugin error at TaskController:
//   error: ambiguous binding for `Repository` matching `TaskRepository`
//   candidates:
//     - DynamoDBTaskRepository<...>.key   (Sources/.../DynamoDBTaskRepository.swift:9)
//     - InMemoryTaskRepository.key        (Sources/.../InMemoryTaskRepository.swift:3)
//   fix: write `@Inject(DynamoDBTaskRepository.key) var repository: Repository`
```

The fix is mechanical — the diagnostic names the candidates and the user pastes one of the keys at the injection site. The rule extends to ambiguity on a generic type parameter (as with `TaskController<Repository: TaskRepository>`): the key selects which binding specializes the enclosing type.

There is no automatic disambiguation. No "most specific match," no declaration-order tie-breaker. If two bindings could satisfy a request, you write the key. The reason: every silent inference rule eventually surprises someone, and the cost of forcing a key is one annotation at the place the ambiguity actually exists.

#### Named keys for same-type-different-role

Auto-generated keys are tied to the providing type, which doesn't help when you have two values of the same concrete type configured differently — a primary and replica DB, two HTTP clients with different timeouts. Declare a `BindingKey` explicitly and reference it on both sides:

```swift
extension Database {
    static let primary = BindingKey<any Database>("primary")
    static let replica = BindingKey<any Database>("replica")
}

@Provides(Database.primary)
static func primary() -> some Database { ... }

@Provides(Database.replica)
static func replica() -> some Database { ... }

@Singleton
struct UserService {
    @Inject(Database.primary) var db: any Database
}
```

#### The cost of preserved generics, restated

Swift specializes generics; it doesn't erase them. With explicit-key disambiguation, the only verbosity Wire forces into user code is one `@Inject(Foo.key)` per ambiguous injection. In the unambiguous common case nothing in user code mentions a key, and concrete types appear only at the binding declaration. That's the win the strict-on-ambiguity rule is buying.

### Multibindings (`CollectedKey<T>`)

Some bindings are naturally one-of-many rather than one-and-only-one — Hummingbird's `[any Service]` for the application's lifecycle, a list of middleware, a collection of health checks. Wire handles these with a second key flavor:

```swift
public struct CollectedKey<Element>: Sendable { ... }
```

Multibindings are explicit and keyed; there is no anonymous "collect everything that conforms to `T`" sweep. To opt a type into a collection, add `@Contributes(to: SomeCollectedKey)` alongside its scope macro:

```swift
extension Service {
    static let lifecycle = CollectedKey<any Service>("lifecycle")
}

@Singleton @Contributes(to: Service.lifecycle)
struct QueueConsumer: Service { ... }

@Singleton @Contributes(to: Service.lifecycle)
struct MetricsEmitter: Service { ... }

@Singleton
struct ApplicationBuilder {
    @Inject(Service.lifecycle) var services: [any Service]
}
```

`@Contributes(to:)` is to `CollectedKey<T>` what `@Provides(_:)` is to `BindingKey<T>` — the declaration annotation for that key flavor. They're separate annotations specifically so the call site tells you which kind of binding you're looking at without having to look up the key's declaration:

- `@Provides(Database.primary)` — single-binding key; exactly one provider expected, multiple is a compile error.
- `@Contributes(to: Service.lifecycle)` — collection key; multiple contributors expected, the consumer's `[T]`-typed injection point gets all of them.

A consumer asking for `[any Service]` *without* specifying a key gets a literal-list lookup, not the collection. The two cases are different lookup paths and can coexist:

```swift
@Provides let coreServices: [any Service] = [a, b, c]   // literal, single binding

@Inject var services: [any Service]                     // → the literal list
@Inject(Service.lifecycle) var services: [any Service]  // → collected from contributors
```

#### Multiple keys per declaration

A `@Singleton` (or `@Provides` function) can carry more than one `@Contributes(to:)` annotation, or mix `@Provides(Key)` and `@Contributes(to:)`. The same instance is registered under each key, with the type system enforcing that each key's element type matches what's provided:

```swift
@Singleton
@Contributes(to: Service.lifecycle)         // started by Hummingbird
@Contributes(to: Healthcheck.allChecks)     // queried by /health
struct DatabaseHealthService: Service, Healthcheck { ... }
```

A common mixed case is a type that's both a unique singleton and a contributor to one or more collections:

```swift
@Singleton
@Provides(Database.primary)                 // unique — the canonical primary DB
@Contributes(to: Database.allConnections)   // also part of the connection-pool collection
struct PrimaryDatabase: Database { ... }
```

The instance is constructed once (singleton lifetime applies once across all keys); every lookup that resolves any of its keys gets that same instance. For `@Provides` functions with multiple key annotations, the function is invoked at most once per resolution and the result is registered under each key.

#### Ordering contributions

When the order of contributors matters — service startup is the canonical case — add `withOrder:` to the contribution. Lower numbers come first; contributions without `withOrder:` are appended after the ordered ones, in declaration order:

```swift
@Singleton @Contributes(to: Service.lifecycle, withOrder: 10)
struct MetricsEmitter: Service { ... }      // starts first

@Singleton @Contributes(to: Service.lifecycle, withOrder: 20)
struct QueueConsumer: Service { ... }       // starts after metrics

@Singleton @Contributes(to: Service.lifecycle)
struct PrometheusScraper: Service { ... }   // unspecified — appended after ordered contributors
```

Convention: leave integer gaps (10, 20, 30) so future contributors can insert without renumbering. The build plugin sorts ascending by `withOrder`, with declaration order as the tiebreaker for unspecified contributors.

Relative ordering (`before:` / `after:` references to other types) is not in scope. Topological sort over relative-order constraints introduces cycle-detection and diagnostic concerns that integer priority avoids; if a real case turns up that integers can't express, it'll be added then.

#### Map-shaped collections (`MappedKey<K, V>`)

When the collection is keyed by string, enum, or other discriminator — strategies-by-name, routes-by-prefix, formatters-by-content-type — declare a `MappedKey<K, V>` and contribute under per-entry keys with `atKey:`:

```swift
public struct MappedKey<Key: Hashable, Value>: Sendable { ... }

extension Strategy {
    static let byName = MappedKey<String, any Strategy>("byName")
}

@Singleton @Contributes(to: Strategy.byName, atKey: "fast")
struct FastStrategy: Strategy { ... }

@Singleton @Contributes(to: Strategy.byName, atKey: "thorough")
struct ThoroughStrategy: Strategy { ... }

@Singleton
struct StrategyDispatcher {
    @Inject(Strategy.byName) var strategies: [String: any Strategy]
}
```

Two contributors writing `atKey:` with the same key value is a compile error — same strict-on-ambiguity stance as `BindingKey`. The build plugin enforces parameter validity per key flavor: `withOrder:` is only meaningful for `CollectedKey`, `atKey:` is required for `MappedKey`, mixing them on the same contribution is an error.

#### Builder-shaped aggregations (`BuilderKey<B>`)

When the natural aggregation isn't a list or a map but a typed *composition* — type-preserving middleware chains (the pattern explored in the Swift HTTP server proposal), pipeline stages, or any case where each addition transforms the type signature of the result — declare a `BuilderKey<B>` whose type parameter is the builder:

```swift
public struct BuilderKey<Builder>: Sendable where Builder: ~Copyable {
    // Builder is a user-defined @resultBuilder type; its methods
    // determine both the constraints on contributors and the
    // aggregated output type.
}

extension Middleware {
    static let chain = BuilderKey<MiddlewareBuilder>("chain")
}

@Singleton @Contributes(to: Middleware.chain, withOrder: 10)
struct LogRequests: MiddlewareProtocol { ... }

@Singleton @Contributes(to: Middleware.chain, withOrder: 20)
struct Compression: MiddlewareProtocol { ... }

@Singleton
struct ApplicationBuilder {
    @Inject(Middleware.chain) var middleware: some MiddlewareProtocol
    // Concrete type at runtime: _Middleware2<LogRequests, Compression>
}
```

The build plugin orders contributors by `withOrder:`, then emits a fold function annotated with the builder's `@resultBuilder` attribute. The Swift compiler dispatches whichever builder methods the user defined (`buildBlock`, `buildPartialBlock`, `buildFinalResult`, etc.) — Wire stays out of the builder's internal protocol and emits no API-specific code. The result is a fully specialized aggregate — `_Middleware2<LogRequests, Compression>` here — with no existential boxing forced by Wire. The consumer reads it via an opaque type (`some MiddlewareProtocol`) since the concrete aggregation depends on which contributors are activated.

The builder's own where-clauses become DI constraints. If the user's builder requires matching `Input`/`Output`/`Context` across the chain, contributing a middleware with mismatched generic parameters is a compile error from the *builder's* signature, not from Wire's logic. Wire doesn't reinvent the constraint system; it threads contributors through the builder the user already wrote.

#### One annotation, four key flavors

The four key flavors form a clean progression by aggregation strategy:

- `BindingKey<T>` — single value, no aggregation
- `CollectedKey<T>` — flat collection (`[T]`)
- `MappedKey<K, V>` — keyed collection (`[K: V]`)
- `BuilderKey<B>` — result-builder aggregation, fully type-preserving

`@Contributes(to:)` is the universal contribution annotation across all four. The key's type determines what the build plugin does at the aggregation site; from the user's perspective, the contribution site looks identical regardless of key flavor.

#### Why the explicit opt-in matters

Spring's "any `List<T>` is autowired" looks convenient and is the source of the most-cited DI surprise in production: someone adds a new type that happens to conform to a marker protocol and silently joins every collection consumer for that protocol. Wire's contributor-side opt-in makes this impossible — adding `@Singleton struct X: Service` does not put `X` into any collection. To join, the contributor must explicitly write `@Contributes(to: Service.lifecycle)`, which is a deliberate annotation referencing a specific key. Refactoring conformances doesn't silently break collections; the compiler enforces that the contribution element type matches the key.

#### Open for later

- **Empty collections.** Zero contributors resolves to `[]` (or `[:]` for a map), with a build-plugin warning. Silenceable when zero is genuinely valid.
- **Relative ordering.** As noted above, `before:` / `after:` constraints aren't in scope. Defer until integer priority demonstrably can't express a real case.

### Lifecycle and teardown (`@Teardown`)

Async/throwing initialization is handled by the constructor — Swift's `init(...) async throws` covers it directly:

```swift
@Singleton
struct DatabasePool {
    let client: PostgresClient

    @Inject
    init(url: String) async throws {
        self.client = try await PostgresClient.connect(to: url)
    }
}
```

The macro propagates `await` and `try` through the resolution chain; the bootstrap becomes `try await Wire.hummingbird()...run()`. There is no `@PostConstruct`-style separate init step — Swift constructors don't need one.

Teardown is the asymmetric case (Swift has no async `deinit`). Rather than a framework-recognised protocol or a wrapper type the framework knows to unwrap, Wire marks teardown **explicitly at the binding's declaration** with `@Teardown`. There is no `Lifecycle` protocol and no `Resource<T>` — nothing for the framework to discover by a conformance probe. The graph already knows construction order; `@Teardown` just annotates which nodes have a teardown action and what it is. Two forms, for the two cases:

**Owned types — mark the teardown method:**

```swift
@Singleton
struct DatabasePool {
    let client: PostgresClient

    @Inject
    init(url: String) async throws {
        self.client = try await PostgresClient.connect(to: url)
    }

    @Teardown
    func teardown() async throws {
        try await client.shutdown()
    }
}
```

The method may be named anything and may be `private`; Wire reads its effect specifiers (`async`/`throws`) off the declaration, so the generated teardown call gets the right colour.

**Third-party or produced values — attach the action to the `@Provides`:**

```swift
@Provides
@Teardown({ (client: HTTPClient) in try await client.shutdown() })
static func httpClient() -> HTTPClient {
    HTTPClient()
}
```

The producer's return type stays the honest `HTTPClient`, so consumers `@Inject var client: HTTPClient` directly — no wrapper, no unwrap step. The teardown action is either an explicit-typed closure (as above) or a reference to a free or static function (`@Teardown(shutdownClient)`); a sync, non-throwing action is fine — it coerces into the `async throws` teardown contract. (Swift attributes take no trailing-closure sugar, so the closure is parenthesised: `@Teardown({ … })`, not `@Teardown { … }`. The closure parameter needs an explicit type — `$0`-inference doesn't reach across the attribute.)

Why explicit annotation over retroactive `Lifecycle` conformance: a recognised conformance is still framework magic (the container probes `as? Lifecycle` at runtime), it can't distinguish two bindings of the same type with different teardown needs, and it pushes a per-binding decision off the declaration and into the type system. `@Teardown` keeps teardown local, per-binding, and statically known — consistent with Wire treating `Lazy<T>` as just a type and refusing dynamic `Any.Type` lookup.

#### Scope semantics

Each scope has a teardown phase. `@Teardown`-annotated bindings within the scope are torn down in reverse dependency order — dependents before dependencies — so a `TaskRepository` that depends on `DatabasePool` tears down first, letting in-flight queries complete before the pool drains.

- **App-scope teardown** runs at process exit, plumbed through `WireHummingbird` into swift-service-lifecycle's shutdown sequence. App-scope teardown happens *after* all `Service`s have stopped, so a `DatabasePool` is torn down only after the HTTP server has finished serving the last request.
- **Request-scope teardown** runs at end of request handling, including the cancelled case. A request-scoped `RequestTransaction` that auto-rollbacks on teardown if not committed is the canonical example.
- **Job-scope teardown** runs at end of job, same scope-guard semantics.

If init throws partway through bootstrap, already-initialized teardown-annotated bindings are torn down in reverse order before the bootstrap rethrows. If a teardown action throws, the error is collected and logged; teardown continues with the next binding. The bootstrap's final result includes any collected teardown errors.

> **M1 status.** Iteration 6 ships the `@Teardown` annotation, and the build plugin *recognises and records* teardown actions, but it does **not** emit teardown calls yet — bootstrap constructs the binding and consumers inject it; nothing invokes the action. The reverse-dependency walk, scope-guarded teardown, and the failure semantics above land in M4. Until then, manual cleanup is the only teardown.

#### Service vs teardown

Two distinct mechanisms for two distinct concerns:

- **`Service`** (from swift-service-lifecycle, contributed via `@Contributes(to: Service.lifecycle)`) — types with a `run()` loop that the service group orchestrates. HTTP server, queue consumer worker, scheduled task runner.
- **`@Teardown`** — a resource cleanup step (no main loop) marked on a `@Singleton`/`@Scoped` type's method or on a `@Provides`-produced value. `DatabasePool`, `HTTPClient`, JWT verifier, anything that's a *resource* rather than a *service*.

A type can have both if it has both responsibilities, but most are one or the other. The build plugin warns at compile time if a `@Singleton` conforms to `Service` but isn't contributed to a service collection (silent "service that's never run" is a common bug).

### Multi-module composition

Wire-aware library packages — `WireSQS`, `WireOpenAPI`, internal company packages shipping shared bindings — declare their `@Singleton`s, `@Provides`, and `@Contributes` like any other module. To bring them into the consuming target's graph, the consumer **activates** the library at the entry point:

```swift
// In WireSQS package
@Singleton
public struct SQSClient {
    @Inject public init(url: URL) async throws { ... }

    @Teardown
    public func teardown() async throws { ... }
}

// In task-cluster
import WireSQS

@main
struct TaskCluster {
    static func main() async throws {
        try await Wire.hummingbird()
            .activating(WireSQS.self)             // pulls WireSQS's bindings into the graph
            .activating(WireOpenAPI.self)
            .port(8080)
            .run()
    }
}

@Singleton
struct WorkerService: Service {
    @Inject var sqs: SQSClient                    // resolves to WireSQS.SQSClient
}
```

Activation is **all-or-nothing per library**: an activated library contributes every one of its bindings — `@Singleton`s available for injection, `@Provides` available, `@Contributes` joining the relevant collections, adapter-annotated types having their `_wireRegister` called. A non-activated library contributes none. Its Swift symbols are still importable (use its types as parameters, conform to its protocols, etc. — that's what `import` always does), but `@Inject var client: SQSClient` from an unactivated library is a compile error: "no binding for `SQSClient`; activate `WireSQS` to use its bindings."

The all-or-nothing rule prevents the silent failure mode of partial activation — taking a library's `@Singleton` while its `@Contributes` partner is invisible, with the type system blessing a graph that's missing behavior the library was designed to provide as a coherent unit. A library is a unit; you take all of it or none of it.

#### Same-package vs external-package targets

Sibling library targets within the same `Package.swift` (task-cluster's `TaskClusterApp`, `TaskClusterDynamoDBModel`, etc.) are auto-activated — the package author intends all bindings together. Targets from external packages (declared as `.package(url:)`) require explicit `.activating(...)` at the consumer's entry point.

The rule: same `Package.swift` = same project = activated together. External package = third-party = explicit activation required.

#### Transitive activation is explicit

If `WireOpenAPI` references bindings declared in `WireHummingbird`, the consumer activates both:

```swift
.activating(WireHummingbird.self)
.activating(WireOpenAPI.self)
```

The build plugin detects missing transitive activations at compile time: if `WireOpenAPI`'s `_wireRegister` parameter list references `Router<BasicRequestContext>` (a binding declared in `WireHummingbird`) and `WireHummingbird` isn't activated, the diagnostic names the missing activation with a fix-it suggesting `.activating(WireHummingbird.self)`. The consumer's activation list at the entry point is always a complete statement of what's in scope — no hidden transitive activations.

#### Cross-library validation

Within the activated set, validation is the same as in-target: every `@Inject` must be satisfied somewhere across the union of activated libraries plus the consumer's own bindings. If `WireSQS.SQSClient` needs a `URL` and the consumer hasn't bound one, the diagnostic names the library and the missing binding. If two activated libraries both bind `Cache`, the consumer disambiguates with a key. `@Contributes(to:)` collections union across activated libraries; a `CollectedKey<any Service>` declared anywhere collects contributors from the activated set.

#### How it works mechanically

The build plugin running on the consuming target enumerates dependency targets via the SPM plugin context, then identifies Wire-aware libraries by the presence of a `_WireExports.swift` marker file in their sources — written manually in M1 (a one-line stub), generated by the library's own Wire build plugin in M6. M0 confirmed that `PackagePlugin` doesn't expose plugin-usage information for dependency targets, so the marker file is the committed discovery mechanism rather than the SPM-context-inspection path that would otherwise be cleaner.

For each activated Wire-aware library, the plugin reads the library's source files (M1: re-parse; M6: compile-time manifest) and aggregates `@Singleton`/`@Provides`/`@Contributes` declarations and adapter-annotated types into the graph for validation. Non-activated libraries are skipped entirely — their bindings never reach the validator and never appear in the generated bootstrap.

#### Test-only substitution

A test target activates the libraries it needs — typically a mix of production and test variants:

```swift
// In test entry point
try await Wire.hummingbird()
    .activating(WireMockSQS.self)        // mock instead of WireSQS
    .activating(WireOpenAPI.self)
    .run()
```

The production library isn't activated, so its bindings are absent from the test graph. If a test mistakenly activates both `WireSQS` and `WireMockSQS`, that's a compile error from the strict-on-ambiguity rule (two libraries binding `SQSClient`); either disambiguate with keys or activate only one.

### Concurrency and isolation

Wire respects Swift 6's isolation model rather than reinventing it. The compiler does the hard work of enforcing isolation correctness; Wire's job is to generate code that passes the checker without getting in the way.

#### The rules

1. **All bindings must be `Sendable`.** Singletons are shared across the process; scoped values cross `await` boundaries during request or job handling. The macro-generated `init(...)` from `@Inject` properties propagates Sendable requirements naturally — try to `@Inject` a non-Sendable type into a `@Singleton` and Swift rejects the generated init at compile time.

2. **Global actor isolation is honored, not reinvented.** Write `@MainActor @Singleton struct UICoordinator` and the macro reads the existing `@MainActor` attribute. Consumers of an isolated singleton from non-isolated contexts use Swift's standard `await` semantics. Wire doesn't introduce a parallel `isolation:` parameter — the language's existing mechanisms already type-check correctly.

3. **The `Resolver` protocol is `Sendable`-aware where it surfaces.** Most adapters never touch a resolver — `_wireRegister` takes its dependencies as direct parameters (see *How the contract works*). Where the resolver does appear — `Lazy<T>` deferring construction within its own scope, or an explicit escape-hatch resolution — its surface is:

    ```swift
    public protocol Resolver: Sendable {
        func resolve<T: Sendable>(_ type: T.Type) async throws -> T
        func resolve<T: Sendable>(_ key: BindingKey<T>) async throws -> T
        func resolve<T: Sendable>(_ key: CollectedKey<T>) async throws -> [T]
        // ... map-shape and other variants
    }
    ```

   Global-actor types are Sendable (the actor provides isolation), so they pass through these methods naturally. Calling `resolve` from any isolation domain is fine; the await hops happen as needed at the call site.

4. **`Lazy<T>` inherits its Sendability from `T`.** A type injecting `Lazy<DatabasePool>` is Sendable iff `DatabasePool` is. `Lazy` defers construction within the same scope — the held value is constructed on first access using the scope's normal isolation rules, with no cross-scope hop.

#### Diagnostics

The classic Spring-style "inject a request-scoped non-Sendable thing into a singleton" failure becomes a Swift compile error — Wire's structural check (scoped types can't be stored on a wider scope) fires first with a fix-it ("scope `Foo` to `HBRequestSeed`, or scope the consumer to the same seed"); the Sendable checker is a second line of defence for cases the structural check can't see (e.g., escape-hatch resolves). Wire emits a custom diagnostic to pre-empt the otherwise-confusing "synthesized init isn't Sendable" message: when a `@Singleton`-annotated type isn't `Sendable`, the build plugin reports "`@Singleton`-annotated types must conform to `Sendable`. Add `: Sendable` to the type or audit its stored properties."

#### What's deliberately deferred

- **Custom isolation domains as scope qualifiers.** "This dependency is on `MyJobActor`" is expressed as `@MyJobActor` on the type. Wire respects that without inventing a parallel `@Scoped(isolation:)` form.
- **Container-level isolation enforcement.** A `@Container(isolation: SomeActor.self)` that constrains every binding within to share an isolation domain is a plausible future direction — useful for single-threaded subsystems where coherent isolation is the architectural intent. Deferred until a concrete use case demonstrates Swift's per-type isolation isn't sufficient. Adding it post-1.0 is non-breaking; existing containers continue to work.
- **`~Copyable` types.** Singletons are shared by definition; non-copyable means single-owner. The semantics conflict; `~Copyable` types don't compose with `@Singleton`. Request- and job-scoped uses *might* work for single-consumer cases but require parallel `Resolver` overloads that haven't been designed. The ergonomic answer for now is to wrap a `~Copyable` resource in a Sendable reference type that manages scoped access internally — the same pattern Swift's standard library uses for `Mutex`. `~Copyable` injection stays out of scope through 0.x; reconsider post-1.0 if a real use case appears.

### Introspection

Wire surfaces the graph in two complementary forms — one at build time, one at runtime — for tooling, documentation, and operational diagnostics.

#### Build-time JSON dump

The build plugin emits a structured dump alongside `_WireGraph.swift` — call it `_WireGraph.json` — describing every binding in the graph, its source location, its dependencies, and the activation list. The format is part of the public API: tools depending on it get stability, with version bumps coordinated alongside the adapter-annotation contract version.

```json
{
  "wireVersion": 1,
  "executable": "TaskCluster",
  "activations": ["TaskClusterApp", "TaskClusterDynamoDBModel", "WireOpenAPI"],
  "bindings": [
    {
      "key": "BindingKey<Logger>",
      "type": "Logger",
      "kind": "provides",
      "scope": "singleton",
      "source": { "library": "TaskCluster", "file": "Sources/.../TaskCluster.swift", "line": 8 },
      "dependencies": []
    },
    {
      "key": "BindingKey<DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>>",
      "type": "DynamoDBTaskRepository<InMemoryDynamoDBCompositePrimaryKeyTable>",
      "kind": "singleton",
      "scope": "singleton",
      "source": { "library": "TaskClusterDynamoDBModel", "file": "...", "line": 9 },
      "dependencies": [
        { "key": "BindingKey<InMemoryDynamoDBCompositePrimaryKeyTable>", "site": "@Inject var table" }
      ]
    }
  ],
  "collections": [
    { "key": "CollectedKey<any Service>", "name": "Service.lifecycle",
      "contributors": [{ "type": "WorkerService", "source": {...}, "order": null }] }
  ],
  "adapters": [
    { "annotation": "WireOpenAPI.RoutedBy",
      "type": "TaskController<DynamoDBTaskRepository<...>>",
      "phase": "post-graph",
      "parameters": [...] }
  ]
}
```

The dump enables IDE integrations ("jump to binding declaration"), documentation generators, CI checks ("did the graph change in this PR?"), and ad-hoc debugging ("where is `SQSClient` coming from?"). It costs a few KB of build output and zero runtime overhead.

#### Runtime introspection

The `Resolver` exposes a read-only method returning a runtime view of the same data:

```swift
public protocol Resolver: Sendable {
    // ... existing resolve methods
    func introspect() -> ResolverIntrospection
}

public struct ResolverIntrospection: Sendable, Codable {
    public let activations: [String]
    public let bindings: [BindingDescription]
    public let collections: [CollectionDescription]
    public let adapters: [AdapterDescription]
}
```

Use cases: `/admin/wiring` endpoints, ops dashboards, runtime diagnostic logs. The structure mirrors the build-time JSON — same field names, same versioning, `Codable` for serialization. The runtime data is included in the binary by default (small for typical graphs); a build flag opts out for size-sensitive deployments, in which case `introspect()` returns an empty structure. The build-time JSON dump is unaffected — it's always written.

#### Deliberately not in scope

- **No runtime resolution via introspection.** `introspect().bindings.first(...)` returns descriptions, not values. Use `resolve(...)` for instances. Read-only by design — the service-locator pattern is excluded.
- **No runtime modification.** Bindings are fixed at compile time; introspection observes the graph, doesn't mutate it.
- **Not a substitute for compile-time validation.** Don't introspect to check whether a binding exists before using it — the compiler already guarantees that.

#### Tooling

Wire core ships the data; tooling builds on it. A `wire graph` CLI, IDE plugins, doc generators — these are community-driven and post-1.0. The build-time JSON's stability is the contract that lets such tooling exist independent of Wire core's release cadence.

### What's *not* in scope

- No SwiftUI integration.
- No service-locator escape hatch (`Wire.resolve(Foo.self)` from arbitrary code). If you need it, you pass a resolver explicitly.
- No runtime registration. The graph is fixed at build time.
- No compatibility layer with swift-dependencies. They're different models; pick one per service.
- No custom scopes through 0.x.
- **No container hierarchy.** Containers are flat. Spring's parent/child container model is the source of a lot of complexity (override semantics, scope interaction, profile inheritance) that hasn't earned its keep in concrete server-side cases. Multi-tenant is a request-scope problem; profile selection picks one of several flat containers at startup; plugins compose at the SPM module level. If a real need for hierarchy turns up post-v1 it'll be added with semantics worked out, not inherited as an assumption.
- **No fine-grained binding override across containers.** When you select a `@Container` at the entry point, it's the whole graph for that run, not an overlay on the default. "Selectively swap one binding while keeping the rest" is the next ergonomic ask post-1.0, but introducing override semantics is a big enough commitment that it stays out until there's a concrete use case it's the only answer to.
- **No `~Copyable` injection through 0.x.** All bindings are `Copyable`. Wrap move-only resources in a Sendable reference type that manages scoped access internally.
- **No container-level isolation enforcement.** Swift's per-type isolation handles correctness; container-level policies (`@Container(isolation:)`) are a deliberately deferred direction, addable post-1.0 without breaking existing code.
- **No implicit library bindings.** Adding a Wire-aware package to your dependencies makes its symbols importable but does *not* register its bindings or run any of its services. External libraries are activated only when the consumer explicitly calls `.activating(LibraryName.self)` at the entry point. This is a deliberate non-goal — Spring's classpath autoconfig surprise (adding a JAR pulls in beans that start side-effecting things) is exactly what this rule prevents.

---

## Comparison

| Library            | Compile-time graph | Linux-first | Macros | Request scope                          | Forces existentials? |
|--------------------|--------------------|-------------|--------|----------------------------------------|----------------------|
| swift-wire         | Yes                | Yes         | Yes    | First-class, type-checked              | No                   |
| SafeDI             | Yes                | Untested    | Yes    | Hierarchical, not framework-aware      | No                   |
| Needle             | Yes                | Builds; codegen tool not packaged for Linux | No (codegen) | Hierarchical | No |
| swift-dependencies | No (runtime)       | Yes         | No     | Task-locals; not statically scoped     | n/a                  |
| Swinject           | No (runtime)       | Yes         | No     | Manual                                 | n/a                  |

The table compares technical axes, but the bigger gap is structural: none of the listed libraries publishes a macro-based extension contract for third-party framework integrations. Needle has internal pluginized components but no public extension surface. SafeDI is a closed system — it knows its own concepts (`Instantiable`, `Forwarded`, `Received`) and nothing else; new framework integrations require changes to SafeDI itself. swift-dependencies and Swinject operate at the value-resolution layer with no build-time graph for packages to contribute to. swift-wire's adapter-annotation contract is the architectural difference, and retrofitting an equivalent into the others would be a redesign rather than an incremental feature.

swift-dependencies is the closest comparison along a different axis. It's the right call for teams whose mental model is iOS or SwiftUI — TCA-style dependency injection where dependencies are looked up at the point of use via `@Dependency`. swift-wire is the right call for teams whose mental model is Spring or Dagger — a build-time graph that's validated as a whole, with dependencies wired at construction. Both are legitimate; pick the one whose mental model fits your team.

Beyond the DI category, swift-wire sits at a different layer from the libraries it gets compared against. Web frameworks (Hummingbird, Vapor) own the runtime — request handling, the network, the service group. Capability-abstraction libraries define what individual dependencies look like — how a database client or HTTP client is shaped for testability and substitution. swift-wire validates and composes the graph of those dependencies at build time. The three layers compose: an app uses a web framework as its runtime, depends on capability abstractions for its building blocks, and uses swift-wire to wire them together.

---

## Roadmap

Library milestones are tied to what task-cluster needs next, not to a fixed calendar. task-cluster today is a small CRUD service over Hummingbird and the OpenAPI generator with a DynamoDB-backed repository; planned growth includes a real task executor, metrics, tracing, auth, and scheduled or background work. Each milestone below lands when task-cluster's evolution makes it the next thing to solve.

- **M0: validation spikes — complete (macOS 6.3 + Linux 6.3.1).** Four PoCs confirmed M1's design assumptions, with three derived adjustments folded in:
  - Spike 1 (cross-target source reading): PASS-with-fallback. Reading works for same-package and external-package dependencies; library discovery falls back to a `_WireExports.swift` marker file because SPM plugin-usage inspection isn't exposed.
  - Spike 2 (type-level macro walking method-level annotations): PASS. M5's `WireMVC` design is mechanically viable.
  - Spike 3 (annotation argument extraction): PASS. SwiftSyntax preserves type-expression structure verbatim, including nested- and multi-argument generics. M1 must normalise interior whitespace before binding lookup so `Router<X, Y>` and `Router<X,Y>` resolve to the same binding.
  - Spike 4 (swift-syntax pinning): PASS. `from: "601.0.0"` resolves to swift-syntax 601.0.1 identically on both platforms. Bumps to 602.x are deliberate per-Swift-release maintenance events.
- **M1: core graph.** Macros (`@Singleton`, `@Scoped`, `@Inject`, `@Container`, `@Provides`, `@Contributes`, `@Teardown`), runtime types (`Lazy<T>`, `BindingKey<T>`, `CollectedKey<T>`, `MappedKey<K, V>`, `BuilderKey<B>`), build plugin, graph validation (including cross-scope storage checks), the adapter-annotation contract v1 (designed for all three annotation forms, versioned for future evolution), multi-module composition (full cross-target validation by re-parsing dependency sources at build time; the manifest-based optimization is deferred to M6), build-time graph JSON dump (`_WireGraph.json` for tooling/CI/IDE consumption), Linux CI. task-cluster's manual wiring switches to Wire-driven construction; framework integration stays manual at this point. No public 0.x tag yet.
- **M2: `WireHummingbird` adapter.** Lands when task-cluster needs first-class request-scoped observability — likely a request-id-tagged logger or the equivalent for tracing. Includes the per-request resolver, `@WebSocketRoute` as the first ship-worthy adapter annotation (type-level form), the first concrete consumer of `CollectedKey` (the application's `[any Service]` lifecycle list), and the runtime `Resolver.introspect()` API plus an `/admin/wiring` example endpoint demonstrating it.
- **M3: `WireOpenAPI` adapter (`@RoutedBy`).** Lands when task-cluster's existing `TaskController.registerHandlers(on:)` call moves into the adapter-annotation system. Auto-wires generated `APIProtocol` conformances. The headline differentiator.
- **M4: lifecycle orchestration.** Lands when task-cluster gets a resource needing orderly shutdown — most likely the first time `AsyncHTTPClient` or a real DynamoDB client (vs the in-memory one) ships in the example. The `@Teardown` annotation exists from M1 (recognised and recorded, but inert); M4 is when the build plugin starts emitting teardown calls in reverse dependency order at scope teardown, integrating with swift-service-lifecycle for app-scope signal handling and Hummingbird's request lifecycle for request-scope teardown. Defines failure semantics (init failure tears down already-initialized bindings in reverse order; teardown failures are collected and logged).
- **M5: `WireMVC` adapter.** Lands when task-cluster has an actual use case for inline route declarations — likely an internal admin endpoint, or as a deliberate content piece contrasting `@RoutedBy`. The first type-level-with-member-recognition adapter; if the contract holds up here, it'll hold up for almost anything.
- **M6: multi-module composition optimization.** Lands when re-parsing dependency sources at build time becomes a performance problem (typically once the dependency graph is large enough that build-time cost is felt). Each library's build plugin generates a per-library compile-time manifest of its bindings; the consumer reads manifests instead of re-parsing source. Surface contract unchanged; optimization invisible to users. Multi-module composition itself ships in M1 — this milestone is purely the perf optimization.
- **Post-1.0:** custom scopes, container composition / fine-grained overrides, `WireVapor` if a Vapor variant of task-cluster materialises, anything else that came out of real use.

The ordering assumes task-cluster's roughly-expected trajectory; it'll shift if the trajectory does.

---

## Risks (so I have to look at them)

1. **swift-syntax tax.** Every Swift release breaks something. SafeDI's commit log is full of Xcode N+1 fixes. Signing up to chase swift-syntax for years is the actual cost of this project, not the design work. Mitigations: keep the macro surface small (most logic in the build plugin, which is more stable); pin swift-syntax `from: "601.0.0"` (M0 confirmed this resolves to 601.0.1 identically on Linux + macOS Swift 6.3.x); treat 602.x bumps as deliberate per-Swift-release maintenance events rather than free version drift.
2. **Audience and adoption asymmetry.** "Compile-time DI for Swift" is saturated; "Compile-time DI for server-side Swift on Linux with a JVM-shaped extension contract" is a real gap but a small one — and partly a bet that Swift continues to grow with developers coming from a non-iOS background. In the demonstration framing the primary audience is task-cluster's blog readership, with adoption downstream of that. The asymmetry to be careful about: publishing the library implicitly invites adoption, and adopters expect ongoing maintenance regardless of whether the blog series stays interesting. The "Status: pre-alpha" header should stay loud through 0.x to keep expectations calibrated.
3. **Hummingbird vs. Vapor abstraction.** Hummingbird threads context through generic parameters; Vapor uses storage on `Request`. A single library can either lean into one model and make the other adapter lossy, or use task-locals as the lowest common denominator and sacrifice some compile-time safety for request-scoped values. M2 will commit to one and the README will be updated honestly.
4. **Macro diagnostics.** The single biggest UX failure mode for compile-time DI is bad error messages when the graph is broken. M1 has to nail this. If it doesn't, the project fails on first contact.
5. **Resolution edge cases.** Strict-on-ambiguity reads cleanly on paper. Real graphs surface cases — default-implementation conformances, conditional conformances, generic protocols whose witnesses come from generic specialization — where what counts as "matching" is itself a judgment call. The build plugin has to be conservative ("when in doubt, ambiguous") to keep diagnostics honest, even at the cost of forcing keys in cases where a smarter algorithm could have picked. If users hit ambiguity errors constantly because the conservative rule is too coarse, the ergonomic story collapses regardless of how good the diagnostics are.
6. **Adapter-annotation contract churn.** The contract is the most architecturally consequential decision in M1, and it has to support three forms (type-level, member-level, type-level-with-member-recognition) from day one — retrofitting member-level support post-hoc would break every existing adapter. The direct-injection signature design (the `_wireRegister` parameter list declares dependencies) means adding a new well-known parameter is a v2 contract bump with a v1 compatibility shim, not a breaking change. Mitigation (executed in M0): both type-level (`@RoutedBy`-style, Spike 2) and type-level-with-member-recognition (`@Controller`+`@Get`-style, also Spike 2) patterns were prototyped against the contract and pass cleanly. The contract holds across both forms before any adapter ships publicly; M3 and M5's adapters can build directly against it.
7. **Features-driven-by-narrative.** The demonstration framing creates a temptation to ship features because they make for a good blog post rather than because task-cluster needs them. Each library addition should be motivated by an actual task-cluster need. `WireMVC` is the canonical test — if no task-cluster endpoint genuinely benefits from inline route declarations, don't ship the adapter just because the contract-design post wants an example. The contract still has to *support* both `@RoutedBy` and `@Controller`+`@Get` from day one for the architectural reasons above, but the public `WireMVC` adapter ships only if there's a real use for it.
8. **Isolation handling untested through 0.x.** task-cluster's planned trajectory exercises `Sendable` extensively but doesn't naturally use global-actor isolation (no `@MainActor` on a server) or actor-isolated job processors (the planned task executor is structured-concurrency-shaped, not actor-shaped). The basic Sendable rule will be validated; the harder isolation corners — global actors, custom-actor scope crossings — won't appear in the example application. If Wire is adopted by code with richer isolation patterns, latent design issues may surface that task-cluster's validation didn't catch. Mitigation: be honest about this gap; treat any external adoption of isolation-heavy code as an early test that may produce design issues to fix.

---

## Why "wire"?

It's what the library does, it's short, it's available on the package index, and it has prior art (Google's `wire` is the Go ecosystem's compile-time DI library — the design lineage is honest about itself).
