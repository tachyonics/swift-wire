import Testing

@testable import WireGenCore

/// Iteration 8e: adapter-registration emission. These pin that resolved
/// registrations emit `_wireRegister` calls into the default bootstrap, after
/// every binding is constructed and before the return, and that the argument
/// labels are rendered (or omitted) correctly.
@Suite("Adapter emission")
struct AdapterEmissionTests {
    private func singleton(_ name: String) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("\(name).swift"),
                originModule: testModule
            )
        )
    }

    private func provider(_ accessPath: String, boundType: String) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: accessPath,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(accessPath).swift"),
                originModule: testModule
            )
        )
    }

    private func registration(
        _ callee: String,
        _ arguments: [(label: String?, localName: String)]
    ) -> ResolvedAdapterRegistration {
        ResolvedAdapterRegistration(
            calleeType: callee,
            phase: .postGraph,
            arguments: arguments.map { .init(label: $0.label, localName: $0.localName) }
        )
    }

    @Test func emitsRegisterCallAfterConstructionBeforeReturn() throws {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [singleton("SimpleController"), provider("Config.router", boundType: "Router")],
            adapterRegistrations: [
                registration(
                    "SimpleController",
                    [(label: "instance", localName: "simpleController"), (label: "router", localName: "router")]
                )
            ]
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func index(containing needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
        let call = try #require(
            index(containing: "SimpleController._wireRegister(instance: simpleController, router: router)")
        )
        let construction = try #require(index(containing: "let simpleController = SimpleController()"))
        let returnStatement = try #require(index(containing: "return _WireGraph("))
        #expect(construction < call)
        #expect(call < returnStatement)
    }

    @Test func noRegistrationsEmitNoRegisterCall() {
        let output = renderWireGraph(imports: [], topologicalOrder: [singleton("App")])
        #expect(!output.contains("_wireRegister"))
    }

    @Test func unlabelledArgumentOmitsLabel() {
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [singleton("App")],
            adapterRegistrations: [registration("App", [(label: nil, localName: "app")])]
        )
        #expect(output.contains("App._wireRegister(app)"))
    }
}
