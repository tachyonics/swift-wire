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

    @Test func emptyGraphProducesEmptyOrder() {
        let result = buildDependencyGraph(from: [])
        #expect(result.topologicalOrder.isEmpty)
        #expect(!result.hasErrors)
    }

    @Test func singleNodeNoDependenciesIsInOrder() {
        let result = buildDependencyGraph(from: [singleton("A")])
        #expect(result.topologicalOrder.map { $0.typeName } == ["A"])
        #expect(!result.hasErrors)
    }

    @Test func twoNodesOneDependencyDependencyConstructedFirst() {
        // A depends on B → topological order is B, then A.
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B"),
        ])
        #expect(result.topologicalOrder.map { $0.typeName } == ["B", "A"])
        #expect(!result.hasErrors)
    }

    @Test func threeNodeChainOrderedCorrectly() {
        // A → B → C, topological order: C, B, A.
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "c", type: "C")]),
            singleton("C"),
        ])
        #expect(result.topologicalOrder.map { $0.typeName } == ["C", "B", "A"])
        #expect(!result.hasErrors)
    }

    @Test func diamondDependencySingleConstructionOfShared() {
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
        #expect(!result.hasErrors)
        let order = result.topologicalOrder.map { $0.typeName }
        #expect(order.count == 4)
        #expect(order.filter { $0 == "D" }.count == 1)

        let dIndex = order.firstIndex(of: "D")!
        let bIndex = order.firstIndex(of: "B")!
        let cIndex = order.firstIndex(of: "C")!
        let aIndex = order.firstIndex(of: "A")!
        #expect(dIndex < bIndex)
        #expect(dIndex < cIndex)
        #expect(bIndex < aIndex)
        #expect(cIndex < aIndex)
    }

    // MARK: - Cycle detection

    @Test func twoNodeCycleDetected() {
        // A → B → A
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "a", type: "A")]),
        ])
        #expect(result.cycles.count == 1)
        #expect(result.hasErrors)
        let cycleNames = Set(result.cycles[0].map { $0.typeName })
        #expect(cycleNames == ["A", "B"])
    }

    @Test func threeNodeCycleDetected() {
        // A → B → C → A
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "c", type: "C")]),
            singleton("C", dependencies: [(name: "a", type: "A")]),
        ])
        #expect(result.cycles.count == 1)
        #expect(result.hasErrors)
        let cycleNames = Set(result.cycles[0].map { $0.typeName })
        #expect(cycleNames == ["A", "B", "C"])
    }

    @Test func selfLoopDetectedAsCycle() {
        // A → A
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "a", type: "A")])
        ])
        #expect(result.cycles.count == 1)
        #expect(result.hasErrors)
        #expect(result.cycles[0].first?.typeName == "A")
    }

    @Test func disjointGraphsSomeCyclesOnlyReportsCycles() {
        // Two disjoint groups: A → B → A (cycle) and C (no deps).
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "b", type: "B")]),
            singleton("B", dependencies: [(name: "a", type: "A")]),
            singleton("C"),
        ])
        #expect(result.cycles.count == 1)
        #expect(result.hasErrors)
    }

    // MARK: - Missing bindings

    @Test func dependencyOnUndiscoveredTypeRecordedAsMissing() {
        // A depends on Missing — no @Singleton found for it.
        let result = buildDependencyGraph(from: [
            singleton("A", dependencies: [(name: "x", type: "Missing")])
        ])
        #expect(result.missingBindings.count == 1)
        #expect(result.hasErrors)
        #expect(result.missingBindings[0].consumer.typeName == "A")
        #expect(result.missingBindings[0].dependency.type == "Missing")
    }

    @Test func multipleMissingBindingsAllRecorded() {
        let result = buildDependencyGraph(from: [
            singleton(
                "A",
                dependencies: [
                    (name: "x", type: "MissingX"),
                    (name: "y", type: "MissingY"),
                ]
            )
        ])
        #expect(result.missingBindings.count == 2)
    }

    // MARK: - Generic types are skipped

    @Test func genericSingletonIsSkippedFromGraph() {
        let result = buildDependencyGraph(from: [
            singleton("Repository", dependencies: [], generics: ["Model"]),
            singleton("App"),
        ])
        #expect(result.skipped.map { $0.typeName } == ["Repository"])
        #expect(result.topologicalOrder.map { $0.typeName } == ["App"])
        #expect(!result.hasErrors)
    }

    @Test func dependencyOnGenericNameIsMissingNotResolvedToGeneric() {
        // App depends on Repository<Model> by name "Repository". Generic
        // singletons aren't in the resolved graph, so this is a missing
        // binding rather than a successful match.
        let result = buildDependencyGraph(from: [
            singleton("Repository", dependencies: [], generics: ["Model"]),
            singleton("App", dependencies: [(name: "repo", type: "Repository")]),
        ])
        #expect(result.skipped.count == 1)
        #expect(result.missingBindings.count == 1)
        #expect(result.hasErrors)
    }

    // MARK: - Determinism

    @Test func topologicalOrderIsDeterministicAcrossInputOrders() {
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
        #expect(
            forward.topologicalOrder.map { $0.typeName }
                == reversed.topologicalOrder.map { $0.typeName }
        )
    }
}
