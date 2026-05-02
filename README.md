# swift-wire

> Compile-time-validated dependency injection for server-side Swift on Linux.

**Status:** pre-alpha. Nothing is built yet. The library is being designed and developed alongside `task-cluster`, a server-side Swift demonstration application, and a corresponding blog series. This README is the current design spec; expect it to iterate as task-cluster grows.

---

## What swift-wire is

swift-wire is a compile-time-validated dependency injection library for server-side Swift on Linux, being built alongside `task-cluster` — a demonstration application that grows in complexity over time — and an accompanying blog series. The library lands new capabilities as task-cluster needs them: request-scoped observability when the HTTP layer gains tracing, lifecycle hooks when there's a DB pool to shut down cleanly, multi-module composition when task-cluster's library targets start shipping their own bindings.

The design intent is to explore what compile-time DI looks like when it's shaped for a server runtime instead of an iOS app: macros plus an SPM build plugin producing a graph that's validated at build time, hierarchical scopes (`@Singleton`, `@RequestScope`, `@JobScope`) defined in terms of server lifecycles, and an adapter-annotation contract that lets framework integrations (Hummingbird, the OpenAPI generator, Vapor, queue consumers) hook in by publishing their own annotations rather than by being baked into the core. The design language is borrowed from Java DI (`@Inject`, `@Provides`, adapter annotations); the implementation is Swift 6 and Linux-first.

If you came here looking for a polished library to adopt, this isn't that yet. swift-dependencies is the fastest path to DI ergonomics today; SafeDI is the closest existing compile-time-safe option (iOS-shaped). swift-wire's reason for existing is the gap none of those fill — Linux-first, server-shaped, with task-cluster as the live test case — combined with the fact that I expect to use it in my own services as task-cluster grows. Adoption is welcome but downstream of the exploration; expect iteration through 0.x.

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
@Singleton
@RoutedBy(Router<BasicRequestContext>.self)         // adapter annotation from WireOpenAPI
package struct TaskController<Repository: TaskRepository>: APIProtocol {
    @Inject var repository: Repository
    @Inject var requestLogger: Provider<RequestLogger>   // crosses scope: resolved per request
    // unchanged: 4 handler methods, now call requestLogger().logger to emit
}
```

`Sources/TaskClusterApp/RequestLogger.swift` (new — but task-cluster *should* have this):

```swift
@RequestScope
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
- **The graph is validated at build time.** Forget to bind a `DynamoDBCompositePrimaryKeyTable` and Swift won't compile. Inject a `@RequestScope` value as a stored property on a `@Singleton` and the macro refuses (you have to wrap it in `Provider<…>` or make the consumer request-scoped).
- **`@RoutedBy` is the architectural feature, not a one-off helper.** It's an *adapter annotation* — a macro published by `WireOpenAPI` that hooks `TaskController` into the app's startup. The same mechanism powers `@JobHandler`, `@ScheduledTask`, `@WebSocketRoute`, etc., from any third-party adapter. The Wire core knows nothing about OpenAPI.
- **Tests select an alternative `@Container` at the entry point** instead of re-instantiating types with different generic arguments by hand. The chosen container is the whole graph for that test run.

If that diff doesn't look like a meaningful improvement to you, the project doesn't have a reason to exist and you should close this README.

---

## Concepts

### Scope annotations

Three built-in scope macros, all defined in terms of server lifecycles:

| Macro            | Lifetime                  | Typical contents                                        |
|------------------|---------------------------|---------------------------------------------------------|
| `@Singleton`     | process                   | DB pools, HTTP clients, config, metrics, base logger    |
| `@RequestScope`  | one HTTP request          | request ID, authenticated principal, request-scoped log |
| `@JobScope`      | one queue/background task | job ID, tenant context for a worker                     |

Scopes form a strict hierarchy: singletons outlive everything; request and job scopes each see singletons but not each other. Asking for a narrower scope as a stored property of a wider one is a compile error. To cross the boundary, inject `Provider<T>` and call it to resolve a fresh `T` in the appropriate scope.

