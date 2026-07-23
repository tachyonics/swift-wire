import Testing

@testable import WireGenCore

/// M6a Phase 2: the `@Scopable` cascade — `@Scopable` discovery, the path computation from a `@BindType`d
/// binding up to the seed roots, the guided diagnostic for an unmarked hop, the stale-`@BindType`
/// diagnostic, and the lift of a `@Scopable`d singleton into the scope (constructed there, not borrowed).
@Suite("ScopableCascade (core)")
struct ScopableCascadeCoreTests {
    // MARK: - Fixtures

    /// An app-scoped `@Provides` producing `boundType` — the `@BindType`d leaf.
    private func appProvider(_ boundType: String, key: String? = nil) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: "make()",
                form: .function,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(boundType).swift"),
                keyIdentifier: key,
                originModule: testModule
            )
        )
    }

    /// An app-scoped `@Singleton` type depending on `dependencies` (scopeKey nil).
    private func appSingleton(_ name: String, dependencies: [(name: String?, type: String)]) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "class",
                genericParameterNames: [],
                dependencies: dependencies.map {
                    DependencyParameter(
                        name: $0.name,
                        type: $0.type,
                        kind: .injectInitParameter,
                        location: mockLocation("\(name).swift")
                    )
                },
                location: mockLocation("\(name).swift"),
                originModule: testModule
            )
        )
    }

    /// A `@Scoped(seed:)` root depending on `dependencies`.
    private func seedRoot(
        _ name: String,
        seed: String,
        dependencies: [(name: String?, type: String)]
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: dependencies.map {
                    DependencyParameter(
                        name: $0.name,
                        type: $0.type,
                        kind: .injectInitParameter,
                        location: mockLocation("\(name).swift")
                    )
                },
                location: mockLocation("\(name).swift"),
                scopeKey: ScopeKey(seed: seed),
                originModule: testModule
            )
        )
    }

    private func bindType(_ slot: String, _ mock: String) -> BindTypeSubstitution {
        BindTypeSubstitution(slotType: slot, slotKey: nil, mockType: mock, location: mockLocation("Key.swift"))
    }

    /// The app graph's resolved adjacency (consumer identity → dependency identities) for `appSingletons`.
    private func appEdges(_ appSingletons: [DiscoveredBinding]) -> [BindingIdentity: [BindingIdentity]] {
        buildDependencyGraph(from: appSingletons, typealiases: [], homeModule: testModule).edges
    }

    // MARK: - Discovery

    @Test func scopableMarkersDiscoveredOnTestingKey() throws {
        let source = """
            enum MyTests {
                @BindType(BackendRepository.self, MockBackendRepository.self)
                @Scopable(TodoController.self)
                @Scopable(SessionCache.self)
                static let testSetup = TestingKey()
            }
            """
        let key = try #require(discover(in: source, sourcePath: "T.swift", module: testModule).testingKeys.first)
        #expect(key.substitutions.count == 1)
        #expect(key.scopables.map(\.typeName) == ["TodoController", "SessionCache"])
    }

    @Test func testingKeyWithoutScopableHasNoMarkers() throws {
        let source = """
            enum MyTests {
                @BindType(Repo.self, MockRepo.self)
                static let testSetup = TestingKey()
            }
            """
        let key = try #require(discover(in: source, sourcePath: "T.swift", module: testModule).testingKeys.first)
        #expect(key.scopables.isEmpty)
    }

    // MARK: - Cascade path

    @Test func cascadeLiftsMockedLeafAndMarkedHop() {
        // Root (seed) → Controller (singleton) → Repo (@BindType'd). The whole path lifts.
        let repo = appProvider("any AccountRepository")
        let controller = appSingleton(
            "AccountController",
            dependencies: [(name: "repository", type: "any AccountRepository")]
        )
        let root = seedRoot(
            "AccountRequestController",
            seed: "AccountRequestSeed",
            dependencies: [(name: "controller", type: "AccountController"), (name: "seed", type: "AccountRequestSeed")]
        )

        let result = cascadeLift(
            seedBindings: [root],
            appSingletons: [repo, controller],
            appEdges: appEdges([repo, controller]),
            substitutions: [bindType("AccountRepository", "MockAccountRepository")],
            scopableTypeNames: ["AccountController"]
        )

        #expect(result.unmarkedHops.isEmpty)
        #expect(result.liftedIdentities.contains(repo.identity))
        #expect(result.liftedIdentities.contains(controller.identity))
        #expect(!result.liftedIdentities.contains(root.identity))  // the seed root is already scoped
    }

    @Test func unreachableSingletonIsNotLifted() {
        // A singleton the seed root never consumes stays in the app graph.
        let repo = appProvider("any AccountRepository")
        let controller = appSingleton(
            "AccountController",
            dependencies: [(name: "repository", type: "any AccountRepository")]
        )
        let unrelated = appSingleton("Analytics", dependencies: [(name: "repository", type: "any AccountRepository")])
        let root = seedRoot(
            "AccountRequestController",
            seed: "AccountRequestSeed",
            dependencies: [(name: "controller", type: "AccountController")]
        )

        let result = cascadeLift(
            seedBindings: [root],
            appSingletons: [repo, controller, unrelated],
            appEdges: appEdges([repo, controller, unrelated]),
            substitutions: [bindType("AccountRepository", "MockAccountRepository")],
            scopableTypeNames: ["AccountController"]
        )
        #expect(result.liftedIdentities.contains(controller.identity))
        #expect(!result.liftedIdentities.contains(unrelated.identity))
    }

    // MARK: - Guided diagnostic

    @Test func unmarkedHopFiresGuidedDiagnostic() {
        let repo = appProvider("any AccountRepository")
        let controller = appSingleton(
            "AccountController",
            dependencies: [(name: "repository", type: "any AccountRepository")]
        )
        let root = seedRoot(
            "AccountRequestController",
            seed: "AccountRequestSeed",
            dependencies: [(name: "controller", type: "AccountController")]
        )

        let result = cascadeLift(
            seedBindings: [root],
            appSingletons: [repo, controller],
            appEdges: appEdges([repo, controller]),
            substitutions: [bindType("AccountRepository", "MockAccountRepository")],
            scopableTypeNames: []  // the hop is NOT marked
        )
        #expect(result.unmarkedHops.count == 1)
        let hop = result.unmarkedHops[0]
        #expect(hop.slotDisplay == "AccountRepository")
        #expect(hop.hopTypeName == "AccountController")

        let diagnostic = unmarkedCascadeHopDiagnostic(hop)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("AccountRepository is bound per-scope-entry under test"))
        #expect(diagnostic.message.contains("through singleton 'AccountController'"))
        #expect(diagnostic.message.contains("Add @Scopable(AccountController.self)"))
    }

    @Test func markingHopClearsTheDiagnostic() {
        let repo = appProvider("any AccountRepository")
        let controller = appSingleton(
            "AccountController",
            dependencies: [(name: "repository", type: "any AccountRepository")]
        )
        let root = seedRoot(
            "AccountRequestController",
            seed: "AccountRequestSeed",
            dependencies: [(name: "controller", type: "AccountController")]
        )
        let inputs = (appSingletons: [repo, controller], seedBindings: [root])

        let unmarked = cascadeLift(
            seedBindings: inputs.seedBindings,
            appSingletons: inputs.appSingletons,
            appEdges: appEdges(inputs.appSingletons),
            substitutions: [bindType("AccountRepository", "MockAccountRepository")],
            scopableTypeNames: []
        )
        #expect(!unmarked.unmarkedHops.isEmpty)

        let marked = cascadeLift(
            seedBindings: inputs.seedBindings,
            appSingletons: inputs.appSingletons,
            appEdges: appEdges(inputs.appSingletons),
            substitutions: [bindType("AccountRepository", "MockAccountRepository")],
            scopableTypeNames: ["AccountController"]
        )
        #expect(marked.unmarkedHops.isEmpty)
    }

    // MARK: - Stale @BindType

    @Test func unmatchedSubstitutionIsDiagnosed() {
        let repo = appProvider("any AccountRepository")
        let unmatched = unmatchedSubstitutions(
            [bindType("AccountRepository", "MockAccountRepository"), bindType("NotBound", "MockNotBound")],
            against: [repo]
        )
        #expect(unmatched.map(\.slotType) == ["NotBound"])
        let diagnostic = unmatchedBindTypeDiagnostic(unmatched[0])
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("@BindType(NotBound, MockNotBound.self)"))
        #expect(diagnostic.message.contains("no binding under test produces"))
    }

    // MARK: - Lift constructs in the scope, not the bootstrap

    @Test func liftedSingletonIsScopeBoundNotBorrowed() throws {
        // Lift the marked hop + mocked leaf into the seed scope, exclude them from the borrow set, and
        // orchestrate: the controller must be scope-bound (constructed per entry), the repo doubles-sourced.
        let repo = appProvider("any AccountRepository")
        let controller = appSingleton(
            "AccountController",
            dependencies: [(name: "repository", type: "any AccountRepository")]
        )
        let root = seedRoot(
            "AccountRequestController",
            seed: "AccountRequestSeed",
            dependencies: [(name: "controller", type: "AccountController"), (name: "seed", type: "AccountRequestSeed")]
        )
        let appSingletons = [repo, controller]
        let substitutions = [bindType("AccountRepository", "MockAccountRepository")]

        let cascade = cascadeLift(
            seedBindings: [root],
            appSingletons: appSingletons,
            appEdges: appEdges(appSingletons),
            substitutions: substitutions,
            scopableTypeNames: ["AccountController"]
        )
        let lifted = appSingletons.filter { cascade.liftedIdentities.contains($0.identity) }
        let liftedSubstituted = applyBindTypeSubstitutions(to: lifted, substitutions: substitutions)
        #expect(
            liftedSubstituted.doublesFields == [
                DoublesField(name: "accountRepository", mockType: "MockAccountRepository")
            ]
        )

        let allBorrows = syntheticSingletonBorrowBindings(from: appSingletons, inWireGraphOfType: "_WireGraph")
        let scopeBorrows = allBorrows.filter { !cascade.liftedIdentities.contains($0.identity) }
        #expect(scopeBorrows.isEmpty)  // both app singletons were lifted, so nothing is borrowed

        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "AccountRequestSeed"),
            containerName: "MyTests_testSetup",
            scopeBindings: [root] + liftedSubstituted.bindings,
            borrowBindings: scopeBorrows,
            parentGraphType: "_WireGraph",
            typealiases: [],
            module: testModule,
            homeModule: testModule
        )
        let order = try #require(orchestration.result.outcome.topologicalOrder)
        #expect(orchestration.result.outcome.validationErrors == nil)

        // The controller is constructed in-scope (not a borrow).
        let controllerName = identifierName(forType: "AccountController", key: nil)
        #expect(!orchestration.borrowedBindingPropertyNames.contains(controllerName))
        #expect(order.contains { $0.boundType == "AccountController" })

        // The rendered scope bootstrap constructs the controller from the doubles-sourced repository.
        let scope = SeedScopeEmission(
            seedTypeExpression: "AccountRequestSeed",
            identifierSuffix: orchestration.identifierSuffix,
            parentGraphType: "_WireGraph",
            topologicalOrder: order,
            borrowedBindingPropertyNames: orchestration.borrowedBindingPropertyNames,
            doublesType: "_MyTests_testSetupDoubles"
        )
        let output = renderWireGraph(imports: [], topologicalOrder: [], seedScopeOrders: [scope])
        #expect(output.contains("let anyAccountRepository = doubles.accountRepository"))
        #expect(output.contains("AccountController(repository: anyAccountRepository)"))
    }
}
