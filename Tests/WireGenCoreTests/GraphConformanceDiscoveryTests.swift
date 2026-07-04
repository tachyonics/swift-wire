import Testing

@testable import WireGenCore

/// M2.1: graph-conformance declarations. These pin that `WireGraphConformanceV1`
/// declarations are discovered anywhere in source with their protocol name and
/// member-to-key mappings (read syntactically — the referenced types needn't
/// exist), and that non-matching declarations are ignored.
@Suite("Graph conformance discovery")
struct GraphConformanceDiscoveryTests {
    private func conformances(in source: String) -> [DiscoveredGraphConformance] {
        discover(in: source, sourcePath: "Conformances.swift", module: testModule).graphConformances
    }

    @Test func capturesProtocolAndMemberMappings() throws {
        let source = """
            enum HummingbirdComposition {
                static let conformance = WireGraphConformanceV1(
                    conformsTo: (any HummingbirdComposable).self,
                    members: [
                        .init("routes", from: HummingbirdKeys.routes),
                        .init("middleware", from: HummingbirdKeys.middleware),
                    ]
                )
            }
            """
        let result = conformances(in: source)
        #expect(result.count == 1)
        let conformance = try #require(result.first)
        #expect(conformance.protocolName == "HummingbirdComposable")
        #expect(
            conformance.members == [
                .init(name: "routes", keyReference: "HummingbirdKeys.routes"),
                .init(name: "middleware", keyReference: "HummingbirdKeys.middleware"),
            ]
        )
        #expect(conformance.originModule == testModule)
    }

    @Test func plainProtocolMetatypeAlsoWorks() throws {
        // `P.self` without `any` — the same protocol name is extracted.
        let source = """
            let c = WireGraphConformanceV1(conformsTo: HummingbirdComposable.self, members: [])
            """
        let conformance = try #require(conformances(in: source).first)
        #expect(conformance.protocolName == "HummingbirdComposable")
        #expect(conformance.members.isEmpty)
    }

    @Test func nonConformanceDeclarationsIgnored() {
        let source = """
            enum Keys {
                static let primary = BindingKey<Database>()
                static let count = 3
            }
            """
        #expect(conformances(in: source).isEmpty)
    }
}