Custom scopes are out of scope through 0.x. They'll be added when a real use case turns up that doesn't fit these three.

### `@Inject` and how the macro generates an init

`@Inject` marks an injection point on a stored property. The scope macro on the enclosing type generates an `init` that takes one parameter per injection point, in declaration order. The build plugin emits the actual call site: `TaskController(repository: ..., requestLogger: ...)`. You don't write the init.

The macro reads the property type as written. `var repository: Repository` keeps `TaskController` generic over `Repository`. `var repository: any TaskRepository` makes it an existential. The library is neutral — pick the one whose performance characteristics you want.

### `Provider<T>` for crossing scopes

A `@Singleton` cannot store a `@RequestScope` value directly — it would outlive the scope. Inject `Provider<T>` instead; calling it resolves a fresh `T` in the active request scope. This is the standard Java DI pattern (Dagger's `Provider`, Spring's `ObjectProvider`). The macro and build plugin enforce it: missing `Provider<…>` wrapping is a compile error with a fix-it.

### Adapter annotations (the extension mechanism)

The Wire core defines exactly: scope macros, `@Inject`, `@Container`, `@Provides`, `@Contributes`, `Provider<T>`, `BindingKey<T>`, `CollectedKey<T>`, `MappedKey<K, V>`, `BuilderKey<B>`, `Lifecycle`, `Resource<T>`. Everything else — every framework integration — is an *adapter annotation*: a macro published by an adapter package that the build plugin recognizes by name and that emits registration code into the generated bootstrap.

Adapter annotations come in three forms, all supported by the contract:

- **Type-level only.** Annotates a type; contributes registration code that runs after the container resolves it. Example: `@RoutedBy(Router<C>.self)` from `WireOpenAPI` — for any type carrying it that conforms to a generated `APIProtocol`, the bootstrap calls `.registerHandlers(on:)` with the supplied router.
- **Type-level with member recognition.** Annotates a type, but also recognizes member-level annotations within it, walking the type's methods at compile time and generating per-method registration. Example: `@Controller("/tasks")` from `WireMVC` — paired with method-level `@Get("/{id}")`, `@Post`, `@Patch("/{id}")`, etc., and parameter-level `@Path`, `@Body`, `@Query`, `@Header`, it generates per-route registration plus the request-decoding and response-encoding adapter for each method.
- **Member-level only.** Annotates a method or property without a type-level marker. Less common; useful for cross-cutting concerns like `@Metric` or `@Cached`.

A `WireMVC` controller — the canonical type-level-with-member-recognition case — looks like this:

