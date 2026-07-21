import Wire

/// End-to-end fixture for rule 3 *inside a seed scope* — a scope-bound consumer
/// asking for `any Greeting`, satisfied by the app-scope `some Greeting`
/// singleton it borrows. This is the case the alias mechanism has to reach into
/// a scope body for: the producer has no construction line here (borrows are
/// inlined at arg sites), so its alias binds up front off the borrow's access
/// path rather than hanging off a `let`.
///
/// Both scope bodies must handle it — the whole-scope façade
/// (`_wireBootstrapTestRequestSeedScope`) and the per-request scope-entry thunk.
@Scoped(seed: TestRequestSeed.self, allowUnused: true)
struct ScopedGreetingReporter {
    @Inject var testRequestSeed: TestRequestSeed
    @Inject var greeting: any Greeting

    func report() -> String { "[\(testRequestSeed.id)] \(greeting.greet())" }
}
