# M6a — Wire testing primitives: implementation plan

> **Status:** the **swift-wire** side of the M6a testing milestone — `@BindType`, `@Scopable`,
> `TestingKey`, and the seed-threaded doubles. Design record: [Notes/TestingModel.md](Notes/TestingModel.md).
> The wire-mvc HTTP harness (the `Doubles` supply channel, `withBindValues`, the suite trait,
> `TestClient` — [Notes/WireMVCTesting.md](Notes/WireMVCTesting.md)) is a **separate follow-on plan**
> that consumes these primitives. Iterative, same discipline as the archived
> [M5.4 plan](Archive/M5_4_PLAN.md): each phase runs end-to-end and has a validation gate.

## Grounding — the scope-entry thunk today

M5.4's request-scope machinery generates, for a `.singleton` bridge proxy over a `@Scoped(seed:)` subject, a thunk (`ScopeEntryEmission.scopeEntryThunkLines`):

```swift
let _wireEnterScope = { @Sendable (hTTPRequest: HTTPRequest) async throws in
    let requestInfo = RequestInfo(request: hTTPRequest, store: userStore)   // constructed per entry
    // borrowed singletons resolve to captured bootstrap locals (userStore), not reconstructed
    let _wireScopeTeardown: … = { … }
    return (whoAmIController, _wireScopeTeardown)
}
```

The witness calls `_wireEnterScope(request)` per request. Every piece below **extends this thunk** — the doubles thread through it, and `@Scopable` bindings move *into* it.

## Phase 1 — `@BindType` + `TestingKey` + seed-threaded doubles (no cascade)

Substitute a slot's type to a concrete mock and source its instance from a threaded `doubles`, for a consumer **already in a seed scope** (a `@Scoped(seed:)` controller injecting the `@BindType`d dependency). No `@Scopable`/cascade yet.

### 1.1 — Annotations (`Sources/Wire`)
- `@attached(peer) public macro BindType<Slot, Mock>(_ slot: Slot.Type, _ mock: Mock.Type)` plus a `(_ key: BindingKey<Slot>, _ mock: Mock.Type)` overload — an inert marker (`[]`), like `ReplacesMacro`. Attached to a `TestingKey` static.
- `public struct TestingKey: Sendable {}` — a value type identifying a test-graph variant, like `BindingKey` / a container key.

### 1.2 — Discovery (`WireGenCore`)
- Scan `@BindType` markers, grouped by the `TestingKey` static they attach to → a `[testingKeyReference: [(slotIdentity, mockType)]]` substitution set. Mirror `BindingKeyScanning` (how keyed references are read).

### 1.3 — Graph — a `TestingKey` is a keyed graph variant
- A `TestingKey` selects a graph variant, exactly as a `@Container` does (`_<Container>WireGraph`). The test target regenerates the variant (spike-27) with the substitutions applied.
- For each `(slot, Mock)`: the slot's binding becomes a **doubles-sourced binding** of `Mock` — it resolves to `doubles.<field>` rather than a `constructionExpression`. Consumers specialise to `Mock` through the existing opaque-lift (the same path that specialises to the real concrete type).
- Emit a `struct _<TestingKey>Doubles: Sendable { package let <field>: <Mock>; … }` — one field per `@BindType` slot, named from the slot identity.

### 1.4 — Scope-entry emission (extend `scopeEntryThunkLines`)
The thunk grows a `doubles` parameter, and a `@BindType`d binding's line becomes a field read:

```swift
let _wireEnterScope = { @Sendable (hTTPRequest: HTTPRequest, doubles: _TestSetupDoubles) async throws in
    let someBackendRepository = doubles.someBackendRepository        // @BindType → from doubles
    let todoController = TodoController(repo: someBackendRepository)  // consumer specialised to the mock type
    let _wireScopeTeardown: … = { … }
    return (todoController, _wireScopeTeardown)
}
```

The thunk *type* and the proxy's `_wireEnterScope` dependency both gain the `doubles` parameter (extends `parsedContributorScopeEntryThunkType` + the bridge-proxy field type). The doubles struct threads through the graph lift like any other constructor argument.

