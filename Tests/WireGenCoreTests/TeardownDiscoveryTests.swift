import Testing

@testable import WireGenCore

/// `@Teardown` discovery (iteration 6): the build plugin recognises and
/// records teardown actions but emits no teardown calls (that's M4).
/// Covers the two recorded forms, the misuse diagnostics, and the
/// inert-emission guarantee.
@Suite("TeardownDiscovery")
struct TeardownDiscoveryTests {
    private func providers(in source: String, _ path: String = "T.swift") -> [DiscoveredProvider] {
        discover(in: source, sourcePath: path).bindings.compactMap {
            if case .provider(let provider) = $0 { return provider }
            return nil
        }
    }

    private func singletons(in source: String, _ path: String = "T.swift") -> [DiscoveredScopeBoundType] {
        discover(in: source, sourcePath: path).bindings.compactMap {
            if case .scopeBound(let scopeBound) = $0 { return scopeBound }
            return nil
        }
    }

    private func errors(in source: String, _ path: String = "T.swift") -> [Diagnostic] {
        discover(in: source, sourcePath: path).warnings.filter { $0.severity == .error }
    }

    // MARK: - Owned-type member form

    @Test func memberTeardownRecordsMethodNameAndEffects() {
        let source = """
            @Singleton
            struct Pool {
                @Inject init() {}
                @Teardown func teardown() async throws {}
            }
            """
        let result = singletons(in: source)
        #expect(result.count == 1)
        guard case .member(let name, let isAsync, let isThrowing)? = result.first?.teardown?.kind else {
            Issue.record("expected a member teardown action")
            return
        }
        #expect(name == "teardown")
        #expect(isAsync)
        #expect(isThrowing)
        #expect(errors(in: source).isEmpty)
    }

    @Test func syncMemberTeardownHasNoEffects() {
        let source = """
            @Singleton
            final class Cache {
                @Inject init() {}
                @Teardown func close() { }
            }
            """
        guard case .member(let name, let isAsync, let isThrowing)? = singletons(in: source).first?.teardown?.kind
        else {
            Issue.record("expected a member teardown action")
            return
        }
        #expect(name == "close")
        #expect(!isAsync)
        #expect(!isThrowing)
    }

    @Test func scopedTypeMemberTeardownIsRecorded() {
        let source = """
            @Scoped(seed: RequestSeed.self)
            struct RequestTx {
                @Inject init() {}
                @Teardown func rollback() async {}
            }
            """
        // Scoped types route into a seed partition, so pull the binding
        // straight from `allBindings`.
        let scoped = discover(in: source, sourcePath: "T.swift").allBindings
            .values.flatMap { $0 }
            .compactMap { binding -> DiscoveredScopeBoundType? in
                if case .scopeBound(let scopeBound) = binding { return scopeBound }
                return nil
            }
        guard case .member(let name, let isAsync, _)? = scoped.first?.teardown?.kind else {
            Issue.record("expected a member teardown action on the scoped type")
            return
        }
        #expect(name == "rollback")
        #expect(isAsync)
    }

    // MARK: - Producer form

    @Test func producerClosureTeardownRecordsActionExpression() {
        let source = """
            @Provides
            @Teardown({ (client: HTTPClient) in try await client.shutdown() })
            func makeClient() -> HTTPClient { HTTPClient() }
            """
        guard case .action(let expression)? = providers(in: source).first?.teardown?.kind else {
            Issue.record("expected a producer teardown action")
            return
        }
        #expect(expression.contains("client.shutdown()"))
        #expect(errors(in: source).isEmpty)
    }

    @Test func producerFunctionReferenceTeardownRecordsActionExpression() {
        let source = """
            @Provides
            @Teardown(shutdownClient)
            func makeClient() -> HTTPClient { HTTPClient() }
            """
        guard case .action(let expression)? = providers(in: source).first?.teardown?.kind else {
            Issue.record("expected a producer teardown action")
            return
        }
        #expect(expression == "shutdownClient")
    }

    @Test func providesPropertyTeardownIsRecorded() {
        let source = """
            @Provides
            @Teardown({ (c: HTTPClient) in c.close() })
            var client: HTTPClient { HTTPClient() }
            """
        guard case .action? = providers(in: source).first?.teardown?.kind else {
            Issue.record("expected a producer teardown action on the property provider")
            return
        }
    }

    @Test func providesWithoutTeardownRecordsNoAction() {
        let source = """
            @Provides
            func makeClient() -> HTTPClient { HTTPClient() }
            """
        #expect(providers(in: source).first?.teardown == nil)
    }

