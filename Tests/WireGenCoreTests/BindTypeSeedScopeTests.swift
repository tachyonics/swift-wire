import Testing

@testable import WireGenCore

/// M6a Phase 1 gate: a `@Scoped(seed:)` controller injecting a `@BindType`d
/// dependency. The scope-entry thunk grows a `doubles` parameter and the
/// `@BindType`d binding resolves to `doubles.<field>` (a concrete mock), with
/// the consumer wired to it — the plan's §1.4 sketch. Mirrors the M5.4 seed-scope
/// emission tests: constructs the bridging proxy directly and renders the graph.
@Suite("BindType seed-scope")
struct BindTypeSeedScopeTests {
    private func doublesSourcedProvider(_ boundType: String, field: String, seed: String) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: "doubles.\(field)",
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("<doubles>"),
                scopeKey: ScopeKey(seed: seed),
                originModule: testModule
            )
        )
    }

    private func syntheticSeed(_ seed: String, accessPath: String) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: seed,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("<synthetic>"),
                originModule: testModule
            )
        )
    }

    // MARK: - Bet A — the doubles-threaded thunk (emission)

    @Test func scopeEntryThunkThreadsDoublesAndSourcesBindType() {
        // The controller injects `repo: BackendRepository`; the variant binds that slot to
        // `MockBackendRepository`, sourced from `doubles.backendRepository`. The thunk grows the `doubles`
        // parameter, reads the field, and wires the controller to it.
        let doublesType = "_MyTests_testSetupDoubles"
        let subject = DiscoveredScopeBoundType(
            typeName: "TodoController",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [
                DependencyParameter(
                    name: "repo",
                    type: "BackendRepository",
                    kind: .injectInitParameter,
                    location: mockLocation("T.swift")
                )
            ],
            location: mockLocation("T.swift"),
            scopeKey: ScopeKey(seed: "RequestSeed"),
            originModule: testModule
        )
        let proxy = contributorProxyBinding(
            for: subject,
            key: "WireMVCKeys.routeContributors",
            prefix: "_WireRouteContributor_",
            proxyScope: .singleton,
            doubles: doublesType
        )
        let controller = DiscoveredBinding.scopeBound(subject)
        let scope = SeedScopeEmission(
            seedTypeExpression: "RequestSeed",
            identifierSuffix: "RequestSeed",
            parentGraphType: "_WireGraph",
            topologicalOrder: [
                syntheticSeed("RequestSeed", accessPath: "requestSeed"),
                doublesSourcedProvider("BackendRepository", field: "backendRepository", seed: "RequestSeed"),
                controller,
            ],
            borrowedBindingPropertyNames: []
        )
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [.scopeBound(proxy)],
            seedScopeOrders: [scope]
        )

        // The thunk takes `(seed, doubles)`.
        #expect(
            output.contains(
                "let \(identifierName(forType: proxy.dependencies[0].type, key: nil)) = { @Sendable (requestSeed: RequestSeed, doubles: \(doublesType)) async throws in"
            )
        )
        // The `@BindType`d binding reads its double.
        #expect(output.contains("let backendRepository = doubles.backendRepository"))
        // The consumer is wired to it.
        #expect(output.contains("let todoController = TodoController(repo: backendRepository)"))
        // The subject is returned alongside the scope teardown.
        #expect(output.contains("return (todoController, _wireScopeTeardown)"))
        // The proxy's `_wireEnterScope` field type carries the doubles parameter.
        #expect(proxy.dependencies[0].type.contains("(RequestSeed, \(doublesType)) async throws"))
    }

    // MARK: - Bet B — end to end: discover → substitute → orchestrate → render

    @Test func discoveredControllerBindsMockThroughVariantGraph() throws {
        let source = """
            @Scoped(seed: RequestSeed.self)
            struct TodoController {
                @Inject var repo: BackendRepository
            }

            @Scoped(seed: RequestSeed.self)
            enum RequestProviders {
                @Provides static func repo() -> BackendRepository { RealRepo() }
            }

            enum MyTests {
                @BindType(BackendRepository.self, MockBackendRepository.self)
                static let testSetup = TestingKey()
            }
            """
        let discovery = discover(in: source, sourcePath: "App.swift", module: testModule)

        // The `@BindType` substitution was discovered.
        let testingKey = try #require(discovery.testingKeys.first)
        #expect(testingKey.keyReference == "MyTests.testSetup")

        // Pull the seed scope's bindings and apply the substitution — the real repo becomes doubles-sourced.
        let scopeBindings = discovery.allBindings
            .filter { $0.key.scope != nil }
            .flatMap { $0.value }
        let result = applyBindTypeSubstitutions(to: scopeBindings, substitutions: testingKey.substitutions)
        #expect(result.unmatched.isEmpty)
        #expect(result.doublesFields == [DoublesField(name: "backendRepository", mockType: "MockBackendRepository")])

        // The variant scope orchestrates into a clean, valid graph.
        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "RequestSeed"),
            scopeBindings: result.bindings,
            borrowBindings: [],
            typealiases: [],
            module: testModule,
            homeModule: testModule
        )
        let order = try #require(orchestration.result.outcome.topologicalOrder)
        #expect(orchestration.result.outcome.validationErrors == nil)

        // Render the scope with a bridging proxy carrying the variant's doubles type.
        let doublesType = doublesStructTypeName(forKeyReference: testingKey.keyReference)
        let subject = DiscoveredScopeBoundType(
            typeName: "TodoController",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [
                DependencyParameter(
                    name: "repo",
                    type: "BackendRepository",
                    kind: .injectInitParameter,
                    location: mockLocation("App.swift")
                )
            ],
            location: mockLocation("App.swift"),
            scopeKey: ScopeKey(seed: "RequestSeed"),
            originModule: testModule
        )
        let proxy = contributorProxyBinding(
            for: subject,
            key: "WireMVCKeys.routeContributors",
            prefix: "_WireRouteContributor_",
            proxyScope: .singleton,
            doubles: doublesType
        )
        let scope = SeedScopeEmission(
            seedTypeExpression: "RequestSeed",
            identifierSuffix: "RequestSeed",
            parentGraphType: "_WireGraph",
            topologicalOrder: order,
            borrowedBindingPropertyNames: []
        )
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [.scopeBound(proxy)],
            seedScopeOrders: [scope]
        )

        // The generated thunk threads doubles and reads the field.
        #expect(output.contains("doubles: \(doublesType)) async throws in"))
        #expect(output.contains("let backendRepository = doubles.backendRepository"))
        #expect(output.contains("TodoController(repo: backendRepository)"))

        // The variant's doubles struct renders with the mock-typed field.
        let doublesStruct = renderDoublesStruct(typeName: doublesType, fields: result.doublesFields)
        #expect(doublesStruct.contains("internal struct \(doublesType): Sendable {"))
        #expect(doublesStruct.contains("let backendRepository: MockBackendRepository"))
    }
}
