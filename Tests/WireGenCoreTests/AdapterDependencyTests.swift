import Testing

@testable import WireGenCore

/// Adapter dependencies — the `.injectsFromGraph` capability of
/// `WireAdapterAnnotationV1`. An adapter declares that its annotation, applied with a type
/// argument (`@Middleware(T.self)`), injects a dependency on `T` (an input edge) — the
/// symmetric complement of the `.contributes(to:)` capability (an output edge). Pins the
/// three moving parts: discovery of the capability, use-site capture of the type argument,
/// and the post-aggregation injection of a synthetic dependency.
@Suite("Adapter dependency")
struct AdapterDependencyTests {
    @Test func discoversInjectsDependencyCapability() throws {
        let source = """
            enum WireMVCAdapter {
                static let middleware = WireAdapterAnnotationV1(
                    annotation: "Middleware", capability: .injectsFromGraph)
            }
            """
        let found = try #require(
            discover(in: source, sourcePath: "Adapter.swift", module: testModule).adapterAnnotations.first
        )
        #expect(found.annotationName == "Middleware")
        #expect(found.capability == .injectsFromGraph)
    }

    @Test func capturesUseSiteArgument() {
        let source = """
            @Singleton
            @Middleware(SessionMiddlewareFactory.self)
            struct Controller {}
            """
        let sites = discover(in: source, sourcePath: "C.swift", module: testModule).aliasUseSites
        #expect(
            sites.contains {
                $0.annotationName == "Middleware"
                    && $0.targetIdentity == "Controller"
                    && $0.argument == "SessionMiddlewareFactory.self"
            }
        )
    }

    @Test func injectsSynthesizedDependency() throws {
        let binding = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Controller",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("C.swift"),
                originModule: testModule
            )
        )
        let annotation = DiscoveredAdapterAnnotation(
            annotationName: "Middleware",
            capability: .injectsFromGraph,
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
        let useSite = ContributionAliasUseSite(
            annotationName: "Middleware",
            targetIdentity: "Controller",
            argument: "SessionMiddlewareFactory.self",
            location: mockLocation("C.swift"),
            originModule: testModule
        )

        let injected = injectAdapterDependencies(
            into: [binding],
            annotations: [annotation],
            useSites: [useSite],
            bindingKeys: []
        )
        let deps = try #require(injected.first?.dependencies)
        #expect(deps.contains { $0.type == "SessionMiddlewareFactory" && $0.name == "_wireSessionMiddlewareFactory" })
    }

    private func controllerBinding() -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Controller",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("C.swift"),
                originModule: testModule
            )
        )
    }
    private func middlewareAnnotation() -> DiscoveredAdapterAnnotation {
        DiscoveredAdapterAnnotation(
            annotationName: "Middleware",
            capability: .injectsFromGraph,
            location: mockLocation("A.swift"),
            originModule: testModule
        )
    }
    private func useSite(argument: String) -> ContributionAliasUseSite {
        ContributionAliasUseSite(
            annotationName: "Middleware",
            targetIdentity: "Controller",
            argument: argument,
            location: mockLocation("C.swift"),
            originModule: testModule
        )
    }

    /// `@Middleware(K)` where `K` is a `BindingKey<AuthGate>` → a dependency on `AuthGate` keyed by `K`.
    @Test func injectsKeyedDependencyForBindingKeyArgument() throws {
        let bindingKey = DiscoveredBindingKey(
            keyReference: "Gates.primary",
            typeArgument: "AuthGate",
            location: mockLocation("K.swift"),
            accessLevel: .internal,
            originModule: testModule
        )
        let injected = injectAdapterDependencies(
            into: [controllerBinding()],
            annotations: [middlewareAnnotation()],
            useSites: [useSite(argument: "Gates.primary")],
            bindingKeys: [bindingKey]
        )
        let dep = try #require(injected.first?.dependencies.first)
        #expect(dep.type == "AuthGate")
        #expect(dep.keyIdentifier == "Gates.primary")
        #expect(dep.name == "_wireGates_primary")
    }

    /// A factory-key argument (neither `.self` nor a known `BindingKey`) is left to factory synthesis —
    /// the dependency pass injects nothing for it.
    @Test func leavesFactoryKeyArgumentToFactorySynthesis() {
        let injected = injectAdapterDependencies(
            into: [controllerBinding()],
            annotations: [middlewareAnnotation()],
            useSites: [useSite(argument: "Keys.session")],
            bindingKeys: []
        )
        #expect(injected.first?.dependencies.isEmpty == true)
    }

    @Test func contributesCapabilityInjectsNoDependency() {
        // A `.contributes(to:)` annotation of the same name shape must NOT inject an input edge.
        let binding = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Controller",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("C.swift"),
                originModule: testModule
            )
        )
        let annotation = DiscoveredAdapterAnnotation(
            annotationName: "Middleware",
            capability: .contributes(key: "SomeKeys.things"),
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
        let useSite = ContributionAliasUseSite(
            annotationName: "Middleware",
            targetIdentity: "Controller",
            argument: "X.self",
            location: mockLocation("C.swift"),
            originModule: testModule
        )
        let injected = injectAdapterDependencies(
            into: [binding],
            annotations: [annotation],
            useSites: [useSite],
            bindingKeys: []
        )
        #expect(injected.first?.dependencies.isEmpty == true)
    }
}
