# Teardown emission — design note (M4)

> **Status:** the plan for M4, lifecycle orchestration. The *semantics* are already
> specified in the README's **Lifecycle and teardown** section (reverse-dependency
> order, app-scope-via-service-lifecycle, failure handling); M1 ships the `@Teardown`
> annotation and **records** each action (`TeardownAction`) but **emits nothing**. M4
> makes it live: the reverse-dependency teardown walk, the app-scope lifecycle seam,
> and the failure semantics. This note is the implementation plan and the graph/adapter
> surface — it does not re-specify the annotation (see the README).

## What M4 is

Emit the teardown the README already describes. `@Teardown` marks which bindings have a
cleanup action and what it is (owned-type member form — a `@Teardown func` on a
`@Singleton`/`@Scoped`; producer form — `@Teardown(<action>)` on a `@Provides`). The
graph already knows construction order; M4 emits the **reverse** of it at scope
teardown, calling each recorded action.

**App-scope only.** Request- and job-scope teardown need scope-entry/exit machinery
that is M5 (request scope is M5). M4 is the app scope: teardown at process shutdown.

**The forcing case is task-cluster's move to the Soto AWS stack.** `AWSClient` is the
canonical *resource, not a service* — no `run()` loop, just `try await client.shutdown()`.
The reference branch does that shutdown *manually* after `application.run()`; M4 is
where it becomes a wired `@Teardown` Wire fires at app-scope shutdown.

## The teardown surface mirrors `Introspectable`

M3's introspection surface transfers directly. Wire Core already emits `func introspect()`
on every graph struct and conforms it to a public `Introspectable`; teardown is the same
shape:

```swift
// Wire Core
public protocol Teardownable {
    func teardown() async -> [any Error]
}
```

- The build plugin emits `func teardown() async -> [any Error]` on each graph struct —
  the reverse-construction-order walk (below) — and conforms the struct to `Teardownable`
  (`internal struct _WireGraph: Introspectable, Teardownable { … }`).
- A facade takes `some Teardownable` to drive shutdown without naming the internal
  concrete `_WireGraph`, exactly as `mountIntrospection(_ graph: some Introspectable)` does.
- `teardown()` **collects** rather than throws — a failing action must not stop the ones
  after it (below), so the method returns the collected errors for the caller to log.
  (Alternative considered: `async throws` with an aggregate error. Returning `[any Error]`
  keeps "continue past failures" in the type and lets the adapter own logging.)

## The reverse-dependency walk

Construction order is the topological order the emitter already iterates to build the
struct. Teardown iterates it **in reverse**, so dependents tear down before their
dependencies (a `TaskRepository` before the `DatabasePool` it holds — in-flight work
drains before the resource does). Only bindings carrying a `TeardownAction` emit a call;
the rest are skipped.

```swift
func teardown() async -> [any Error] {
    var errors: [any Error] = []
    // reverse construction order
    do { try await self.taskController.teardown() } catch { errors.append(error) }   // member form
    do { try await shutdownClient(self.awsClient) } catch { errors.append(error) }    // producer form
    return errors
}
```

- **Member form** → `try await self.<property>.<method>()`; the `async`/`throws` colour
  comes from the recorded action's effect specifiers.
- **Producer form** → the recorded action expression applied to the produced value
  (`self.<property>`); treated as `async throws` at the call site (a sync action coerces).
- Each call is wrapped so a throw is **collected**, not propagated — teardown continues
  to the next binding. This is the *happy-path* failure handling (M4.1).

## App-scope integration — WireHummingbird

The `apply` seam already reserves this: *"Once `@Teardown` emission lands (M4), a
graph-teardown `Service` prepends here so it shuts down last."* WireHummingbird ships:

```swift
// WireHummingbird
struct GraphTeardownService: Service {
    let graph: any Teardownable
    let logger: Logger
    func run() async throws {
        try await gracefulShutdown()          // suspend until the group shuts down
        for error in await graph.teardown() { logger.error("teardown: \(error)") }
    }
}
```

`apply` **prepends** it to the `[any Service]` it returns, so ServiceLifecycle's
reverse-order shutdown runs it **last** — app-scope teardown happens *after* every
`Service` (including the HTTP server) has stopped, so a `DatabasePool` drains only after
the last request is served. The concrete graph conforms to `Teardownable`, so `apply`
constructs the service from the same `graph` it already receives.

**To verify (spike):** the ordering of the graph-teardown service relative to
Hummingbird's own server service inside the `ServiceGroup` — the M2 lifecycle work
already "verified against Hummingbird's reverse-order `ServiceGroup` shutdown," so this
extends that check rather than opening it fresh.

## Init-failure partial teardown — deferred to M7c

Distinct from `graph.teardown()`: if an init throws **partway through bootstrap**, the
already-constructed teardown-annotated bindings must be torn down in reverse before the
bootstrap rethrows — and the graph struct doesn't exist yet, so this can't go through
`Teardownable`. It's codegen inside `_wireBootstrap()`: track which bindings are built and,
on a throw, run the reverse teardown over the built set, then rethrow.

