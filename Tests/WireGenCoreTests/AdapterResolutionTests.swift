import Testing

@testable import WireGenCore

/// Iteration 8c/8d: adapter resolution + validation. These pin that a use-site
/// is classified against the discovered definitions, its register signature is
/// substituted and validated against the producer set (reusing `matchProducer`),
/// and that missing bindings / duplicate definitions surface as errors anchored
/// at the right place.
@Suite("Adapter resolution")
struct AdapterResolutionTests {
    private func definition(_ name: String, signature: String) -> DiscoveredAdapterAnnotation {
        DiscoveredAdapterAnnotation(
            annotationName: name,
            form: .typeLevel,
            phase: .postGraph,
            registerSignature: signature,
            location: mockLocation("\(name)Def.swift"),
            originModule: testModule
        )
    }

    private func useSite(
        _ name: String,
        on type: String,
        typeArguments: [String] = []
    ) -> AdapterUseSite {
        AdapterUseSite(
            annotationName: name,
            annotatedTypeName: type,
            annotatedQualifiedTypeName: type,
            typeArguments: typeArguments,
            location: mockLocation("\(type).swift"),
            originModule: testModule
        )
    }

    private func producer(_ boundType: String, key: String? = nil) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: boundType,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(boundType).swift"),
                keyIdentifier: key,
                accessLevel: .internal,
                originModule: testModule
            )
        )
    }

    /// A lifted `@Singleton(as: opaqueIdentity.self)` producer — concrete type
    /// `concreteType`, but keyed in the graph as `some opaqueIdentity`.
    private func liftedProducer(_ concreteType: String, opaqueIdentity: String) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: concreteType,
                typeKind: "struct",
                genericParameterNames: [],
                explicitIdentity: opaqueIdentity,
                dependencies: [],
                location: mockLocation("\(concreteType).swift"),
                originModule: testModule
            )
        )
    }

    @Test func resolvesInstanceAndTypeArgument() throws {
        let result = resolveAdapterRegistrations(
            useSites: [useSite("RoutedBy", on: "SimpleController", typeArguments: ["Router<BasicRequestContext>"])],
            definitions: [definition("RoutedBy", signature: "(instance: Self, router: $0)")],
            producers: [producer("SimpleController"), producer("Router<BasicRequestContext>")]
        )
        #expect(result.diagnostics.isEmpty)
        let registration = try #require(result.registrations.first)
        #expect(result.registrations.count == 1)
        #expect(registration.calleeType == "SimpleController")
        #expect(registration.phase == .postGraph)
        #expect(
            registration.arguments == [
                .init(label: "instance", localName: identifierName(forType: "SimpleController", key: nil)),
                .init(label: "router", localName: identifierName(forType: "Router<BasicRequestContext>", key: nil)),
            ]
        )
    }

    @Test func resolvesInstanceForLiftedOpaqueNode() throws {
        // `@RoutedBy` on a lifted `@Singleton(as: APIProtocol.self)` node. Its
        // concrete type is `TaskController` but its graph identity is
        // `some APIProtocol`; `instance: Self` must resolve to that identity so
        // the registration references the lifted local (`someAPIProtocol`), not
        // a nonexistent `taskController`. The callee stays the concrete type.
        let result = resolveAdapterRegistrations(
            useSites: [useSite("RoutedBy", on: "TaskController", typeArguments: ["Router"])],
            definitions: [definition("RoutedBy", signature: "(instance: Self, router: $0)")],
            producers: [
                liftedProducer("TaskController", opaqueIdentity: "APIProtocol"),
                producer("Router"),
            ]
        )
        #expect(result.diagnostics.isEmpty)
        let registration = try #require(result.registrations.first)
        #expect(registration.calleeType == "TaskController")
        #expect(
            registration.arguments == [
                .init(label: "instance", localName: identifierName(forType: "some APIProtocol", key: nil)),
                .init(label: "router", localName: identifierName(forType: "Router", key: nil)),
            ]
        )
    }

    @Test func unmatchedUseSiteIsDroppedSilently() {
        // `@Traced` has no adapter definition, so it's left entirely alone —
        // no registration, no diagnostic.
        let result = resolveAdapterRegistrations(
            useSites: [useSite("Traced", on: "SimpleController", typeArguments: ["Category"])],
            definitions: [definition("RoutedBy", signature: "(instance: Self, router: $0)")],
            producers: [producer("SimpleController")]
        )
        #expect(result.registrations.isEmpty)
        #expect(result.diagnostics.isEmpty)
    }

    @Test func missingBindingErrorsAtTheUseSite() throws {
        let site = useSite("RoutedBy", on: "SimpleController", typeArguments: ["Router<X>"])
        let result = resolveAdapterRegistrations(
            useSites: [site],
            definitions: [definition("RoutedBy", signature: "(instance: Self, router: $0)")],
            producers: [producer("SimpleController")]  // no Router<X>
        )
        #expect(result.registrations.isEmpty)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(result.diagnostics.count == 1)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.location == site.location)
        #expect(diagnostic.message.contains("no binding produces 'Router<X>'"))
        #expect(diagnostic.message.contains("@RoutedBy"))
    }

    @Test func typeArgumentIndexOutOfRangeErrors() throws {
        // Signature needs `$0`, but the use-site supplies no type arguments.
        let result = resolveAdapterRegistrations(
            useSites: [useSite("RoutedBy", on: "C", typeArguments: [])],
            definitions: [definition("RoutedBy", signature: "(instance: Self, router: $0)")],
            producers: [producer("C")]
        )
        #expect(result.registrations.isEmpty)
        let diagnostic = try #require(result.diagnostics.first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("$0"))
    }

    @Test func duplicateDefinitionIsAnError() {
        let result = resolveAdapterRegistrations(
            useSites: [useSite("RoutedBy", on: "C", typeArguments: ["R"])],
            definitions: [
                definition("RoutedBy", signature: "(instance: Self, router: $0)"),
                definition("RoutedBy", signature: "(instance: Self)"),
            ],
            producers: [producer("C"), producer("R")]
        )
        // Conflicting name → no single contract → use-site unresolved, errors at
        // each definition.
        #expect(result.registrations.isEmpty)
        #expect(result.diagnostics.count == 2)
        #expect(result.diagnostics.allSatisfy { $0.severity == .error })
        #expect(result.diagnostics.allSatisfy { $0.message.contains("defined more than once") })
    }

    @Test func signatureSplittingIsBracketAware() throws {
        // A literal collection type whose generic argument list contains a comma
        // must not split into two parameters.
        let result = resolveAdapterRegistrations(
            useSites: [useSite("Wired", on: "C")],
            definitions: [definition("Wired", signature: "(instance: Self, map: Dictionary<String, Int>)")],
            producers: [producer("C"), producer("Dictionary<String, Int>")]
        )
        #expect(result.diagnostics.isEmpty)
        let registration = try #require(result.registrations.first)
        #expect(registration.arguments.count == 2)
        #expect(registration.arguments[1].label == "map")
        #expect(registration.arguments[1].localName == identifierName(forType: "Dictionary<String, Int>", key: nil))
    }

    // MARK: - Registration ordering (Step 1)

    private func singleton(_ name: String, dependsOn deps: [String] = []) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: deps.map {
                    DependencyParameter(
                        name: nil,
                        type: $0,
                        kind: .injectInitParameter,
                        location: mockLocation("\(name).swift")
                    )
                },
                location: mockLocation("\(name).swift"),
                originModule: testModule
            )
        )
    }

    @Test func consumerOfAdaptedCollaboratorIsOrderedAfterRegistrationSelf() throws {
        // SimpleController (@RoutedBy Router) registers with Router; Application
        // consumes Router. The registration is an ordering edge, so Application
        // must be ordered *after* SimpleController — otherwise codegen would emit
        // `SimpleController._wireRegister(…, router:)` after Application was built
        // from an un-registered router.
        let bindings = [
            singleton("SimpleController"),
            producer("Router"),
            singleton("Application", dependsOn: ["Router"]),
        ]
        let useSites = [useSite("RoutedBy", on: "SimpleController", typeArguments: ["Router"])]
        let defs = [definition("RoutedBy", signature: "(instance: Self, router: $0)")]

        // Control: without the adapter, Application (alphabetically first, only
        // depends on Router) is ordered *before* SimpleController.
        let control = buildDependencyGraph(from: bindings)
        let controlNames = try #require(control.outcome.topologicalOrder).map { $0.boundType }
        #expect(controlNames.firstIndex(of: "Application")! < controlNames.firstIndex(of: "SimpleController")!)

        // With the adapter, the ordering edge flips it: SimpleController before Application.
        let result = buildDependencyGraph(
            from: bindings,
            adapterUseSites: useSites,
            adapterDefinitions: defs
        )
        let names = try #require(result.outcome.topologicalOrder).map { $0.boundType }
        #expect(names.firstIndex(of: "SimpleController")! < names.firstIndex(of: "Application")!)
    }
}