    // MARK: - Misuse diagnostics

    @Test func staticMemberTeardownIsAnError() {
        let source = """
            @Singleton
            struct Pool {
                @Inject init() {}
                @Teardown static func teardown() {}
            }
            """
        #expect(errors(in: source).contains { $0.message.contains("'static'") })
        #expect(singletons(in: source).first?.teardown == nil)
    }

    @Test func memberTeardownWithParametersIsAnError() {
        let source = """
            @Singleton
            struct Pool {
                @Inject init() {}
                @Teardown func teardown(other: Int) {}
            }
            """
        #expect(errors(in: source).contains { $0.message.contains("takes parameters") })
        #expect(singletons(in: source).first?.teardown == nil)
    }

    @Test func argumentOnMemberTeardownIsAnError() {
        let source = """
            @Singleton
            struct Pool {
                @Inject init() {}
                @Teardown({ (p: Pool) in }) func teardown() {}
            }
            """
        #expect(errors(in: source).contains { $0.message.contains("takes no argument") })
        #expect(singletons(in: source).first?.teardown == nil)
    }

    @Test func twoMemberTeardownsIsAnError() {
        let source = """
            @Singleton
            struct Pool {
                @Inject init() {}
                @Teardown func first() {}
                @Teardown func second() {}
            }
            """
        guard let duplicate = errors(in: source).first(where: {
            $0.message.contains("more than one @Teardown")
        }) else {
            Issue.record("expected a 'more than one @Teardown' error")
            return
        }
        // The error points at the second declaration (line 5); its note
        // points back at the first (line 4) — consistent with the
        // duplicate-key diagnostics' "first used here" notes.
        #expect(duplicate.location.line == 5)
        #expect(duplicate.notes.contains { $0.location.line == 4 })
        // The first well-formed one is still recorded.
        guard case .member(let name, _, _)? = singletons(in: source).first?.teardown?.kind else {
            Issue.record("expected the first teardown to be recorded")
            return
        }
        #expect(name == "first")
    }

    @Test func tooPrivateMemberTeardownErrorsButStillRecords() {
        let source = """
            @Singleton
            struct Pool {
                @Inject init() {}
                @Teardown private func teardown() async {}
            }
            """
        #expect(errors(in: source).contains { $0.message.contains("must be at least 'internal'") })
        // Mirrors @Inject func: the action is well-formed, only its
        // visibility is wrong, so it's recorded for the eventual error.
        #expect(singletons(in: source).first?.teardown != nil)
    }

    @Test func bareTeardownOnProvidesIsAnError() {
        let source = """
            @Provides
            @Teardown
            func makeClient() -> HTTPClient { HTTPClient() }
            """
        #expect(errors(in: source).contains { $0.message.contains("requires a teardown action") })
        #expect(providers(in: source).first?.teardown == nil)
    }

    @Test func teardownOnTheTypeItselfIsAnError() {
        let source = """
            @Singleton
            @Teardown
            struct Pool {
                @Inject init() {}
            }
            """
        #expect(errors(in: source).contains { $0.message.contains("has no effect") })
        #expect(singletons(in: source).first?.teardown == nil)
    }

    // MARK: - Inert emission (M1 records but emits no teardown calls)

    @Test func teardownActionsEmitNoTeardownCalls() {
        let scopeBound = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Pool",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("Pool.swift"),
                teardown: TeardownAction(
                    kind: .member(methodName: "teardown", isAsync: true, isThrowing: true),
                    location: mockLocation("Pool.swift")
                )
            )
        )
        let provider = DiscoveredBinding.provider(
            DiscoveredProvider(
                boundType: "HTTPClient",
                accessPath: "makeClient",
                form: .function,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("Client.swift"),
                teardown: TeardownAction(
                    kind: .action(expression: "{ (c: HTTPClient) in try await c.shutdown() }"),
                    location: mockLocation("Client.swift")
                )
            )
        )
        let output = renderWireGraph(imports: [], topologicalOrder: [scopeBound, provider])
        // The bindings are constructed as usual (the producer's return
        // type drives the property name — `HTTPClient` → `hTTPClient`)…
        #expect(output.contains("let pool = Pool()"))
        #expect(output.contains("let hTTPClient = makeClient()"))
        // …but nothing references the recorded teardown action.
        #expect(!output.contains("teardown"))
        #expect(!output.contains("shutdown"))
    }
}