**This is deferred to M7c (dynamic construction scheduling), not an M4 sub-step.** The
reason is coupling: what "the already-constructed set" *is*, and how it's inspected, is
fixed by the construction scheduler. Under today's strict sequential chain it's a **linear
prefix** (wrap each `let` in `do`/`catch`, tear down the prefix). Under M7c's dynamic
*ready-as-deps-resolve* form it's **whichever `AtomicState<T>` cells reached `.resolved`**
when the `TaskGroup` cancelled — a runtime-determined, non-linear set. Implementing it now
against the sequential chain would be rewritten wholesale when the scheduler changes, so it
lands once, against the final model. See [EffectAwareResolution.md](EffectAwareResolution.md),
*Strict per-level vs dynamic ready-as-deps-resolve*.

Nothing in M4 forces it: the Soto gate's inits (`AWSClient()`, `DynamoDB(client:…)`,
`SotoDynamoDBCompositePrimaryKeyTable(…)`) are synchronous and non-throwing, and a bootstrap
init-failure almost always ends in process exit, so the OS reclaims the half-built
resources. It lands with M7c — or earlier if a concrete adopter hits a throwing init that
coexists with a constructed `@Teardown` binding — with a fixture asserting the earlier
binding's action fired. **Happy-path `teardown()` is unaffected:** it walks the *static*
topological order in reverse, independent of the runtime scheduler.

## task-cluster adoption (the gate)

`ApplicationWiring` grows the resource chain, replacing the in-memory table (dropped —
no fallback branch). Shapes as `@Provides` bindings:

```swift
@Provides
@Teardown({ (client: AWSClient) in try await client.shutdown() })
static func awsClient() -> AWSClient { AWSClient() }

@Provides
static func dynamoDB(client: AWSClient) -> SotoDynamoDB.DynamoDB {
    .init(client: client, region: .init(rawValue: region), endpoint: endpoint)
}

@Provides
static func table(dynamoDB: SotoDynamoDB.DynamoDB) -> some DynamoDBCompositePrimaryKeyTable & Sendable {
    SotoDynamoDBCompositePrimaryKeyTable(tableName: tableName, client: dynamoDB)
}
```

`DynamoDBTaskRepository` is unchanged (generic over `Table`). Config (`TASK_TABLE_NAME`,
`AWS_REGION`, `AWS_ENDPOINT_URL`) enters as `@Provides` reads of a `ConfigReader` binding
— the eventual `@OpenAPIConfiguration`/WireConfiguration adapter is not a dependency here.
The teardown chain is `repository → table → dynamoDB → awsClient`; only `AWSClient`
carries a `@Teardown`, so the reverse walk resolves to a single `awsClient.shutdown()` at
shutdown — but the mechanism is general.

**Validation — full LocalStack integration test.** The reference branch's setup:
`swift-local-containers` stands up a LocalStack DynamoDB, `AWS_ENDPOINT_URL` points at it,
and the test drives the app against a real Soto client — so `AWSClient.shutdown()` runs
against a live client, not a stub. This proves resource shutdown end-to-end, on top of the
swift-wire unit/integration test that pins the reverse-order walk and failure collection
in isolation.

## Suggested sequencing

- **M4.1 — Core teardown emission.** `Teardownable` in Wire Core; emit `teardown()` on the
  graph struct (reverse-order walk, member + producer forms, failure collection);
  conform the struct. Unit + end-to-end swift-wire tests (a `@Teardown` binding that
  records it fired; assert reverse order and that a throwing action doesn't stop the rest).
- **M4.2 — WireHummingbird `GraphTeardownService`.** The service + `apply` prepend; verify
  ServiceGroup ordering (teardown runs after the server stops).
- **M4.3 — task-cluster Soto adoption.** The `ApplicationWiring` chain above; drop the
  in-memory table; build/run against pushed swift-wire + wire-hummingbird main.
- **M4.4 — LocalStack integration test.** `swift-local-containers` + real DynamoDB;
  exercise `AWSClient.shutdown()` against a live client.
- **~~M4.5~~ → M7c — init-failure partial teardown.** Deferred to the dynamic-scheduling
  pass (above): its `_wireBootstrap()` codegen is fixed by the construction scheduler, so it
  lands once against the final model rather than being written against the sequential chain
  and rewritten.
- **M4.6 — docs.** This note; the `ROADMAP.md` M4 entry + the new M7c entry; the README
  status refresh (M1 inert → M4 app-scope emitted; request scope M5; init-failure M7c).

## References

- README **Lifecycle and teardown** — the committed semantics (reverse order, app-scope
  via service-lifecycle, failure handling, Service-vs-teardown).
- [WireHummingbirdDesign.md](WireHummingbirdDesign.md) — the `[any Service]` lifecycle
  seam and the reserved graph-teardown-service prepend.
- [WireOpenAPIDesign.md](WireOpenAPIDesign.md) — the `Introspectable` precedent this
  teardown surface mirrors (Core protocol + graph conformance + `some`-taking facade).
- `TeardownDiscovery.swift` — the `TeardownAction` model M4 consumes (M1, inert).
