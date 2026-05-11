import Testing

@testable import WireGenCore

@Suite("Graph")
struct GraphTests {
    // MARK: - Helpers

    /// A stable mock location derived from a file path. Line and column
    /// default to 1 so synthetic test bindings have something deterministic
    /// for `formattedPrefix`-style assertions.
    private func mockLocation(_ file: String, line: Int = 1, column: Int = 1) -> WireGenCore.SourceLocation {
        WireGenCore.SourceLocation(file: file, line: line, column: column)
    }

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
        return .singleton(
            DiscoveredSingleton(
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
        .singleton(
            DiscoveredSingleton(
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
}
