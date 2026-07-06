import Foundation
import Testing
import Wire

/// M2.7 Core end-to-end: the generated graph carries a codegen-baked `introspect()`
/// returning a framework-agnostic wiring model (bindings, kinds, scopes, dependency
/// edges). Asserts on the `IntrospectionExample` fixture plus, robustly, that every
/// binding kind the shared integration graph produces is surfaced.
@Suite("Introspection (end-to-end)")
struct IntrospectionTests {
    @Test func introspectSurfacesKindsScopesAndEdges() async throws {
        let graph = try await Wire.bootstrap()
        let model = graph.introspect()

        let root = try #require(model.bindings.first { $0.type == "IntrospectionRoot" })
        #expect(root.kind == .singleton)
        #expect(root.scope == nil)
        #expect(root.key == nil)
        #expect(root.dependencies.contains { $0.type == "IntrospectionLeaf" })

        let leaf = try #require(model.bindings.first { $0.type == "IntrospectionLeaf" })
        #expect(leaf.kind == .singleton)
        #expect(leaf.dependencies.isEmpty)

        // The shared integration graph also carries `@Provides` providers and
        // multibinding aggregates — introspection surfaces those kinds too.
        #expect(model.bindings.contains { $0.kind == .provider })
        #expect(model.bindings.contains { $0.kind == .aggregate })
    }

    @Test func introspectIsCodable() async throws {
        let model = try await Wire.bootstrap().introspect()
        let data = try JSONEncoder().encode(model)
        let round = try JSONDecoder().decode(WiringModel.self, from: data)
        #expect(round.bindings.count == model.bindings.count)
    }
}
