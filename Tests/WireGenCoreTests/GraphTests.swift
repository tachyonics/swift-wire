import Testing

@testable import WireGenCore

@Suite("Graph")
struct GraphTests {
    // MARK: - Helpers

    private func singleton(
        _ name: String,
        dependencies: [(name: String, type: String)] = [],
        generics: [String] = []
    ) -> DiscoveredSingleton {
        let deps = dependencies.map {
            DependencyParameter(name: $0.name, type: $0.type, kind: .injectProperty)
        }
        return DiscoveredSingleton(
            typeName: name,
            typeKind: "struct",
            genericParameterNames: generics,
            dependencies: deps,
            sourcePath: "\(name).swift"
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
        #expect(order.map { $0.typeName } == ["A"])
    }

    @Test func twoNodesOneDependencyDependencyConstructedFirst() throws {
        // A depends on B → topological order is B, then A.
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.typeName } == ["B", "A"])
    }

    @Test func threeNodeChainOrderedCorrectly() throws {
        // A → B → C, topological order: C, B, A.
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "c", type: "C")]),
            singleton("C"),
        ])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.typeName } == ["C", "B", "A"])
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
        let names = order.map { $0.typeName }
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
        let cycleNames = Set(errors.cycles[0].map { $0.typeName })
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
        let cycleNames = Set(errors.cycles[0].map { $0.typeName })
        #expect(cycleNames == ["A", "B", "C"])
    }

    @Test func selfLoopDetectedAsCycle() throws {
        // A → A
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "a", type: "A")])
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.cycles.count == 1)
        #expect(errors.cycles[0].first?.typeName == "A")
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
        // A depends on Missing — no @Singleton found for it.
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "x", type: "Missing")])
        ])
        let errors = try #require(result.outcome.validationErrors)
        #expect(errors.missingBindings.count == 1)
        #expect(errors.missingBindings[0].consumer.typeName == "A")
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

    // MARK: - Generic types are skipped

    @Test func genericSingletonIsSkippedFromGraph() throws {
        let result = buildDependencyGraph(from: [
            singleton("Repository", dependencies: [], generics: ["Model"]),
            singleton("App"),
        ])
        #expect(result.skipped.map { $0.typeName } == ["Repository"])
        let order = try #require(result.outcome.topologicalOrder)
        #expect(order.map { $0.typeName } == ["App"])
    }

    @Test func dependencyOnGenericNameIsMissingNotResolvedToGeneric() throws {
        // App depends on Repository<Model> by name "Repository". Generic
        // singletons aren't in the resolved graph, so this is a missing
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
        let inputForward: [DiscoveredSingleton] = [
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
            forwardOrder.map { $0.typeName } == reversedOrder.map { $0.typeName }
        )
    }
}
