import Wire

/// A simple value bound only inside `TestContainer` via the
/// `@Container extension` opt-in. Demonstrates that bindings declared
/// in a `@Container extension` merge into the same logical container
/// as the primary declaration's bindings — both `banner` (primary)
/// and `testMode` (extension) show up on `_TestContainerWireGraph`.
struct TestMode: Sendable {
    let value: String
}

@Container
extension TestContainer {
    @Provides(allowUnused: true) static let testMode: TestMode = TestMode(value: "integration-test")
}
