/// A namespace identifier for a *test-graph variant* — the config a test target
/// selects to substitute bindings under test.
///
/// `TestingKey` joins Wire's key family (`BindingKey<Value>` / `FactoryKey` /
/// `CollectedKey` / `MappedKey` / `BuilderKey`), and like `FactoryKey` it is a
/// pure *namespace token*: its identity is the *canonical text* of its declaring
/// reference (`MyTests.testSetup`), from which the build plugin derives the
/// variant's doubles-struct type name (`_MyTests_testSetupDoubles`).
///
/// Declare one as a static member and attach `@BindType` (and, from Phase 2,
/// `@Scopable`) to it to describe the substitutions the variant applies:
///
///     enum MyTests {
///         @BindType(BackendRepository.self, MockBackendRepository.self)
///         static let testSetup = TestingKey()
///     }
///
/// One key is one test-graph variant: two suites wanting different substitutions
/// use two keys. It mirrors `@Container` selection, for tests — the substitutions
/// live only in the test graph, so the production graph is untouched. The
/// substituted slot is sourced from a per-scope-entry *doubles* value the test
/// holds and inspects, threaded into the scope exactly as the scope's seed is.
public struct TestingKey: Sendable {
    public init() {}
}
