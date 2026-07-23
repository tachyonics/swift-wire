import Testing

/// M6a Phase 1 gate — the runtime chain for a `@BindType` doubles substitution: variant seed scope →
/// doubles-threaded scope-entry → the seed-scoped consumer resolves to the *exact* supplied instance.
/// Hand-builds the `doubles` (standing in for the not-yet-built adapter witness) and drives the generated
/// `bootstrap…Scope(seed:wireGraph:doubles:)` — the `WireDoublesFixture.bindMockRepo` variant of
/// `BindTypeDoublesExample`.
@Suite("BindTypeDoubles")
struct BindTypeDoublesTests {
    @Test func suppliedMockInstanceFlowsThroughScopeEntry() async throws {
        // The variant borrows the production app graph; only the seed scope is substituted.
        let graph = try await Wire.bootstrap()

        // The test constructs and holds the mock, then supplies it through the generated doubles struct.
        let mock = MockTodoRepository()
        let doubles = _WireDoublesFixture_bindMockRepoDoubles(todoRepository: mock)

        // The generated scope-entry threads the doubles alongside the seed.
        let scope = try await Wire.bootstrapWireDoublesFixture_bindMockRepo_TodoRequestSeedScope(
            seed: TodoRequestSeed(id: "req-1"),
            wireGraph: graph,
            doubles: doubles
        )

        // The controller resolved its `any TodoRepository` to the exact supplied mock: driving it records
        // the call on the very instance the test holds (reference identity through the recorded state),
        // and the mock's return value flows back — proving the double, not the production `RealTodoRepository`.
        #expect(scope.todoController.handle() == "mock:req-1")
        #expect(mock.recordedFetches == ["req-1"])
    }
}
