import Testing

@testable import WireGenCore

@Suite("Graph")
struct GraphTests {
    // MARK: - Helpers

    private func singleton(
        _ name: String,
        dependencies: [(name: String, type: String)] = [],
        generics: [String] = []
    ) -> DiscoveredBinding {
        let deps = dependencies.map {
            DependencyParameter(
                name: $0.name,
                type: $0.type,
                kind: .injectProperty,
                location: mockLocation("\(name).swift")
            )
        }
        return .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: generics,
                dependencies: deps,
                location: mockLocation("\(name).swift")
            )
        )
    }

    /// Build a singleton with one keyed dependency. Keyed-test helper —
    /// separate from `singleton(_:dependencies:)` to avoid an overload-
    /// ambiguity trap (Swift can't disambiguate `dependencies: []`
    /// across two tuple shapes).
    private func singletonWithKeyedDep(
        _ name: String,
        depName: String,
        depType: String,
        depKey: String?
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: depName,
                        type: depType,
                        kind: .injectProperty,
                        location: mockLocation("\(name).swift"),
                        keyIdentifier: depKey
                    )
                ],
                location: mockLocation("\(name).swift")
            )
        )
    }

    private func providerProperty(
        _ accessPath: String,
        boundType: String,
        key: String? = nil,
        sourcePath: String? = nil
    ) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation(sourcePath ?? "\(accessPath).swift"),
                keyIdentifier: key
            )
        )
    }

    private func providerFunction(
        _ accessPath: String,
        boundType: String,
        dependencies: [(name: String, type: String)] = [],
        generics: [String] = [],
        sourcePath: String? = nil
    ) -> DiscoveredBinding {
        let deps = dependencies.map {
            DependencyParameter(
                name: $0.name,
                type: $0.type,
                kind: .providerFunctionParameter,
                location: mockLocation(sourcePath ?? "\(accessPath).swift")
            )
        }
        return .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .function,
                dependencies: deps,
                genericParameterNames: generics,
                location: mockLocation(sourcePath ?? "\(accessPath).swift")
            )
        )
    }

    // MARK: - Topological order

    @Test func emptyGraphProducesEmptyOrder() throws {
        let result = buildDependencyGraph(from: [])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.isEmpty)
    }

    @Test func singleNodeNoDependenciesIsInOrder() throws {
        let result = buildDependencyGraph(from: [singleton("A")])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["A"])
    }

    @Test func twoNodesOneDependencyDependencyConstructedFirst() throws {
        // A depends on B → topological order is B, then A.
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["B", "A"])
    }

    @Test func threeNodeChainOrderedCorrectly() throws {
        // A → B → C, topological order: C, B, A.
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "c", type: "C")]),
            singleton("C"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["C", "B", "A"])
    }

    @Test func diamondDependencySingleConstructionOfShared() throws {
        // A → B → D, A → C → D. D should appear once, before both B and C,
        // and B/C should both appear before A.
        let result = buildDependencyGraph(from: [
            singleton(
                "A",
                dependencies: [(name: "b", type: "B"), (name: "c", type: "C")]
            ),
            singleton("B", dependencies: [(name: "d", type: "D")]),
            singleton("C", dependencies: [(name: "d", type: "D")]),
            singleton("D"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        let names = order.map { $0.boundType }
        #expect(names.count == 4)
        #expect(names.filter { $0 == "D" }.count == 1)

        let dIndex = names.firstIndex(of: "D")!
        let bIndex = names.firstIndex(of: "B")!
        let cIndex = names.firstIndex(of: "C")!
        let aIndex = names.firstIndex(of: "A")!
        #expect(dIndex < bIndex)
        #expect(dIndex < cIndex)
        #expect(bIndex < aIndex)
        #expect(cIndex < aIndex)
    }

    // MARK: - Cycle detection

    @Test func twoNodeCycleDetected() throws {
        // A → B → A
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "a", type: "A")]),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.cycles.count == 1)
        let cycleNames = Set(errors.cycles[0].map { $0.boundType })
        #expect(cycleNames == ["A", "B"])
    }

    @Test func threeNodeCycleDetected() throws {
        // A → B → C → A
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "c", type: "C")]),
            singleton("C", dependencies: [(name: "a", type: "A")]),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.cycles.count == 1)
        let cycleNames = Set(errors.cycles[0].map { $0.boundType })
        #expect(cycleNames == ["A", "B", "C"])
    }

    @Test func selfLoopDetectedAsCycle() throws {
        // A → A
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "a", type: "A")])
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.cycles.count == 1)
        #expect(errors.cycles[0].first?.boundType == "A")
    }

    @Test func disjointGraphsSomeCyclesOnlyReportsCycles() throws {
        // Two disjoint groups: A → B → A (cycle) and C (no deps).
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "a", type: "A")]),
            singleton("C"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.cycles.count == 1)
    }

    // MARK: - Missing bindings

    @Test func dependencyOnUndiscoveredTypeRecordedAsMissing() throws {
        // A depends on Missing — no binding found for it.
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "x", type: "Missing")])
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.missingBindings.count == 1)
        #expect(errors.missingBindings[0].consumer.boundType == "A")
        #expect(errors.missingBindings[0].dependency.type == "Missing")
    }

    @Test func multipleMissingBindingsAllRecorded() throws {
        let result = buildDependencyGraph(from: [
            singleton(
                "A",
                dependencies: [
                    (name: "x", type: "MissingX"),
                    (name: "y", type: "MissingY"),
                ]
            )
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.missingBindings.count == 2)
    }

    @Test func missingBindingForTypealiasAttachesHintWhenUnderlyingIsBound() throws {
        // `@Inject var userID: UserID` where `UserID` is a typealias of
        // `UUID` and `UUID` IS bound. The missing binding stands (we
        // don't unwrap), but the diagnostic carries a hint pointing at
        // the underlying type.
        let result = buildDependencyGraph(
            from: [
                singleton("A", dependencies: [(name: "userID", type: "UserID")]),
                .provider(
                    DiscoveredProvider(
                        boundType: "UUID",
                        accessPath: "uuid",
                        form: .property,
                        dependencies: [],
                        genericParameterNames: [],
                        location: mockLocation("UUID.swift")
                    )
                ),
            ],
            typealiases: [
                DiscoveredTypealias(
                    name: "UserID",
                    underlyingType: "UUID",
                    location: mockLocation("Types.swift", line: 3, column: 1)
                )
            ]
        )
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.missingBindings.count == 1)
        let hint = try #require(errors.missingBindings[0].typealiasHint)
        #expect(hint.typealiasName == "UserID")
        #expect(hint.underlyingType == "UUID")
    }

    @Test func missingBindingWithTypealiasButUnboundUnderlyingHasNoHint() throws {
        // Typealias exists but underlying type isn't bound either —
        // adding a hint would mislead the user. No hint attached.
        let result = buildDependencyGraph(
            from: [singleton("A", dependencies: [(name: "userID", type: "UserID")])],
            typealiases: [
                DiscoveredTypealias(
                    name: "UserID",
                    underlyingType: "UUID",
                    location: mockLocation("Types.swift")
                )
            ]
        )
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.missingBindings.count == 1)
        #expect(errors.missingBindings[0].typealiasHint == nil)
    }

    // MARK: - @Provides bindings participate in the graph

    @Test func providerPropertyParticipatesInTopologicalOrder() throws {
        // App is a @Singleton that injects Logger; Logger is a
        // @Provides let, not a @Singleton. Both must end up in the topo
        // order, with Logger before App.
        let result = buildDependencyGraph(from: [
            singleton("App", dependencies: [(name: "logger", type: "Logger")]),
            providerProperty("logger", boundType: "Logger"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["Logger", "App"])
    }

    @Test func providerFunctionParametersBecomeGraphDependencies() throws {
        // makeRepo(table:) -> Repository, with table: TaskTable provided
        // by another @Provides. The function's parameter is a real
        // graph edge that affects topological order.
        let result = buildDependencyGraph(from: [
            providerFunction(
                "makeRepo",
                boundType: "Repository",
                dependencies: [(name: "table", type: "TaskTable")]
            ),
            providerProperty("taskTable", boundType: "TaskTable"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["TaskTable", "Repository"])
    }

    @Test func mixedSingletonAndProviderInDependencyChain() throws {
        // Logger (provider) → UserService (singleton injects logger).
        let result = buildDependencyGraph(from: [
            singleton("UserService", dependencies: [(name: "logger", type: "Logger")]),
            providerProperty("logger", boundType: "Logger"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["Logger", "UserService"])
    }

    // MARK: - Duplicate bindings

    @Test func twoSingletonsForSameTypeAreFlaggedAsDuplicate() throws {
        // Two distinct singleton types whose typeName collides — only
        // possible in pathological code, but the duplicate check catches
        // it. Same model would reject `@Singleton class Logger` plus
        // `@Provides let logger: Logger` once we get such a case.
        let result = buildDependencyGraph(from: [
            singleton("Logger"),
            singleton("Logger"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.duplicateBindings.count == 1)
        #expect(errors.duplicateBindings[0].boundType == "Logger")
        #expect(errors.duplicateBindings[0].bindings.count == 2)
    }

    @Test func singletonAndProviderForSameTypeAreFlaggedAsDuplicate() throws {
        // The realistic shape: a @Singleton type and a @Provides for
        // that exact type. Both produce 'Logger' → ambiguous.
        let result = buildDependencyGraph(from: [
            singleton("Logger"),
            providerProperty("loggerProvider", boundType: "Logger"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.duplicateBindings.count == 1)
        #expect(errors.duplicateBindings[0].boundType == "Logger")
    }

    @Test func duplicateBindingsShortCircuitOtherValidation() throws {
        // When duplicates exist, the graph is fundamentally ambiguous
        // and the rest of validation isn't trustworthy. Cycles and
        // missing-bindings are not reported alongside.
        let result = buildDependencyGraph(from: [
            singleton("Logger"),
            singleton("Logger"),
            singleton("App", dependencies: [(name: "missing", type: "Missing")]),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.duplicateBindings.count == 1)
        #expect(errors.cycles.isEmpty)
        #expect(errors.missingBindings.isEmpty)
    }

    // MARK: - Generic types are skipped

    @Test func genericSingletonIsSkippedFromGraph() throws {
        let result = buildDependencyGraph(from: [
            singleton("Repository", dependencies: [], generics: ["Model"]),
            singleton("App"),
        ])
        #expect(result.skipped.map { $0.boundType } == ["Repository"])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["App"])
    }

    @Test func genericProviderFunctionIsSkippedFromGraph() throws {
        let result = buildDependencyGraph(from: [
            providerFunction(
                "makeAny",
                boundType: "Box",
                dependencies: [],
                generics: ["T"]
            ),
            singleton("App"),
        ])
        #expect(result.skipped.count == 1)
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["App"])
    }

    @Test func dependencyOnGenericNameIsMissingNotResolvedToGeneric() throws {
        // App depends on Repository<Model> by name "Repository". Generic
        // bindings aren't in the resolved graph, so this is a missing
        // binding rather than a successful match.
        let result = buildDependencyGraph(from: [
            singleton("Repository", dependencies: [], generics: ["Model"]),
            singleton("App", dependencies: [(name: "repo", type: "Repository")]),
        ])
        #expect(result.skipped.count == 1)
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.missingBindings.count == 1)
    }

    // MARK: - Determinism

    @Test func topologicalOrderIsDeterministicAcrossInputOrders() throws {
        // Same graph constructed in two different input orders should
        // produce the same topological output. The DFS visits nodes in
        // sorted name order, so output stability is guaranteed.
        let inputForward: [DiscoveredBinding] = [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "c", type: "C")]),
            singleton("C"),
        ]
        let inputReversed = Array(inputForward.reversed())

        let forward = buildDependencyGraph(from: inputForward)
        let reversed = buildDependencyGraph(from: inputReversed)
        let forwardOrder = try #require(forward.outcome.topologicalOrder)
        let reversedOrder = try #require(reversed.outcome.topologicalOrder)
        #expect(
            forwardOrder.map { $0.boundType } == reversedOrder.map { $0.boundType }
        )
    }

    // MARK: - renderTopologicalOrder

    @Test func renderTopologicalOrderEmptyShowsEmptyNotice() {
        let report = renderTopologicalOrder([])
        #expect(report.contains("topological order (0 binding(s))"))
        #expect(report.contains("(graph is empty)"))
    }

    @Test func renderTopologicalOrderNumbersEachEntry() {
        let report = renderTopologicalOrder([singleton("First"), singleton("Second")])
        #expect(report.contains("topological order (2 binding(s))"))
        #expect(report.contains("1. First"))
        #expect(report.contains("2. Second"))
    }

    @Test func renderTopologicalOrderUsesAccessPathForProviders() {
        // Providers display by access path, not by bound type, so the
        // user sees the source-level identifier they wrote.
        let report = renderTopologicalOrder([
            providerProperty("Config.dbURL", boundType: "URL")
        ])
        #expect(report.contains("Config.dbURL"))
    }

    // MARK: - renderSkipped

    @Test func renderSkippedEmptyReturnsEmptyString() {
        // Suppression so the CLI doesn't print an empty section header
        // when there are no generic bindings.
        #expect(renderSkipped([]).isEmpty)
    }

    @Test func renderSkippedRendersGenericParameters() {
        let report = renderSkipped([
            singleton("Repository", generics: ["Model"]),
            singleton("Pair", generics: ["Left", "Right"]),
        ])
        #expect(report.contains("Repository<Model>"))
        #expect(report.contains("Pair<Left, Right>"))
    }

    // MARK: - renderValidationErrors

    @Test func renderValidationErrorsCyclesOnly() {
        let errors = GraphResult.ValidationErrors(
            cycles: [[singleton("A"), singleton("B"), singleton("A")]],
            missingBindings: [],
            duplicateBindings: []
        )
        let report = renderValidationErrors(errors)
        // Anchored at the first cycle node's location; the arrow-
        // separated path renders the edges.
        #expect(report.contains("A.swift:1:1: error: dependency cycle: A → B → A"))
        #expect(!report.contains("no binding produces"))
        #expect(!report.contains("has multiple bindings"))
    }

    @Test func renderValidationErrorsMissingBindingsOnly() {
        let consumer = singleton("A")
        let dep = DependencyParameter(
            name: "x",
            type: "Missing",
            kind: .injectProperty,
            location: mockLocation("A.swift", line: 4, column: 9)
        )
        let errors = GraphResult.ValidationErrors(
            cycles: [],
            missingBindings: [MissingBinding(consumer: consumer, dependency: dep)],
            duplicateBindings: []
        )
        let report = renderValidationErrors(errors)
        // Position is the dependency site; the consumer is implied by
        // the location, so the message stays self-contained.
        #expect(report.contains("A.swift:4:9: error: no binding produces 'Missing'"))
        #expect(!report.contains("cycle"))
    }

    @Test func renderValidationErrorsBothCyclesAndMissingBindings() {
        let consumer = singleton("A")
        let dep = DependencyParameter(
            name: "x",
            type: "Missing",
            kind: .injectProperty,
            location: mockLocation("A.swift", line: 4, column: 9)
        )
        let errors = GraphResult.ValidationErrors(
            cycles: [[singleton("A"), singleton("B"), singleton("A")]],
            missingBindings: [MissingBinding(consumer: consumer, dependency: dep)],
            duplicateBindings: []
        )
        let report = renderValidationErrors(errors)
        #expect(report.contains("dependency cycle: A → B → A"))
        #expect(report.contains("no binding produces 'Missing'"))
    }

    @Test func renderValidationErrorsMultipleCyclesEachOnItsOwnLine() {
        let errors = GraphResult.ValidationErrors(
            cycles: [
                [singleton("A"), singleton("B"), singleton("A")],
                [singleton("C"), singleton("D"), singleton("C")],
            ],
            missingBindings: [],
            duplicateBindings: []
        )
        let report = renderValidationErrors(errors)
        #expect(report.contains("A.swift:1:1: error: dependency cycle: A → B → A"))
        #expect(report.contains("C.swift:1:1: error: dependency cycle: C → D → C"))
    }

    @Test func renderValidationErrorsDuplicateBindingsListSourcePaths() {
        let errors = GraphResult.ValidationErrors(
            cycles: [],
            missingBindings: [],
            duplicateBindings: [
                DuplicateBinding(
                    boundType: "Logger",
                    bindings: [
                        singleton("Logger"),
                        providerProperty("loggerProvider", boundType: "Logger"),
                    ]
                )
            ]
        )
        let report = renderValidationErrors(errors)
        // Primary error at the first binding; note(s) at the rest.
        #expect(
            report.contains(
                "Logger.swift:1:1: error: type 'Logger' has multiple bindings; the dependency graph is ambiguous"
            )
        )
        #expect(report.contains("loggerProvider.swift:1:1: note: also bound here"))
    }

    // MARK: - Keyed bindings: (type, key?) identity

    @Test func sameTypeWithDifferentKeysCoexist() throws {
        // Two providers of the same type but different keys — they
        // have distinct (type, key) identities, so the graph accepts
        // them both. No duplicate, no ambiguity.
        let result = buildDependencyGraph(from: [
            providerProperty("primaryDB", boundType: "Database", key: "Database.primary"),
            providerProperty("replicaDB", boundType: "Database", key: "Database.replica"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.count == 2)
    }

    @Test func sameTypeWithSameKeyIsDuplicate() throws {
        // Two providers with identical (type, key) — duplicate.
        let result = buildDependencyGraph(from: [
            providerProperty("dbA", boundType: "Database", key: "Database.primary"),
            providerProperty("dbB", boundType: "Database", key: "Database.primary"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.duplicateBindings.count == 1)
        #expect(errors.duplicateBindings[0].boundType == "Database")
        #expect(errors.duplicateBindings[0].keyIdentifier == "Database.primary")
    }

    @Test func keyedAndUnkeyedSameTypeCoexist() throws {
        // A `@Singleton Database` (unkeyed) and a `@Provides(.replica)`
        // bind the same type but distinct slots. Both fit.
        let result = buildDependencyGraph(from: [
            singleton("Database"),
            providerProperty("replicaDB", boundType: "Database", key: "Database.replica"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.count == 2)
    }

    @Test func keyedDependencyResolvesToKeyedBinding() throws {
        // Consumer asks for `Database` keyed `Database.primary`; a
        // keyed provider satisfies it.
        let result = buildDependencyGraph(from: [
            providerProperty("primaryDB", boundType: "Database", key: "Database.primary"),
            singletonWithKeyedDep(
                "UserRepo",
                depName: "db",
                depType: "Database",
                depKey: "Database.primary"
            ),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["Database", "UserRepo"])
    }

    @Test func keyedDependencyDoesNotMatchUnkeyedBinding() throws {
        // Dagger-style: keyed dep matches only same-key binding. An
        // unkeyed `Database` binding doesn't satisfy a keyed `Database`
        // dep — it's a missing-binding error.
        let result = buildDependencyGraph(from: [
            singleton("Database"),
            singletonWithKeyedDep(
                "UserRepo",
                depName: "db",
                depType: "Database",
                depKey: "Database.primary"
            ),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.missingBindings.count == 1)
        #expect(errors.missingBindings[0].dependency.keyIdentifier == "Database.primary")
    }

    @Test func unkeyedDependencyDoesNotMatchKeyedBinding() throws {
        // The mirror case: unkeyed dep matches only unkeyed binding.
        // A keyed provider doesn't fill an unkeyed slot.
        let result = buildDependencyGraph(from: [
            providerProperty("primaryDB", boundType: "Database", key: "Database.primary"),
            singletonWithKeyedDep(
                "UserRepo",
                depName: "db",
                depType: "Database",
                depKey: nil
            ),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.missingBindings.count == 1)
        #expect(errors.missingBindings[0].dependency.keyIdentifier == nil)
    }

    // MARK: - Diagnostic rendering for keyed slots

    @Test func renderMissingBindingForKeyedSlotIncludesKey() {
        let consumer = singleton("UserRepo")
        let dep = DependencyParameter(
            name: "db",
            type: "Database",
            kind: .injectProperty,
            location: mockLocation("UserRepo.swift", line: 3, column: 17),
            keyIdentifier: "Database.primary"
        )
        let errors = GraphResult.ValidationErrors(
            cycles: [],
            missingBindings: [MissingBinding(consumer: consumer, dependency: dep)],
            duplicateBindings: []
        )
        let report = renderValidationErrors(errors)
        #expect(
            report.contains(
                "UserRepo.swift:3:17: error: no binding produces 'Database' keyed 'Database.primary'"
            )
        )
    }

    @Test func renderDuplicateKeyedBindingsNamesTheKey() {
        let errors = GraphResult.ValidationErrors(
            cycles: [],
            missingBindings: [],
            duplicateBindings: [
                DuplicateBinding(
                    boundType: "Database",
                    keyIdentifier: "Database.primary",
                    bindings: [
                        providerProperty("dbA", boundType: "Database", key: "Database.primary"),
                        providerProperty("dbB", boundType: "Database", key: "Database.primary"),
                    ]
                )
            ]
        )
        let report = renderValidationErrors(errors)
        #expect(
            report.contains(
                "error: type 'Database' keyed 'Database.primary' has multiple bindings"
            )
        )
        // Keyed duplicates already say which slot is overloaded —
        // the fix-it note is only useful for unkeyed duplicates.
        #expect(!report.contains("note: to disambiguate"))
    }

    @Test func renderUnkeyedDuplicateAppendsFixItNote() {
        let errors = GraphResult.ValidationErrors(
            cycles: [],
            missingBindings: [],
            duplicateBindings: [
                DuplicateBinding(
                    boundType: "Database",
                    keyIdentifier: nil,
                    bindings: [
                        providerProperty("dbA", boundType: "Database"),
                        providerProperty("dbB", boundType: "Database"),
                    ]
                )
            ]
        )
        let report = renderValidationErrors(errors)
        #expect(report.contains("note: to disambiguate, declare named keys"))
        #expect(report.contains("BindingKey<Database>()"))
        #expect(report.contains("@Provides(Database.primary)"))
        #expect(report.contains("@Inject(Database.primary)"))
    }

    // MARK: - Whitespace-canonicalised type matching

    @Test func bindingsOfSameTypeWithDifferentWhitespaceAreDuplicates() throws {
        // `Router<X, Y>` and `Router<X,Y>` are the same type expression
        // up to whitespace. Both bindings should land in the same
        // graph identity slot — i.e. detected as duplicates rather
        // than coexisting as distinct slots.
        let result = buildDependencyGraph(from: [
            providerProperty("router1", boundType: "Router<X, Y>"),
            providerProperty("router2", boundType: "Router<X,Y>"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.duplicateBindings.count == 1)
    }

    @Test func consumerWithDifferentWhitespaceResolvesToProvider() throws {
        // The realistic asymmetry: provider writes the type one way,
        // consumer the other. Canonical-form identity makes them match
        // so resolution succeeds end-to-end.
        let result = buildDependencyGraph(from: [
            providerProperty("router", boundType: "Router<X, Y>"),
            singleton(
                "App",
                dependencies: [(name: "router", type: "Router<X,Y>")]
            ),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["Router<X, Y>", "App"])
    }

    @Test func internalAndOuterWhitespaceAreAllStripped() throws {
        // Variations beyond the trivial post-comma space: leading /
        // trailing inside the generic clause, spaces around the
        // bracket. All should canonicalise to the same form. Pin the
        // contract with a less-typical formatting so a regression
        // that only strips `, ` → `,` would still get caught.
        let result = buildDependencyGraph(from: [
            providerProperty("a", boundType: "Pair< Foo , Bar >"),
            singleton(
                "B",
                dependencies: [(name: "p", type: "Pair<Foo,Bar>")]
            ),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType } == ["Pair< Foo , Bar >", "B"])
    }

    // MARK: - Generic specialisation

    @Test func singleParamGenericSingletonSpecialisedForConcreteConsumer() throws {
        // A generic `Repository<T>` singleton with a dep of type `T`
        // matched against a consumer asking for `Repository<DynamoDBTable>`.
        // Specialisation substitutes T → DynamoDBTable in the dep,
        // emits a concrete `Repository<DynamoDBTable>` binding, and
        // resolves the consumer's dep against it.
        let result = buildDependencyGraph(from: [
            singleton(
                "Repository",
                dependencies: [(name: "table", type: "T")],
                generics: ["T"]
            ),
            singleton("DynamoDBTable"),
            singleton(
                "App",
                dependencies: [(name: "repo", type: "Repository<DynamoDBTable>")]
            ),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        let names = order.map { $0.boundType }
        // Specialised binding appears in the resolved graph with its
        // concrete type expression; DynamoDBTable resolved before it;
        // App last.
        #expect(names.contains("Repository<DynamoDBTable>"))
        #expect(names.contains("DynamoDBTable"))
        #expect(names.contains("App"))
        let dynamoIdx = names.firstIndex(of: "DynamoDBTable")!
        let repoIdx = names.firstIndex(of: "Repository<DynamoDBTable>")!
        let appIdx = names.firstIndex(of: "App")!
        #expect(dynamoIdx < repoIdx)
        #expect(repoIdx < appIdx)
    }

    @Test func multiParamGenericSingletonSpecialisedForConcreteConsumer() throws {
        // Two-parameter generic — `Pair<A, B>` with deps `first: A`,
        // `second: B`. Each parameter substitutes independently.
        let result = buildDependencyGraph(from: [
            singleton(
                "Pair",
                dependencies: [
                    (name: "first", type: "A"),
                    (name: "second", type: "B"),
                ],
                generics: ["A", "B"]
            ),
            singleton("Foo"),
            singleton("Bar"),
            singleton(
                "App",
                dependencies: [(name: "pair", type: "Pair<Foo, Bar>")]
            ),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        let names = order.map { $0.boundType }
        #expect(names.contains("Pair<Foo, Bar>"))
        #expect(names.contains("Foo"))
        #expect(names.contains("Bar"))
    }

    @Test func genericProviderFunctionSpecialisedCarriesConcreteArguments() throws {
        // A `@Provides func makeRepo<T>() -> Repository<T>` specialised
        // for a `Repository<DynamoDBTable>` consumer. The resulting
        // provider binding has `concreteGenericArguments` populated so
        // codegen can splice them at the call site
        // (`makeRepo<DynamoDBTable>()`).
        let result = buildDependencyGraph(from: [
            providerFunction(
                "makeRepo",
                boundType: "Repository<T>",
                dependencies: [],
                generics: ["T"]
            ),
            singleton(
                "App",
                dependencies: [(name: "repo", type: "Repository<DynamoDBTable>")]
            ),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        // Find the specialised provider binding and assert on its
        // concreteGenericArguments. Filter by accessPath to be sure
        // we're inspecting the provider, not a singleton with a
        // collide-y type name.
        let specialised = order.compactMap { binding -> DiscoveredProvider? in
            if case .provider(let provider) = binding,
                provider.accessPath == "makeRepo"
            {
                return provider
            }
            return nil
        }.first
        let provider = try #require(specialised)
        #expect(provider.boundType == "Repository<DynamoDBTable>")
        #expect(provider.concreteGenericArguments == ["DynamoDBTable"])
        // genericParameterNames cleared so the binding looks concrete
        // to the rest of the pipeline.
        #expect(provider.genericParameterNames.isEmpty)
    }

    @Test func multipleConsumersOfSameSpecialisationShareOneBinding() throws {
        // Two singletons both depend on `Repository<DynamoDBTable>`.
        // The specialisation phase should produce *one* specialised
        // binding that both consumers resolve against — not two, and
        // not a false ambiguity. The `originallyConcrete` snapshot
        // distinguishes "user-written concrete shadowing the generic"
        // (real ambiguity) from "specialisation just added an entry
        // and now a second consumer finds it" (legitimate dedup).
        let result = buildDependencyGraph(from: [
            singleton(
                "Repository",
                dependencies: [(name: "table", type: "T")],
                generics: ["T"]
            ),
            singleton("DynamoDBTable"),
            singleton(
                "AppA",
                dependencies: [(name: "repo", type: "Repository<DynamoDBTable>")]
            ),
            singleton(
                "AppB",
                dependencies: [(name: "repo", type: "Repository<DynamoDBTable>")]
            ),
        ])
        // No ambiguity — both consumers get the same specialised
        // binding.
        let order = try #require(result.outcome.topologicalOrder)
        let repoCount = order.filter {
            $0.boundType == "Repository<DynamoDBTable>"
        }.count
        #expect(repoCount == 1)
        // Both consumers appear in the order.
        let names = order.map { $0.boundType }
        #expect(names.contains("AppA"))
        #expect(names.contains("AppB"))
    }

    @Test func concreteAndGenericForSameInstantiationIsAmbiguous() throws {
        // A concrete `@Provides static let r: Repository<DynamoDBTable>`
        // exists alongside a generic `Repository<T>` scopeBound. Both
        // could satisfy a consumer's `Repository<DynamoDBTable>` dep,
        // which is ambiguous — Wire surfaces this as a duplicate-
        // binding error (consistent with how two concrete bindings for
        // the same type are handled) rather than silently picking one
        // over the other. User disambiguates by adding a key to one
        // side, or by removing one of the bindings.
        let result = buildDependencyGraph(from: [
            singleton(
                "Repository",
                dependencies: [(name: "table", type: "T")],
                generics: ["T"]
            ),
            providerProperty("explicit", boundType: "Repository<DynamoDBTable>"),
            singleton(
                "App",
                dependencies: [(name: "repo", type: "Repository<DynamoDBTable>")]
            ),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.duplicateBindings.count == 1)
        // The duplicate's identity matches the consumer's dep — the
        // canonical type expression and (in this case) the unkeyed
        // slot.
        let duplicate = try #require(errors.duplicateBindings.first)
        // Canonical type name (whitespace-stripped) — `parseGenericType`
        // canonicalises while extracting `(base, params)`, and the
        // identity carries that canonical form through.
        #expect(duplicate.boundType == "Repository<DynamoDBTable>")
        #expect(duplicate.keyIdentifier == nil)
        // Both the concrete provider and the generic singleton appear
        // in the duplicates list.
        #expect(duplicate.bindings.count == 2)
        let kinds = Set(
            duplicate.bindings.map { binding -> String in
                switch binding {
                case .scopeBound: return "scopeBound"
                case .provider: return "provider"
                }
            }
        )
        #expect(kinds == ["scopeBound", "provider"])
    }

    @Test func concreteAndGenericWithDifferentKeysCoexist() throws {
        // Counterpart to the ambiguity case: a keyed concrete binding
        // and an unkeyed generic for the same type live happily in
        // separate `(type, key)` slots. The keyed concrete satisfies
        // keyed consumers; the generic satisfies unkeyed concrete
        // requests via specialisation. No ambiguity because the
        // identities differ.
        let result = buildDependencyGraph(from: [
            singleton(
                "Repository",
                dependencies: [(name: "table", type: "T")],
                generics: ["T"]
            ),
            singleton("DynamoDBTable"),
            // Keyed concrete provider.
            .provider(
                DiscoveredProvider(
                    boundType: "Repository<DynamoDBTable>",
                    accessPath: "specialRepo",
                    form: .property,
                    dependencies: [],
                    genericParameterNames: [],
                    location: mockLocation("specialRepo.swift"),
                    keyIdentifier: "Repository.special"
                )
            ),
            singletonWithKeyedDep(
                "AppKeyed",
                depName: "repo",
                depType: "Repository<DynamoDBTable>",
                depKey: "Repository.special"
            ),
            singleton(
                "AppUnkeyed",
                dependencies: [(name: "repo", type: "Repository<DynamoDBTable>")]
            ),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        // Both Repository<DynamoDBTable> entries land — one keyed,
        // one specialised-unkeyed. Each consumer resolves to its
        // matching slot.
        let repoCount = order.filter {
            $0.boundType == "Repository<DynamoDBTable>"
        }.count
        #expect(repoCount == 2)
    }

    @Test func specialisedBindingDepThatIsAlsoGenericChainsThroughFixpoint() throws {
        // Specialisation of `Outer<T>` produces a binding with a dep
        // typed `T` (substituted to a concrete type). That concrete
        // type might *itself* be a generic instantiation requiring
        // specialisation. The iteration-to-fixpoint logic should
        // handle this — both `Outer<Inner<X>>` and `Inner<X>` resolve.
        let result = buildDependencyGraph(from: [
            singleton(
                "Outer",
                dependencies: [(name: "inner", type: "T")],
                generics: ["T"]
            ),
            singleton(
                "Inner",
                dependencies: [(name: "value", type: "U")],
                generics: ["U"]
            ),
            singleton("Value"),
            singleton(
                "App",
                dependencies: [(name: "outer", type: "Outer<Inner<Value>>")]
            ),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        let names = order.map { $0.boundType }
        // Both specialised bindings show up.
        #expect(names.contains("Outer<Inner<Value>>"))
        #expect(names.contains("Inner<Value>"))
        #expect(names.contains("Value"))
    }

    @Test func nestedSubstitutionInDepTypeStaysUnsubstitutedAndMissingBindingFires() throws {
        // Generic binding has a dep `box: Box<T>`. The substitution
        // rule only replaces deps whose type *exactly equals* a
        // parameter name — `Box<T>` doesn't qualify, so it passes
        // through. The specialised binding ends up with a dep
        // `box: Box<T>` (literal), which has no binding → missing-
        // binding error. Documented limitation; nested substitution
        // is deferred to a later iteration.
        let result = buildDependencyGraph(from: [
            singleton(
                "Wrapper",
                dependencies: [(name: "box", type: "Box<T>")],
                generics: ["T"]
            ),
            singleton(
                "App",
                dependencies: [(name: "wrapper", type: "Wrapper<Int>")]
            ),
        ])
        let errors = try #require(result.outcome.validationErrors)
        // The unresolved dep is `box: Box<T>` on the specialised
        // Wrapper<Int> binding.
        #expect(errors.missingBindings.contains { $0.dependency.type == "Box<T>" })
    }

    @Test func noMatchingGenericProducesMissingBindingForInstantiation() throws {
        // Consumer asks for `Repository<X>` but no generic Repository
        // exists. Standard missing-binding error — the specialisation
        // phase finds no candidates and the dep falls through to the
        // existing missing-binding detection.
        let result = buildDependencyGraph(from: [
            singleton(
                "App",
                dependencies: [(name: "repo", type: "Repository<X>")]
            )
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.missingBindings.count == 1)
        #expect(errors.missingBindings[0].dependency.type == "Repository<X>")
    }

    @Test func multipleGenericCandidatesProduceAmbiguityError() throws {
        // Two generic bindings of the same `(base, paramCount, key)`
        // shape both match a consumer's concrete instantiation. Wire
        // can't pick — emits a duplicate-binding error listing the
        // candidates so the user disambiguates (typically with keys).
        let result = buildDependencyGraph(from: [
            providerFunction(
                "makeRepoA",
                boundType: "Repository<T>",
                dependencies: [],
                generics: ["T"]
            ),
            providerFunction(
                "makeRepoB",
                boundType: "Repository<T>",
                dependencies: [],
                generics: ["T"]
            ),
            singleton(
                "App",
                dependencies: [(name: "repo", type: "Repository<DynamoDBTable>")]
            ),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.duplicateBindings.count == 1)
        let duplicate = try #require(errors.duplicateBindings.first)
        #expect(duplicate.boundType == "Repository<DynamoDBTable>")
        #expect(duplicate.bindings.count == 2)
    }

    // MARK: - Generated-identifier collisions

    @Test func bindingsWithCollidingAccessorNamesAreReported() throws {
        // `Logger` and `Logger?` are distinct `(type, key)` identities
        // (different textual type expressions → different identity
        // slots → they coexist in the graph), but `sanitizeIdentifier`
        // strips the `?` from `Logger?`, leaving both with the same
        // generated accessor name `logger`. Codegen can't emit two
        // `let logger:` lines, so Wire surfaces the collision as a
        // validation error.
        let result = buildDependencyGraph(from: [
            providerProperty("plainLogger", boundType: "Logger"),
            providerProperty("optionalLogger", boundType: "Logger?"),
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.identifierCollisions.count == 1)
        let collision = try #require(errors.identifierCollisions.first)
        #expect(collision.identifier == "logger")
        #expect(collision.bindings.count == 2)
    }

    @Test func renderIdentifierCollisionNamesTheGeneratedAccessor() {
        let errors = GraphResult.ValidationErrors(
            cycles: [],
            missingBindings: [],
            duplicateBindings: [],
            identifierCollisions: [
                IdentifierCollision(
                    identifier: "logger",
                    bindings: [
                        providerProperty("a", boundType: "Logger"),
                        providerProperty("b", boundType: "Logger?"),
                    ]
                )
            ]
        )
        let report = renderValidationErrors(errors)
        #expect(
            report.contains(
                "error: generated accessor name 'logger' collides across multiple bindings"
            )
        )
        #expect(report.contains("note: also generates 'logger'"))
    }

    @Test func specialisationHonoursWhitespaceCanonicalisation() throws {
        // Provider declares the dep type with spaces; consumer
        // without (or vice versa). The canonicalised identity should
        // make them match, just as for non-generic bindings.
        let result = buildDependencyGraph(from: [
            singleton(
                "Pair",
                dependencies: [
                    (name: "first", type: "A"),
                    (name: "second", type: "B"),
                ],
                generics: ["A", "B"]
            ),
            singleton("Foo"),
            singleton("Bar"),
            singleton(
                "App",
                // Spaces inside the generic clause — should still
                // parse and match correctly.
                dependencies: [(name: "pair", type: "Pair<Foo,  Bar>")]
            ),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.boundType }.contains { $0.contains("Pair<") })
    }
}
