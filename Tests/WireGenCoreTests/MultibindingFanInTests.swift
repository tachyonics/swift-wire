import Testing

@testable import WireGenCore

/// Step 4 of iteration 5β: the fan-in pass. A declared multibinding key
/// becomes a synthesised aggregate binding whose dependencies are its
/// contributors, so it flows through the ordinary graph pipeline —
/// topologically sorting after every contributor, resolving consumers by
/// identity, and never tripping duplicate detection on co-contributors.
/// Collected and mapped keys are covered here; builder keys are deferred
/// to Step 5 (their result type is read from the builder).
@Suite("Multibinding fan-in")
struct MultibindingFanInTests {
    // MARK: - Helpers

    private func contributor(
        _ name: String,
        to keyReference: String,
        order: Int? = nil,
        atKey: String? = nil
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("\(name).swift"),
                contributions: [
                    Contribution(
                        keyReference: keyReference,
                        order: order,
                        mapKeyExpression: atKey,
                        location: mockLocation("\(name).swift")
                    )
                ]
            )
        )
    }

    private func consumer(
        _ name: String,
        injecting collectionType: String,
        key: String
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: "x",
                        type: collectionType,
                        kind: .injectProperty,
                        location: mockLocation("\(name).swift"),
                        keyIdentifier: key
                    )
                ],
                location: mockLocation("\(name).swift")
            )
        )
    }

    private func collectedKey(_ reference: String, element: String) -> DiscoveredMultibindingKey {
        DiscoveredMultibindingKey(
            keyReference: reference,
            flavour: .collected,
            typeArguments: [element],
            location: mockLocation("\(reference).swift"),
            accessLevel: .internal
        )
    }

    private func mappedKey(
        _ reference: String,
        key: String,
        value: String
    ) -> DiscoveredMultibindingKey {
        DiscoveredMultibindingKey(
            keyReference: reference,
            flavour: .mapped,
            typeArguments: [key, value],
            location: mockLocation("\(reference).swift"),
            accessLevel: .internal
        )
    }

    // MARK: - Topological placement

    @Test func aggregateSortsAfterAllContributors() throws {
        let result = buildDependencyGraph(
            from: [
                contributor("Auth", to: "App.services"),
                contributor("Logging", to: "App.services"),
            ],
            multibindingKeys: [collectedKey("App.services", element: "any Service")]
        )
        let names = try #require(result.outcome.topologicalOrder).map { $0.boundType }
        let aggregateIndex = try #require(names.firstIndex(of: "[any Service]"))
        let authIndex = try #require(names.firstIndex(of: "Auth"))
        let loggingIndex = try #require(names.firstIndex(of: "Logging"))
        #expect(authIndex < aggregateIndex)
        #expect(loggingIndex < aggregateIndex)
    }

    @Test func consumerSortsAfterAggregate() throws {
        let result = buildDependencyGraph(
            from: [
                contributor("Auth", to: "App.services"),
                consumer("Dashboard", injecting: "[any Service]", key: "App.services"),
            ],
            multibindingKeys: [collectedKey("App.services", element: "any Service")]
        )
        #expect(result.outcome.validationErrors == nil)
        let names = try #require(result.outcome.topologicalOrder).map { $0.boundType }
        let aggregateIndex = try #require(names.firstIndex(of: "[any Service]"))
        let consumerIndex = try #require(names.firstIndex(of: "Dashboard"))
        #expect(aggregateIndex < consumerIndex)
    }

    @Test func mappedAggregateSortsAfterContributors() throws {
        let result = buildDependencyGraph(
            from: [
                contributor("Fast", to: "App.strategies", atKey: "\"fast\""),
                contributor("Slow", to: "App.strategies", atKey: "\"slow\""),
            ],
            multibindingKeys: [mappedKey("App.strategies", key: "String", value: "any Strategy")]
        )
        let names = try #require(result.outcome.topologicalOrder).map { $0.boundType }
        let aggregateIndex = try #require(names.firstIndex(of: "[String: any Strategy]"))
        #expect(try #require(names.firstIndex(of: "Fast")) < aggregateIndex)
        #expect(try #require(names.firstIndex(of: "Slow")) < aggregateIndex)
    }

    // MARK: - No false duplicates; contributor liveness

    @Test func coContributorsAreNotDuplicates() {
        let result = buildDependencyGraph(
            from: [
                contributor("Auth", to: "App.services"),
                contributor("Logging", to: "App.services"),
            ],
            multibindingKeys: [collectedKey("App.services", element: "any Service")]
        )
        #expect(result.outcome.validationErrors == nil)
    }

    @Test func contributorReachableOnlyViaAggregateIsConstructed() throws {
        // `Auth` is never injected directly — only contributed. It must
        // still appear in the order because the aggregate depends on it.
        let result = buildDependencyGraph(
            from: [
                contributor("Auth", to: "App.services"),
                consumer("Dashboard", injecting: "[any Service]", key: "App.services"),
            ],
            multibindingKeys: [collectedKey("App.services", element: "any Service")]
        )
        let names = try #require(result.outcome.topologicalOrder).map { $0.boundType }
        #expect(names.contains("Auth"))
    }

    // MARK: - Empty and deferred cases

    @Test func emptyAggregateStillResolvesForConsumer() throws {
        // Declared key, zero contributors, but a consumer: the aggregate
        // exists (empty) so the consumer resolves rather than erroring.
        let result = buildDependencyGraph(
            from: [consumer("Dashboard", injecting: "[any Service]", key: "App.services")],
            multibindingKeys: [collectedKey("App.services", element: "any Service")]
        )
        #expect(result.outcome.validationErrors == nil)
        let names = try #require(result.outcome.topologicalOrder).map { $0.boundType }
        #expect(names.contains("[any Service]"))
    }

    @Test func builderKeyProducesNoAggregateYet() {
        // Step 4 can't derive a builder's result type, so no aggregate is
        // synthesised — flips to a real aggregate when Step 5 lands.
        let key = DiscoveredMultibindingKey(
            keyReference: "App.middleware",
            flavour: .builder,
            typeArguments: ["MiddlewareBuilder"],
            location: mockLocation("App.swift"),
            accessLevel: .internal
        )
        let result = buildDependencyGraph(
            from: [contributor("LogMiddleware", to: "App.middleware")],
            multibindingKeys: [key]
        )
        let order = result.outcome.topologicalOrder
        #expect(order?.contains { $0.keyIdentifier == "App.middleware" } != true)
    }
}