### 1.5 — Gate
- **WireGenCore unit tests:** a `@BindType` substitution makes the slot doubles-sourced + `Mock`-typed; the scope-entry thunk takes `(seed, doubles)` and resolves the binding from `doubles`.
- **Cross-module integration fixture** (mirroring the M5.4 seed-scope tests): a `@Scoped(seed:)` controller injecting a `@BindType`d dependency; the generated thunk is called with a hand-constructed `doubles` (simulating the not-yet-built wire-mvc witness) and returns the controller holding the supplied instance.
- swift-wire `swift test` green under 6.4.

## Phase 2 — `@Scopable` + the cascade + guided diagnostics

Lift app-scoped bindings into the seed scope so a **singleton** consumer of a `@BindType`d binding receives the per-entry double (including init-time reads), transitively, with WireGen-guided marking.

### 2.1 — Annotation
- `@attached(peer) public macro Scopable<T>(_ type: T.Type)` — inert marker on a `TestingKey` static, alongside `@BindType`. Scope-agnostic (no "request").

### 2.2 — Discovery
- Scan `@Scopable` → the set of app-scoped bindings this `TestingKey` permits to be lifted.

### 2.3 — Graph — cascade + diagnostics
- From each `@BindType`d binding, walk the resolved edges (`GraphResult.edges` — already surfaced for M5.4.6 reachability) toward the seed-scope root(s). Every **app-scoped** binding on that path must be `@Scopable`d.
- For each unmarked hop: a guided diagnostic —
  ```
  error: BackendRepository is bound per-scope-entry under test, but reaches the scope
         root through singleton 'TodoController'. Add @Scopable(TodoController.self).
  ```
- A `@Scopable`d binding moves from the bootstrap (app scope) into the seed scope: it joins the scope's binding set and is constructed **in the thunk**, per entry, rather than once in `_wireBootstrap`.

### 2.4 — Scope-entry emission
- The lifted bindings construct inside the thunk (they enter `scope.topologicalOrder` / the reachable set), so a lifted `TodoController` is rebuilt per entry and its `init` sees the double. Borrowed *un-lifted* singletons still resolve to captured bootstrap locals.

### 2.5 — Gate
- **WireGenCore tests:** the cascade path computation; the guided diagnostic fires for an unmarked hop and clears when marked; a `@Scopable`d singleton constructs in the thunk, not the bootstrap.
- **Fixture:** a `@Singleton` controller injecting a `@BindType`d binding, with `@Scopable(Controller.self)`, reconstructs per entry and observes the double at `init` time.
- The per-call **proxy alternative** is *not* built — it stays documented as the alternative-with-a-gap (init-time reads).

## Out of scope here (the wire-mvc harness plan)

The `Doubles` supply channel (store + `X-WireMVC-Test-Binds` correlation header), `withBindValues`, the `@Suite(.wiremvc(key))` trait, `TestClient`, and the request handler that reads the header, pulls the test's doubles from the store, and calls `_wireEnterScope(request, doubles)`. Built on top of these primitives, after they land.

## Risks / open items to watch

1. **Doubles through the lift.** The `doubles` parameter must compose with the existing generic-lift thunk type (`liftSpecialised`) — a doubles-sourced binding whose `Mock` is concrete should simplify, not complicate, the lift, but verify against a generic scoped subject (the `MeController<Repository>` shape).
2. **`TestingKey` = keyed graph variant.** Confirm the container/keyed-graph generation cleanly hosts a test variant (substitutions + scope-lifts), and that a test target declaring several `TestingKey`s gets several variants.
3. **Missing-double is a runtime concern.** swift-wire's graph is complete (the slot *has* a binding — `doubles.<field>`); "no double supplied" is the harness's runtime error (an empty field / a throwing accessor), surfaced by wire-mvc as a 500. Decide whether the `Doubles` field is non-optional (constructed only when all supplied) or the accessor throws.
