import Testing

@testable import WireGenCore

/// M2.1: graph-conformance emission. Pins that a discovered
/// `WireGraphConformanceV1` emits `extension _WireGraph: <Protocol>`, mapping each
/// member to the aggregate binding for its multibinding key — the member's type
/// spelled from the aggregate's product type so the protocol's associated types
/// are inferred from the witness.
@Suite("Graph conformance emission")
struct GraphConformanceEmissionTests {
    private func contributor(_ name: String, to keyReference: String) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("\(name).swift"),
                contributions: [
                    Contribution(keyReference: keyReference, location: mockLocation("\(name).swift"))
                ],
                originModule: testModule
            )
        )
    }

    private func collectedKey(_ reference: String, element: String) -> DiscoveredMultibindingKey {
        DiscoveredMultibindingKey(
            keyReference: reference,
            flavour: .collected,
            typeArguments: [element],
            location: mockLocation("\(reference).swift"),
            accessLevel: .internal,
            originModule: testModule
        )
    }

    @Test func emitsExtensionMappingMemberToAggregateProperty() throws {
        // A `CollectedKey<any RouteContributor>` with one contributor synthesises an
        // aggregate `[any RouteContributor]` binding; the conformance maps `routes`
        // to it.
        let graph = buildDependencyGraph(
            from: [contributor("HelloController", to: "App.routes")],
            multibindingKeys: [collectedKey("App.routes", element: "any RouteContributor")]
        )
        let order = try #require(graph.outcome.topologicalOrder)

        let conformance = DiscoveredGraphConformance(
            protocolName: "HummingbirdComposable",
            members: [.init(name: "routes", keyReference: "App.routes")],
            location: mockLocation("Conformance.swift"),
            originModule: testModule
        )

        let output = renderWireGraph(imports: [], topologicalOrder: order, graphConformances: [conformance])

        #expect(output.contains("extension _WireGraph: HummingbirdComposable {"))
        // Member type is the aggregate's product type; the body reads it off the graph.
        #expect(output.contains("var routes: [any RouteContributor] { self."))
    }

    @Test func memberWithNoContributorsMapsToEmptyCollection() {
        // A conformance whose key has no contributors in this graph still emits — the
        // absent member maps to an empty collection, so the graph conforms and a
        // facade's `apply` works even when nothing is contributed.
        let order: [DiscoveredBinding] = [
            .scopeBound(
                DiscoveredScopeBoundType(
                    typeName: "App",
                    typeKind: "struct",
                    genericParameterNames: [],
                    dependencies: [],
                    location: mockLocation("App.swift"),
                    originModule: testModule
                )
            )
        ]

        let conformance = DiscoveredGraphConformance(
            protocolName: "HummingbirdComposable",
            members: [
                .init(name: "routes", keyReference: "App.routes"),
                .init(name: "services", keyReference: "App.services"),
            ],
            location: mockLocation("Conformance.swift"),
            originModule: testModule
        )

        let output = renderWireGraph(
            imports: [],
            topologicalOrder: order,
            graphConformances: [conformance],
            multibindingKeys: [
                collectedKey("App.routes", element: "any RouteContributor"),
                collectedKey("App.services", element: "any Service"),
            ]
        )

        #expect(output.contains("extension _WireGraph: HummingbirdComposable {"))
        #expect(output.contains("var routes: [any RouteContributor] { [] }"))
        #expect(output.contains("var services: [any Service] { [] }"))
    }

    @Test func noConformancesEmitNoExtension() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                .scopeBound(
                    DiscoveredScopeBoundType(
                        typeName: "App",
                        typeKind: "struct",
                        genericParameterNames: [],
                        dependencies: [],
                        location: mockLocation("App.swift"),
                        originModule: testModule
                    )
                )
            ]
        )
        #expect(!output.contains("extension _WireGraph:"))
    }
}