```swift
@Singleton
@Controller("/tasks")
package struct TaskController {
    @Inject var repository: any TaskRepository
    @Inject var requestLogger: Provider<RequestLogger>

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

- **Public API** (stable, breaking change requires a major version of Wire): `Resolver` protocol, the `_wireRegister` direct-injection convention, manifest format, phase taxonomy, runtime types (`BindingKey`, `CollectedKey`, `MappedKey`, `BuilderKey`, `Provider`, `Lifecycle`, `Resource`), introspection types (`ResolverIntrospection`, `BindingDescription`, etc.), build-time graph JSON format.
- **SPI** (adapter authors only, can evolve within a major version): registry internals, phase ordering implementation, build-plugin internals, generated bootstrap structure.

Adapter authors building against public API are insulated from Wire's internal evolution.

### `@Provides` (and optionally `@Container`)

`@Provides` declares a binding for the dependency graph. It attaches to either a property or a function — pick whichever Swift construct fits. A property contributes a value with no dependencies; a function's parameters become its dependencies.

You only declare `@Provides` for things the graph can't construct on its own — framework primitives (a `Logger`, a config object), values produced by external systems, or concrete instances pinning a specific type for a generic constraint. Every `@Singleton` / `@RequestScope` / `@JobScope` type is automatically part of the graph and constructed by the build plugin without an explicit `@Provides`.

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

Every `@Singleton` / `@RequestScope` / `@JobScope` macro auto-generates a `static let key: BindingKey<Self>` on the type. The build plugin uses these keys to identify bindings; users only ever *read* keys, and only when an ambiguity forces them to. In the common case, nothing in the user's code mentions a key.

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

When the natural aggregation isn't a list or a map but a typed *composition* — Hummingbird-style middleware chains where each addition is folded into the previous result via a result builder — declare a `BuilderKey<B>` whose type parameter is the builder:

```swift
public struct BuilderKey<Builder>: Sendable where Builder: ~Copyable {
    // Builder is typically a @resultBuilder type; its buildPartialBlock signatures
    // determine both the constraints on contributors and the aggregated output type.
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

The build plugin orders contributors by `withOrder:`, then generates a fold over the builder's `buildPartialBlock` calls. The result is a fully specialized aggregate — `_Middleware2<LogRequests, Compression>` here — with no existential boxing forced by Wire. The consumer reads it via an opaque type (`some MiddlewareProtocol`) since the concrete aggregation depends on which contributors are activated.

The builder's own where-clauses become DI constraints. If `MiddlewareBuilder.buildPartialBlock` requires matching `Input`/`Output`/`Context` across the chain, contributing a middleware with mismatched generic parameters is a compile error from the *builder's* signature, not from Wire's logic. Wire doesn't reinvent the constraint system; it threads contributors through the builder the user already wrote.

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

### Lifecycle (`Lifecycle` and `Resource<T>`)

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

Teardown is the asymmetric case (Swift has no async `deinit`), so Wire defines a `Lifecycle` protocol for resources that own a teardown step:

```swift
public protocol Lifecycle: Sendable {
    func teardown() async throws
}
```

Owned types conform directly:

```swift
@Singleton
struct DatabasePool: Lifecycle {
    let client: PostgresClient

    @Inject
    init(url: String) async throws {
        self.client = try await PostgresClient.connect(to: url)
    }

    func teardown() async throws {
        try await client.shutdown()
    }
}
```

For third-party types — `HTTPClient`, an SDK client, anything you can't add a conformance to — wrap in `Resource<T>` at the `@Provides` site:

```swift
public struct Resource<Value>: Lifecycle {
    public let value: Value
    private let onTeardown: @Sendable () async throws -> Void

    public init(_ value: Value, teardown: @Sendable @escaping () async throws -> Void) {
        self.value = value
        self.onTeardown = teardown
    }

    public func teardown() async throws {
        try await onTeardown()
    }
}

@Provides
static func httpClient() -> Resource<HTTPClient> {
    let client = HTTPClient()
    return Resource(client) { try await client.shutdown() }
}
```

Consumers `@Inject var client: HTTPClient` directly — the resolver recognises `Resource<T>` as a marker at the `@Provides` site, registers the unwrapped `T` as the lookup type, and records the teardown closure with the scope. `Resource<T>` is a wrapper for declaration, not for consumption.

#### Scope semantics

Each scope has a teardown phase. Resources within the scope are torn down in reverse dependency order — dependents before dependencies — so a `TaskRepository` that depends on `DatabasePool` tears down first, letting in-flight queries complete before the pool drains.

- **App-scope teardown** runs at process exit, plumbed through `WireHummingbird` into swift-service-lifecycle's shutdown sequence. App-scope teardown happens *after* all `Service`s have stopped, so a `DatabasePool` is torn down only after the HTTP server has finished serving the last request.
- **Request-scope teardown** runs at end of request handling, including the cancelled case. A request-scoped `RequestTransaction` that auto-rollbacks on teardown if not committed is the canonical example.
- **Job-scope teardown** runs at end of job, same scope-guard semantics.

If init throws partway through bootstrap, already-initialized resources are torn down in reverse order before the bootstrap rethrows. If a `teardown()` throws, the error is collected and logged; teardown continues with the next resource. The bootstrap's final result includes any collected teardown errors.

#### Service vs Lifecycle

Two distinct mechanisms for two distinct concerns:

- **`Service`** (from swift-service-lifecycle, contributed via `@Contributes(to: Service.lifecycle)`) — types with a `run()` loop that the service group orchestrates. HTTP server, queue consumer worker, scheduled task runner.
- **`Lifecycle`** (Wire's protocol) — types with a `teardown()` step but no main loop. `DatabasePool`, `HTTPClient`, JWT verifier, anything that's a *resource* rather than a *service*.

A type can implement both if it has both responsibilities, but most are one or the other. The build plugin warns at compile time if a `@Singleton` conforms to `Service` but isn't contributed to a service collection (silent "service that's never run" is a common bug).

### Multi-module composition

Wire-aware library packages — `WireSQS`, `WireOpenAPI`, internal company packages shipping shared bindings — declare their `@Singleton`s, `@Provides`, and `@Contributes` like any other module. To bring them into the consuming target's graph, the consumer **activates** the library at the entry point:

```swift
// In WireSQS package
@Singleton
public struct SQSClient: Lifecycle {
    @Inject public init(url: URL) async throws { ... }
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

1. **All bindings must be `Sendable`.** Singletons are shared across the process; request- and job-scoped values cross `await` boundaries during request handling. The macro-generated `init(...)` from `@Inject` properties propagates Sendable requirements naturally — try to `@Inject` a non-Sendable type into a `@Singleton` and Swift rejects the generated init at compile time.

2. **Global actor isolation is honored, not reinvented.** Write `@MainActor @Singleton struct UICoordinator` and the macro reads the existing `@MainActor` attribute. Consumers of an isolated singleton from non-isolated contexts use Swift's standard `await` semantics. Wire doesn't introduce a parallel `isolation:` parameter — the language's existing mechanisms already type-check correctly.

3. **The `Resolver` protocol is `Sendable`-aware where it surfaces.** Most adapters never touch a resolver — `_wireRegister` takes its dependencies as direct parameters (see *How the contract works*). Where the resolver does appear — `Provider<T>` resolving lazily into a request scope, or an explicit escape-hatch resolution — its surface is:

    ```swift
    public protocol Resolver: Sendable {
        func resolve<T: Sendable>(_ type: T.Type) async throws -> T
        func resolve<T: Sendable>(_ key: BindingKey<T>) async throws -> T
        func resolve<T: Sendable>(_ key: CollectedKey<T>) async throws -> [T]
        // ... map-shape and other variants
    }
    ```

   Global-actor types are Sendable (the actor provides isolation), so they pass through these methods naturally. Calling `resolve` from any isolation domain is fine; the await hops happen as needed at the call site.

4. **`Provider<T>` inherits its Sendability from `T`.** A `@Singleton` injecting `Provider<RequestLogger>` is Sendable iff `RequestLogger` is. Calling `provider()` from inside the singleton hops to whatever isolation the request scope dictates, governed by Swift's normal rules.

#### Diagnostics

The classic Spring-style "inject a request-scoped non-Sendable thing into a singleton" failure becomes a Swift compile error from the standard isolation checker, not a runtime surprise. Wire emits a custom diagnostic to pre-empt the otherwise-confusing "synthesized init isn't Sendable" message: when a `@Singleton`-annotated type isn't `Sendable`, the build plugin reports "`@Singleton`-annotated types must conform to `Sendable`. Add `: Sendable` to the type or audit its stored properties."

#### What's deliberately deferred

- **Custom isolation domains as scope qualifiers.** "This dependency is on `MyJobActor`" is expressed as `@MyJobActor` on the type. Wire respects that without inventing a parallel `@JobScope(isolation:)` form.
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

The honest read: SafeDI is the closest existing thing, and the gap swift-wire fills is "designed for the server" rather than a fundamentally different mechanism. If SafeDI added Linux CI, framework adapters, a `.request` scope, and an adapter-annotation extension model in its native language, swift-wire would be redundant. Whether it will is anyone's guess — but the project has been at one maintainer for two years.

---

## Roadmap

Library milestones are tied to what task-cluster needs next, not to a fixed calendar. task-cluster today is a small CRUD service over Hummingbird and the OpenAPI generator with a DynamoDB-backed repository; planned growth includes a real task executor, metrics, tracing, auth, and scheduled or background work. Each milestone below lands when task-cluster's evolution makes it the next thing to solve.

- **M0: validation spikes — complete (macOS 6.3 + Linux 6.3.1).** Four PoCs confirmed M1's design assumptions, with three derived adjustments folded in:
  - Spike 1 (cross-target source reading): PASS-with-fallback. Reading works for same-package and external-package dependencies; library discovery falls back to a `_WireExports.swift` marker file because SPM plugin-usage inspection isn't exposed.
  - Spike 2 (type-level macro walking method-level annotations): PASS. M5's `WireMVC` design is mechanically viable.
  - Spike 3 (annotation argument extraction): PASS. SwiftSyntax preserves type-expression structure verbatim, including nested- and multi-argument generics. M1 must normalise interior whitespace before binding lookup so `Router<X, Y>` and `Router<X,Y>` resolve to the same binding.
  - Spike 4 (swift-syntax pinning): PASS. `from: "601.0.0"` resolves to swift-syntax 601.0.1 identically on both platforms. Bumps to 602.x are deliberate per-Swift-release maintenance events.
- **M1: core graph.** Macros (`@Singleton`, `@RequestScope`, `@JobScope`, `@Inject`, `@Container`, `@Provides`, `@Contributes`), runtime types (`Provider<T>`, `BindingKey<T>`, `CollectedKey<T>`, `MappedKey<K, V>`, `BuilderKey<B>`, `Lifecycle`, `Resource<T>`), build plugin, graph validation, the adapter-annotation contract v1 (designed for all three annotation forms, versioned for future evolution), multi-module composition (full cross-target validation by re-parsing dependency sources at build time; the manifest-based optimization is deferred to M6), build-time graph JSON dump (`_WireGraph.json` for tooling/CI/IDE consumption), Linux CI. task-cluster's manual wiring switches to Wire-driven construction; framework integration stays manual at this point. No public 0.x tag yet.
- **M2: `WireHummingbird` adapter.** Lands when task-cluster needs first-class request-scoped observability — likely a request-id-tagged logger or the equivalent for tracing. Includes the per-request resolver, `@WebSocketRoute` as the first ship-worthy adapter annotation (type-level form), the first concrete consumer of `CollectedKey` (the application's `[any Service]` lifecycle list), and the runtime `Resolver.introspect()` API plus an `/admin/wiring` example endpoint demonstrating it.
- **M3: `WireOpenAPI` adapter (`@RoutedBy`).** Lands when task-cluster's existing `TaskController.registerHandlers(on:)` call moves into the adapter-annotation system. Auto-wires generated `APIProtocol` conformances. The headline differentiator.
- **M4: lifecycle orchestration.** Lands when task-cluster gets a resource needing orderly shutdown — most likely the first time `AsyncHTTPClient` or a real DynamoDB client (vs the in-memory one) ships in the example. The `Lifecycle` protocol and `Resource<T>` wrapper exist from M1; M4 is when the build plugin starts walking them in reverse dependency order at scope teardown, integrating with swift-service-lifecycle for app-scope signal handling and Hummingbird's request lifecycle for request-scope teardown. Defines failure semantics (init failure tears down already-initialized resources in reverse order; teardown failures are collected and logged).
- **M5: `WireMVC` adapter.** Lands when task-cluster has an actual use case for inline route declarations — likely an internal admin endpoint, or as a deliberate content piece contrasting `@RoutedBy`. The first type-level-with-member-recognition adapter; if the contract holds up here, it'll hold up for almost anything.
- **M6: multi-module composition optimization.** Lands when re-parsing dependency sources at build time becomes a performance problem (typically once the dependency graph is large enough that build-time cost is felt). Each library's build plugin generates a per-library compile-time manifest of its bindings; the consumer reads manifests instead of re-parsing source. Surface contract unchanged; optimization invisible to users. Multi-module composition itself ships in M1 — this milestone is purely the perf optimization.
- **Post-1.0:** custom scopes, container composition / fine-grained overrides, `WireVapor` if a Vapor variant of task-cluster materialises, anything else that came out of real use.

The ordering assumes task-cluster's roughly-expected trajectory; it'll shift if the trajectory does.

---

## Risks (so I have to look at them)

1. **swift-syntax tax.** Every Swift release breaks something. SafeDI's commit log is full of Xcode N+1 fixes. Signing up to chase swift-syntax for years is the actual cost of this project, not the design work. Mitigations: keep the macro surface small (most logic in the build plugin, which is more stable); pin swift-syntax `from: "601.0.0"` (M0 confirmed this resolves to 601.0.1 identically on Linux + macOS Swift 6.3.x); treat 602.x bumps as deliberate per-Swift-release maintenance events rather than free version drift.
2. **Audience and adoption asymmetry.** "Compile-time DI for Swift" is saturated; "Compile-time DI for server-side Swift on Linux" is a real gap but a small one. In the demonstration framing the primary audience is task-cluster's blog readership, with adoption downstream of that. The asymmetry to be careful about: publishing the library implicitly invites adoption, and adopters expect ongoing maintenance regardless of whether the blog series stays interesting. The "Status: pre-alpha" header should stay loud through 0.x to keep expectations calibrated.
3. **Hummingbird vs. Vapor abstraction.** Hummingbird threads context through generic parameters; Vapor uses storage on `Request`. A single library can either lean into one model and make the other adapter lossy, or use task-locals as the lowest common denominator and sacrifice some compile-time safety for request-scoped values. M2 will commit to one and the README will be updated honestly.
4. **Macro diagnostics.** The single biggest UX failure mode for compile-time DI is bad error messages when the graph is broken. M1 has to nail this. If it doesn't, the project fails on first contact.
5. **Resolution edge cases.** Strict-on-ambiguity reads cleanly on paper. Real graphs surface cases — default-implementation conformances, conditional conformances, generic protocols whose witnesses come from generic specialization — where what counts as "matching" is itself a judgment call. The build plugin has to be conservative ("when in doubt, ambiguous") to keep diagnostics honest, even at the cost of forcing keys in cases where a smarter algorithm could have picked. If users hit ambiguity errors constantly because the conservative rule is too coarse, the ergonomic story collapses regardless of how good the diagnostics are.
6. **Adapter-annotation contract churn.** The contract is the most architecturally consequential decision in M1, and it has to support three forms (type-level, member-level, type-level-with-member-recognition) from day one — retrofitting member-level support post-hoc would break every existing adapter. The direct-injection signature design (the `_wireRegister` parameter list declares dependencies) means adding a new well-known parameter is a v2 contract bump with a v1 compatibility shim, not a breaking change. Mitigation (executed in M0): both type-level (`@RoutedBy`-style, Spike 2) and type-level-with-member-recognition (`@Controller`+`@Get`-style, also Spike 2) patterns were prototyped against the contract and pass cleanly. The contract holds across both forms before any adapter ships publicly; M3 and M5's adapters can build directly against it.
7. **Features-driven-by-narrative.** The demonstration framing creates a temptation to ship features because they make for a good blog post rather than because task-cluster needs them. Each library addition should be motivated by an actual task-cluster need. `WireMVC` is the canonical test — if no task-cluster endpoint genuinely benefits from inline route declarations, don't ship the adapter just because the contract-design post wants an example. The contract still has to *support* both `@RoutedBy` and `@Controller`+`@Get` from day one for the architectural reasons above, but the public `WireMVC` adapter ships only if there's a real use for it.
8. **Isolation handling untested through 0.x.** task-cluster's planned trajectory exercises `Sendable` extensively but doesn't naturally use global-actor isolation (no `@MainActor` on a server) or actor-isolated job processors (the planned task executor is structured-concurrency-shaped, not actor-shaped). The basic Sendable rule will be validated; the harder isolation corners — global actors, custom-actor scope crossings — won't appear in the example application. If Wire is adopted by code with richer isolation patterns, latent design issues may surface that task-cluster's validation didn't catch. Mitigation: be honest about this gap; treat any external adoption of isolation-heavy code as an early test that may produce design issues to fix.

---

## Why "wire"?

It's what the library does, it's short, it's available on the package index, and it has prior art (Google's `wire` is the Go ecosystem's compile-time DI library — the design lineage is honest about itself).
