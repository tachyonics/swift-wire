import Testing

@testable import WireGenCore

/// Snapshot-style tests for effect-aware emission — verifying that
/// `try`/`await`/`try await` prefixes appear at the construction
/// call sites when bindings carry the matching effect flags.
/// Lives in its own suite (rather than appended to `CodeEmissionTests`)
/// so the gallery struct's body stays under the lint threshold.
@Suite("EffectAwareEmission")
struct EffectAwareEmissionTests {
    // MARK: - Helpers

    private func singleton(
        _ name: String,
        dependencies: [(name: String?, type: String)] = [],
        initIsAsync: Bool = false,
        initIsThrowing: Bool = false
    ) -> DiscoveredBinding {
        let deps = dependencies.map {
            DependencyParameter(
                name: $0.name,
                type: $0.type,
                kind: .injectInitParameter,
                location: mockLocation("\(name).swift")
            )
        }
        return .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: deps,
                location: mockLocation("\(name).swift"),
                initIsAsync: initIsAsync,
                initIsThrowing: initIsThrowing
            )
        )
    }

    private func providerFunction(
        _ accessPath: String,
        boundType: String,
        dependencies: [(name: String?, type: String)] = [],
        isAsync: Bool = false,
        isThrowing: Bool = false
    ) -> DiscoveredBinding {
        let deps = dependencies.map {
            DependencyParameter(
                name: $0.name,
                type: $0.type,
                kind: .providerFunctionParameter,
                location: mockLocation("\(accessPath).swift")
            )
        }
        return .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .function,
                dependencies: deps,
                genericParameterNames: [],
                location: mockLocation("\(accessPath).swift"),
                isAsync: isAsync,
                isThrowing: isThrowing
            )
        )
    }

    private func providerProperty(
        _ accessPath: String,
        boundType: String,
        isAsync: Bool = false,
        isThrowing: Bool = false
    ) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(accessPath).swift"),
                isAsync: isAsync,
                isThrowing: isThrowing
            )
        )
    }

    // MARK: - Function providers

    @Test func asyncFunctionProviderEmitsAwaitPrefix() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerFunction("makeFoo", boundType: "Foo", isAsync: true)
            ]
        )
        #expect(output.contains("let foo = await makeFoo()"))
    }

    @Test func throwsFunctionProviderEmitsTryPrefix() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerFunction("makeBar", boundType: "Bar", isThrowing: true)
            ]
        )
        #expect(output.contains("let bar = try makeBar()"))
    }

    @Test func asyncThrowsFunctionProviderEmitsTryAwaitPrefix() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerFunction(
                    "makeBaz",
                    boundType: "Baz",
                    isAsync: true,
                    isThrowing: true
                )
            ]
        )
        #expect(output.contains("let baz = try await makeBaz()"))
    }

    @Test func syncFunctionProviderEmitsNoPrefix() {
        // Sync, non-throwing: bare call, no `try`/`await`. Confirms
        // we don't accidentally prefix all calls.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerFunction("makeQux", boundType: "Qux")
            ]
        )
        #expect(output.contains("let qux = makeQux()"))
        #expect(!output.contains("try makeQux()"))
        #expect(!output.contains("await makeQux()"))
    }

    // MARK: - Computed-property providers

    @Test func asyncThrowsComputedPropertyEmitsTryAwaitPrefix() {
        // Property-form providers with effects render as
        // `let foo = try await accessPath` (the access path itself
        // is the call site of the computed getter).
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                providerProperty(
                    "fetchedFoo",
                    boundType: "Foo",
                    isAsync: true,
                    isThrowing: true
                )
            ]
        )
        #expect(output.contains("let foo = try await fetchedFoo"))
    }

    // MARK: - User-written `@Inject init` effects

    @Test func asyncInitOnScopeBoundEmitsAwaitPrefix() {
        // `@Inject init(...) async` on a `@Singleton`/`@Scoped` —
        // codegen prefixes the constructor call.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("AsyncService", initIsAsync: true)
            ]
        )
        #expect(output.contains("let asyncService = await AsyncService()"))
    }

    @Test func asyncThrowsInitOnScopeBoundEmitsTryAwaitPrefix() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("DatabasePool", initIsAsync: true, initIsThrowing: true)
            ]
        )
        #expect(output.contains("let databasePool = try await DatabasePool()"))
    }

    @Test func syncInitOnScopeBoundEmitsNoPrefix() {
        // Default `@Inject` properties (no custom init) → sync
        // memberwise init → no prefix at the construction site.
        // Same code path covers user-written sync `init` too.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("PlainService")
            ]
        )
        #expect(output.contains("let plainService = PlainService()"))
        #expect(!output.contains("try PlainService"))
        #expect(!output.contains("await PlainService"))
    }

    // MARK: - Mixed dependency chain

    @Test func chainOfMixedEffectsRendersEachCallWithCorrectPrefix() {
        // `Logger` sync, `DatabasePool` async-throws (depends on
        // Logger), `Application` async-throws (depends on
        // DatabasePool). Each construction line gets the prefix
        // matching its own binding's effects; the enclosing
        // bootstrap is already async-throws-wide so all colours
        // are permitted in sequence.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                singleton("Logger"),
                singleton(
                    "DatabasePool",
                    dependencies: [(name: "logger", type: "Logger")],
                    initIsAsync: true,
                    initIsThrowing: true
                ),
                singleton(
                    "Application",
                    dependencies: [(name: "pool", type: "DatabasePool")],
                    initIsAsync: true,
                    initIsThrowing: true
                ),
            ]
        )
        #expect(output.contains("let logger = Logger()"))
        #expect(output.contains("let databasePool = try await DatabasePool(logger: logger)"))
        #expect(output.contains("let application = try await Application(pool: databasePool)"))
    }
}
