import Testing

@testable import WireGenCore

/// M6a Phase 1: the test-graph variant transform — `@BindType` substitutions
/// rewriting a slot into a doubles-sourced binding, and the `_<Key>Doubles`
/// struct the scope is entered with.
@Suite("TestingGraph")
struct TestingGraphTests {
    private func scopedController(
        _ name: String,
        seed: String,
        dependencies: [(name: String?, type: String)]
    ) -> DiscoveredBinding {
        let deps = dependencies.map {
            DependencyParameter(name: $0.name, type: $0.type, kind: .injectInitParameter, location: mockLocation("\(name).swift"))
        }
        return .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: deps,
                location: mockLocation("\(name).swift"),
                scopeKey: ScopeKey(seed: seed),
                originModule: testModule
            )
        )
    }

    private func scopedProvider(_ boundType: String, seed: String, key: String? = nil) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: "make\(boundType)()",
                form: .function,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(boundType).swift"),
                keyIdentifier: key,
                scopeKey: ScopeKey(seed: seed),
                originModule: testModule
            )
        )
    }

    // MARK: - Doubles struct

    @Test func doublesStructTypeNameJoinsReferenceComponents() {
        #expect(doublesStructTypeName(forKeyReference: "MyTests.testSetup") == "_MyTests_testSetupDoubles")
        #expect(doublesStructTypeName(forKeyReference: "setup") == "_setupDoubles")
    }

    @Test func renderDoublesStructEmitsPackageFieldsAndInit() {
        let rendered = renderDoublesStruct(
            typeName: "_MyTests_testSetupDoubles",
            fields: [
                DoublesField(name: "backendRepository", mockType: "MockBackendRepository"),
                DoublesField(name: "clock", mockType: "FakeClock"),
            ]
        )
        let expected = """
            internal struct _MyTests_testSetupDoubles: Sendable {
                let backendRepository: MockBackendRepository
                let clock: FakeClock
                init(backendRepository: MockBackendRepository, clock: FakeClock) {
                    self.backendRepository = backendRepository
                    self.clock = clock
                }
            }
            """
        #expect(rendered == expected)
    }

    // MARK: - Substitution

    @Test func substitutionMakesSlotDoublesSourcedAndMockTyped() throws {
        // A concrete slot bound in the scope, substituted to a mock: the binding becomes a
        // `doubles.<field>` provider keeping its identity + scope, and one doubles field of the mock type.
        let repo = scopedProvider("BackendRepository", seed: "RequestSeed")
        let controller = scopedController(
            "TodoController",
            seed: "RequestSeed",
            dependencies: [(name: "repo", type: "BackendRepository")]
        )
        let result = applyBindTypeSubstitutions(
            to: [repo, controller],
            substitutions: [
                BindTypeSubstitution(
                    slotType: "BackendRepository",
                    slotKey: nil,
                    mockType: "MockBackendRepository",
                    location: mockLocation("T.swift")
                )
            ]
        )
        #expect(result.unmatched.isEmpty)
        #expect(result.doublesFields == [DoublesField(name: "backendRepository", mockType: "MockBackendRepository")])

        // The repo binding is now a doubles-sourced provider, same identity + scope, no dependencies.
        let rewritten = try #require(result.bindings.first)
        guard case .provider(let provider) = rewritten else { Issue.record("expected provider"); return }
        #expect(provider.boundType == "BackendRepository")
        #expect(provider.accessPath == "doubles.backendRepository")
        #expect(provider.form == .property)
        #expect(provider.dependencies.isEmpty)
        #expect(provider.scopeKey == ScopeKey(seed: "RequestSeed"))
        // The construction line the scope emits reads the field.
        #expect(constructionExpression(for: rewritten) == "doubles.backendRepository")
        // The consumer is untouched.
        #expect(result.bindings.last?.boundType == "TodoController")
    }

    @Test func opaqueSlotKeepsIdentityFieldStripsSomePrefix() throws {
        // A `@Singleton(as: BackendRepository.self)` slot keys as `some BackendRepository`; the doubles
        // binding keeps that identity (consumers still lift the same way) while the field strips `some `.
        let repo = DiscoveredBinding.provider(
            DiscoveredProvider(
                boundType: "some BackendRepository",
                accessPath: "makeRepo()",
                form: .function,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("R.swift"),
                scopeKey: ScopeKey(seed: "RequestSeed"),
                originModule: testModule
            )
        )
        let result = applyBindTypeSubstitutions(
            to: [repo],
            substitutions: [
                BindTypeSubstitution(
                    slotType: "BackendRepository",
                    slotKey: nil,
                    mockType: "MockBackendRepository",
                    location: mockLocation("T.swift")
                )
            ]
        )
        #expect(result.doublesFields == [DoublesField(name: "backendRepository", mockType: "MockBackendRepository")])
        guard case .provider(let provider) = try #require(result.bindings.first) else {
            Issue.record("expected provider"); return
        }
        #expect(provider.boundType == "some BackendRepository")
        #expect(provider.accessPath == "doubles.backendRepository")
    }

    @Test func keyedSubstitutionMatchesByKey() throws {
        let repo = scopedProvider("BackendRepository", seed: "RequestSeed", key: "Repo.primary")
        let result = applyBindTypeSubstitutions(
            to: [repo],
            substitutions: [
                BindTypeSubstitution(
                    slotType: nil,
                    slotKey: "Repo.primary",
                    mockType: "MockRepo",
                    location: mockLocation("T.swift")
                )
            ]
        )
        guard case .provider(let provider) = try #require(result.bindings.first) else {
            Issue.record("expected provider"); return
        }
        #expect(provider.keyIdentifier == "Repo.primary")
        #expect(provider.accessPath == "doubles.backendRepositoryKeyedRepoPrimary")
        #expect(result.doublesFields.first?.mockType == "MockRepo")
    }

    @Test func unmatchedSubstitutionIsReported() {
        let repo = scopedProvider("BackendRepository", seed: "RequestSeed")
        let result = applyBindTypeSubstitutions(
            to: [repo],
            substitutions: [
                BindTypeSubstitution(
                    slotType: "NotBound",
                    slotKey: nil,
                    mockType: "MockNotBound",
                    location: mockLocation("T.swift")
                )
            ]
        )
        #expect(result.doublesFields.isEmpty)
        #expect(result.unmatched.count == 1)
        #expect(result.unmatched.first?.slotType == "NotBound")
        // The binding set is unchanged.
        #expect(result.bindings.first?.boundType == "BackendRepository")
    }
}
