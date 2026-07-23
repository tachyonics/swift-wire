# Wire testing model — design note (M6a)

> **Status:** design record for swift-wire's **scope-agnostic** testing primitives. `@Replaces`
> is **built**; `@BindType` / `@Scopable` / `TestingKey` and the seed-threaded cascade are
> **unbuilt** — this note is for review before building. These primitives know nothing about
> HTTP or "request scope"; an adapter's test harness supplies the specifics (the WireMVC harness
> is in [WireMVCTesting.md](WireMVCTesting.md)).

## The problem

Substituting bindings for a test, at any scope, without distorting production. Two distinct needs:

- **Swap a binding's type** — use a fake *implementation* everywhere its slot is consumed.
- **Inject a test-held instance** — a mock the test constructs, configures, and inspects (`verify`), including a *generated* mock (e.g. [smockable](https://github.com/tachyonics/smockable)) whose type you **cannot annotate**.

And a guardrail: testing must never push a production scope decision (a binding shouldn't become seeded-scope just because it's easier to mock that way).

## The primitives

### `@Replaces` — compile-time type swap *(built)*

A bare marker: a consumer binding supersedes a dependency module's binding for the slot it produces, resolved before duplicate detection, honored only from the composition root's own module. Wire **constructs** the double, so the test holds no handle to it, and the double must be a **hand-written type you can annotate**. Good for a stateless fake implementation across a whole test target; wrong for an inspectable or generated mock.

### `@BindType(Protocol.self, Mock.self)` — test-graph type substitution

Declares that, in this test graph, the slot named by the first argument is bound to the concrete `Mock` type — `@BindType(Repo.self, Mock.self)` for the unkeyed slot, `@BindType(Repo.primary, Mock.self)` for a keyed one (mirroring `@Provides` / `@Replaces`). WireGen specialises the test graph to that concrete type — the *same* opaque-lift it already does for the real binding, just pointed at the mock. Crucially it **references** `Mock` rather than annotating it, so a generated mock fits with no wrapper. The **instance** is supplied at runtime (below), so the test holds and inspects it.

### `@Scopable(X.self)` — permit lifting into a seeded scope

Permits an app-scoped (`@Singleton`) binding to be reconstructed inside a seeded scope **under test**. Scope-agnostic — *which* seed is the caller's business (an adapter's; WireMVC's is `HTTPRequest`). It's an explicit, per-binding acknowledgment because making a singleton seeded-scope can break it (it may rely on being one — a cache, a pool, cross-scope state); the mark says "I accept this isn't a singleton under test."

### `TestingKey` — the keyed test-graph config

The `@BindType` / `@Scopable` declarations attach to a `TestingKey` value; an entry point (or an adapter's suite trait) selects it. One key = one test-graph variant; two suites wanting different substitutions use two keys. Mirrors `@Container` selection, for tests.

```swift
enum MyTests {
    @BindType(BackendRepository.self, MockBackendRepository.self)
    @Scopable(TodoController.self)              // the app-scoped hop the cascade needs (below)
    static let testSetup = TestingKey()
}
```

## The instance rides the seed

A `@BindType` binding's instance is just an extra thing the scope is **entered with**. swift-wire already threads a **seed** into a seeded scope (`HTTPRequest` today); the test doubles ride the same channel — the scope-entry becomes `(seed, test-doubles)`, and a `@BindType` binding resolves directly to its double from the doubles part. No new value-source abstraction: the double is a seed input, threaded exactly as the seed is. The adapter supplies the doubles at scope entry ([WireMVCTesting.md](WireMVCTesting.md) does it from an HTTP-correlated store).

## The cascade — and why it's inherent

A singleton captures its dependencies **at build time**, once. So a per-scope-entry double can only reach it by rebuilding it per entry — which means **everything on the path from the mocked binding up to the seeded-scope root(s) must be lifted into the scope**. That's the cascade, and it can't be dodged for completeness: a consumer that reads a dependency in its `init` (`self.x = repo.load()`) is built once at bootstrap, with no scope active, so it would never see the double unless rebuilt per entry.

Each app-scoped hop on that path needs `@Scopable` — the same explicit acknowledgment as the leaf, for the same reason (each might rely on being a singleton).

**WireGen drives the marking.** It knows the seeded-scope roots, so given a `@BindType`d binding it computes the path and, for each unmarked app-scoped hop, errors with exactly what to add:

```
error: BackendRepository is bound per-scope-entry under test, but reaches the
       scope root through singleton 'TodoController'. Add @Scopable(TodoController.self)
       to allow it to be lifted into the scope under test.
```

Explicit (you type each acknowledgment) but guided — no guess-and-check, and it names the whole chain when there are intermediates.

**The alternative, and its gap.** A per-call *proxy* of just the mocked binding (the singleton consumer stays a singleton, holding a proxy that resolves the double per scope-entry) avoids the cascade — but only mocks **per-call** reads, never **init-time** reads. So the proxy is the shortcut with a hole; the cascade is the complete answer. (Decision below.)

## `@Replaces` vs `@BindType`

| | `@Replaces` | `@BindType` + instance |
|---|---|---|
| double is a | *type* Wire constructs | concrete type you name + an *instance* you pass |
| test-held handle | no | yes (configure / `verify`) |
| generated mock | needs a hand-written wrapper | fits (references the type) |
| granularity | whole test target | per `TestingKey`, per scope-entry instance |

`@Replaces` stays the tool for a hand-written whole-target fake with no handle needed; `@BindType` is the tool for an inspectable or generated mock.

## Test-graph-only

All of this lives in the **test graph** — the test target regenerates its own graph (its own build plugin, depending on the app target, per spike-27) and applies the `TestingKey`'s substitutions and scope-lifts there. The production graph is untouched: real bindings, real scopes, no doubles-seed.

## Decisions

- **Naming** — `@BindType`, `@Scopable`, `TestingKey`; scope-agnostic (no "request" in the swift-wire layer).
- **Missing instance → error.** A `@BindType`d slot reached with no double supplied for a scope-entry throws (`no bound value for …`); the adapter surfaces it (WireMVC as an explicit 500). No silent fall-back — a `@BindType` slot is a hole the test must fill.
- **Keys → the slot is the first argument.** `@BindType(Repo.self, Mock.self)` for the unkeyed slot, `@BindType(Repo.primary, Mock.self)` for a keyed one — mirroring `@Provides` / `@Replaces`.
- **Cascade → reconstruct-per-entry** (the `@Scopable` model), not the per-call proxy, so init-time dependency reads are mocked too. The proxy stays documented above as the alternative-with-a-gap.

## Prior art

- **Instance mocking:** Dagger-Hilt `@BindValue` / `@TestInstallIn`, Spring `@MockBean`, ASP.NET `ConfigureTestServices(_ => mock)`, NestJS `.overrideProvider().useValue()`. Common shape: the test holds the mock; the framework injects that instance; the scope collapses to it — nobody mocks "per request."
- **Scoped resolution:** Spring scoped proxies (per-call resolution of a scoped bean injected into a singleton) — the alternative-with-a-gap above.
