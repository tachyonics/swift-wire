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

    @Test func registrationEmittedBeforeAConsumerOfItsCollaborator() throws {
        // `Application` is ordered after the registration's args (Step 1's ordering
        // edges guarantee this in a real graph; simulated here by the order).
        // Codegen must emit `_wireRegister` as soon as both its arg-locals exist —
        // i.e. after `SimpleController`, *before* `Application` — so `Application`
        // is built from an already-registered router.
        let output = renderWireGraph(
            imports: [],
            topologicalOrder: [
                provider("Config.router", boundType: "Router"),
                singleton("SimpleController"),
                singleton("Application"),
            ],
            adapterRegistrations: [
                registration(
                    "SimpleController",
                    [(label: "instance", localName: "simpleController"), (label: "router", localName: "router")]
                )
            ]
        )
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func index(containing needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
        let controller = try #require(index(containing: "let simpleController = SimpleController()"))
        let call = try #require(
            index(containing: "SimpleController._wireRegister(instance: simpleController, router: router)")
        )
        let consumer = try #require(index(containing: "let application = Application()"))
        #expect(controller < call)
        #expect(call < consumer)
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
