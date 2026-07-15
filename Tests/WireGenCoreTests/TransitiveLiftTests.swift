import Testing

@testable import WireGenCore

/// Increment 3.1c — transitive lift. A generic `@Singleton` earns lift-node status and threads its
/// parameter through a *parameterised* dependency on another lift node — the route-contributor proxy
/// `P<Repository>` holding `TodosController<Repository>` — not only through a bare-parameter
/// dependency (`repository: Repository`). Two extensions: `undeterminedGenericParameters`
/// (determination reads generic-argument occurrences) and `bridgedDependencyIdentity` (a parameterised
/// dependency resolves to the wrapped lift node's structural identity).
@Suite("Transitive lift")
struct TransitiveLiftTests {
    private func binding(
        typeName: String = "Proxy",
        params: [String] = ["Repository"],
        constraints: [String: String] = ["Repository": "TodoRepository"],
        deps: [(name: String?, type: String)]
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: typeName,
                typeKind: "struct",
                genericParameterNames: params,
                genericParameterConstraints: constraints,
                dependencies: deps.map {
                    DependencyParameter(
                        name: $0.name,
                        type: $0.type,
                        kind: .injectInitParameter,
                        location: mockLocation("P.swift")
                    )
                },
                location: mockLocation("P.swift"),
                originModule: testModule
            )
        )
    }

    private func dependency(_ name: String?, _ type: String) -> DependencyParameter {
        DependencyParameter(name: name, type: type, kind: .injectInitParameter, location: mockLocation("P.swift"))
    }

    // MARK: - Determination

    @Test func bareParameterDependencyStillDetermines() {
        let controller = binding(typeName: "TodosController", deps: [("repository", "Repository")])
        #expect(controller.undeterminedGenericParameters.isEmpty)
        #expect(controller.isLiftNode)
    }

    @Test func parameterAsGenericArgumentDetermines() {
        // The proxy reaches `Repository` only through `TodosController<Repository>`.
        let proxy = binding(deps: [("controller", "TodosController<Repository>")])
        #expect(proxy.undeterminedGenericParameters.isEmpty)
        #expect(proxy.isLiftNode)
    }

    @Test func nestedParameterAsGenericArgumentDetermines() {
        let proxy = binding(deps: [("controller", "Wrapper<Box<Repository>>")])
        #expect(proxy.undeterminedGenericParameters.isEmpty)
    }

    @Test func substringOccurrenceDoesNotDetermine() {
        // `RepositoryStore` must not satisfy `Repository`.
        let notDetermined = binding(deps: [("x", "Holder<RepositoryStore>")])
        #expect(notDetermined.undeterminedGenericParameters == ["Repository"])
        #expect(!notDetermined.isLiftNode)
    }

    @Test func unconstrainedParameterNeverDetermines() {
        let unconstrained = binding(constraints: [:], deps: [("controller", "TodosController<Repository>")])
        #expect(unconstrained.undeterminedGenericParameters == ["Repository"])
    }

    // MARK: - Resolution (bridging)

    @Test func bridgesBareParameterToSomeConstraint() {
        let controller = binding(typeName: "TodosController", deps: [("repository", "Repository")])
        let identity = bridgedDependencyIdentity(dependency("repository", "Repository"), in: controller)
        #expect(identity.base == "someTodoRepository")
    }

    @Test func bridgesParameterisedDependencyToWrappedLiftNodeIdentity() {
        let proxy = binding(deps: [("controller", "TodosController<Repository>")])
        let identity = bridgedDependencyIdentity(dependency("controller", "TodosController<Repository>"), in: proxy)
        // Matches the controller lift node's structural identity `TodosController<some TodoRepository>`.
        #expect(identity.base == "TodosController<someTodoRepository>")
    }

    @Test func leavesNonParameterDependencyUnchanged() {
        // The proxy's factory dependency carries no generic parameter — its identity is untouched.
        let proxy = binding(deps: [
            ("controller", "TodosController<Repository>"),
            ("_wireFactory_X", "_WireFactory_X"),
        ])
        let identity = bridgedDependencyIdentity(dependency("_wireFactory_X", "_WireFactory_X"), in: proxy)
        #expect(identity.base == "_WireFactory_X")
    }

    @Test func doesNotBridgeForNonLiftNode() {
        let plain = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Plain",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("P.swift"),
                originModule: testModule
            )
        )
        let identity = bridgedDependencyIdentity(dependency("x", "Foo<Bar>"), in: plain)
        #expect(identity.base == "Foo<Bar>")
    }
}
