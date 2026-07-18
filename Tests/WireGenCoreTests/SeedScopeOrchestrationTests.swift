import Testing

@testable import WireGenCore

@Suite("SeedScopeOrchestration")
struct SeedScopeOrchestrationTests {
    // MARK: - Helpers

    private func scopedSingleton(
        _ name: String,
        seed: String,
        dependencies: [(name: String?, type: String)] = []
    ) -> DiscoveredBinding {
        let deps = dependencies.map {
            DependencyParameter(
                name: $0.name,
                type: $0.type,
                kind: .injectInitParameter,
                location: mockLocation("\(name).swift")
            )
        }
        return .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: deps,
                location: mockLocation("\(name).swift"),
                scopeKey: ScopeKey(seed: seed),
                originModule: testModule
            )
        )
    }

    private func singletonProvider(_ name: String, type: String) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: type,
                accessPath: name,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(name).swift"),
                originModule: testModule
            )
        )
    }

    // MARK: - Scope-entry linking (bridging contributor proxies)

    @Test func bridgeProxyResolvesAndSortsAfterItsBorrowedSingleton() throws {
        // A `@Scoped(seed: RequestSeed)` controller injecting an app singleton (`TodoRepository`), and
        // its `.singleton` bridge proxy. Through the real graph: (1) the proxy's `_wireEnterScope` thunk
        // dependency must NOT read as a missing binding (it has no producer — it's synthesised inline),
        // and (2) the scope-entry linking must give the proxy a `.scopeCapture` edge so it sorts *after*
        // `TodoRepository`, whose local the thunk captures.
        let repository = DiscoveredScopeBoundType(
            typeName: "TodoRepository",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [],
            location: mockLocation("Repo.swift"),
            originModule: testModule
        )
        let subject = DiscoveredScopeBoundType(
            typeName: "SessionController",
            typeKind: "struct",
            genericParameterNames: [],
            dependencies: [
                DependencyParameter(
                    name: "seed",
                    type: "RequestSeed",
                    kind: .injectInitParameter,
                    location: mockLocation("S.swift")
                ),
                DependencyParameter(
                    name: "repository",
                    type: "TodoRepository",
                    kind: .injectInitParameter,
                    location: mockLocation("S.swift")
                ),
            ],
            location: mockLocation("S.swift"),
            scopeKey: ScopeKey(seed: "RequestSeed"),
            originModule: testModule
        )
        let proxy = contributorProxyBinding(
            for: subject,
            key: "WireMVCKeys.routeContributors",
            prefix: "_WireRouteContributor_",
            proxyScope: .singleton
        )
        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "RequestSeed"),
            scopeBindings: [.scopeBound(subject)],
            borrowBindings: syntheticSingletonBorrowBindings(from: [.scopeBound(repository)]),
            typealiases: [],
            module: testModule
        )

        let linked = linkingScopeEntryCaptures(
            into: [.scopeBound(repository), .scopeBound(proxy)],
            orchestrations: [orchestration]
        )

        // The proxy gained a `.scopeCapture` dependency on `TodoRepository`.
        let linkedProxy = try #require(
            linked.compactMap { binding -> DiscoveredScopeBoundType? in
                guard case .scopeBound(let type) = binding, type.typeName.hasPrefix("_WireRouteContributor_") else {
                    return nil
                }
                return type
            }.first
        )
        let captures = linkedProxy.dependencies.filter { $0.kind == .scopeCapture }
        #expect(captures.map(\.type) == ["TodoRepository"])

        // The real graph resolves cleanly (the thunk dep is not "missing") and orders the proxy after
        // the singleton it captures.
        let graph = buildDependencyGraph(from: linked, typealiases: [])
        let order = try #require(graph.outcome.topologicalOrder)
        let names = order.map(\.boundType)
        let repositoryIndex = try #require(names.firstIndex(of: "TodoRepository"))
        let proxyIndex = try #require(names.firstIndex(where: { $0.hasPrefix("_WireRouteContributor_") }))
        #expect(repositoryIndex < proxyIndex)
    }

    // MARK: - Validation

    @Test func scopeBindingDependingOnSeedOnlyValidates() throws {
        // The synthetic seed binding satisfies a scope binding that
        // `@Inject`s the seed. No singletons needed; the orchestration
        // succeeds with a topological order that includes the seed.
        let scope = scopedSingleton(
            "RequestLogger",
            seed: "HBRequestSeed",
            dependencies: [(name: "seed", type: "HBRequestSeed")]
        )
        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "HBRequestSeed"),
            scopeBindings: [scope],
            borrowBindings: [],
            typealiases: [],
            module: testModule
        )
        let order = try #require(orchestration.result.outcome.topologicalOrder)
        // Order: seed first (no deps), then RequestLogger (depends on seed).
        #expect(order.count == 2)
        #expect(order[0].boundType == "HBRequestSeed")
        #expect(order[1].boundType == "RequestLogger")
    }

    @Test func scopeBindingBorrowingSingletonValidates() throws {
        // Scope binding `@Inject`s a singleton (`Logger`). The
        // orchestrator generates a synthetic borrow binding for the
        // logger so dep resolution succeeds; the borrow's property
        // name lands in `borrowedBindingPropertyNames`.
        let scope = scopedSingleton(
            "RequestLogger",
            seed: "HBRequestSeed",
            dependencies: [(name: "base", type: "Logger")]
        )
        let singleton = singletonProvider("logger", type: "Logger")
        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "HBRequestSeed"),
            scopeBindings: [scope],
            borrowBindings: syntheticSingletonBorrowBindings(from: [singleton]),
            typealiases: [],
            module: testModule
        )
        let order = try #require(orchestration.result.outcome.topologicalOrder)
        // Order: Logger borrow + seed (both no deps), then RequestLogger.
        #expect(order.count == 3)
        #expect(orchestration.borrowedBindingPropertyNames == ["logger"])
        #expect(order.last?.boundType == "RequestLogger")
    }

    @Test func scopeBindingMissingDependencyFails() throws {
        // A scope binding depending on something that's neither in
        // the scope, the seed, nor the default singletons surfaces
        // as a missing-binding validation error — the standard
        // `buildDependencyGraph` diagnostic path; the orchestrator
        // doesn't add any custom error type.
        let scope = scopedSingleton(
            "RequestLogger",
            seed: "HBRequestSeed",
            dependencies: [(name: "unknown", type: "MissingService")]
        )
        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "HBRequestSeed"),
            scopeBindings: [scope],
            borrowBindings: [],
            typealiases: [],
            module: testModule
        )
        let errors = try #require(orchestration.result.outcome.validationErrors)
        #expect(!errors.missingBindings.isEmpty)
    }

    @Test func identifierSuffixSanitisesGenericSeedExpressions() {
        // The struct/function naming uses `sanitizeIdentifier` so a
        // generic seed type (`TenantSeed<String>`) produces a valid
        // Swift identifier (`TenantSeedOfString`) in the generated
        // names.
        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "TenantSeed<String>"),
            scopeBindings: [],
            borrowBindings: [],
            typealiases: [],
            module: testModule
        )
        #expect(orchestration.identifierSuffix == "TenantSeedOfString")
        #expect(orchestration.seedTypeExpression == "TenantSeed<String>")
    }

    @Test func containerScopeOrchestrationCarriesContainerSpecificParentGraphType() throws {
        // A seeded scope inside a `@Container` borrows from the
        // container's singletons (typed `_<Container>WireGraph`),
        // not the default `_WireGraph`. The orchestration's
        // identifier suffix composes as `<Container>_<Seed>` so the
        // emitted struct/function names don't clash with default-
        // graph scopes of the same seed type; the parent-graph
        // type flows through to emission so the bootstrap signature
        // and borrow access paths point at the container's graph.
        let scope = scopedSingleton(
            "RequestLogger",
            seed: "HBRequestSeed",
            dependencies: [(name: "base", type: "Logger")]
        )
        let singleton = singletonProvider("logger", type: "Logger")
        let containerGraphType = "_TestContainerWireGraph"
        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "HBRequestSeed"),
            containerName: "TestContainer",
            scopeBindings: [scope],
            borrowBindings: syntheticSingletonBorrowBindings(
                from: [singleton],
                inWireGraphOfType: containerGraphType
            ),
            parentGraphType: containerGraphType,
            typealiases: [],
            module: testModule
        )
        #expect(orchestration.identifierSuffix == "TestContainer_HBRequestSeed")
        #expect(orchestration.parentGraphType == containerGraphType)
        #expect(orchestration.borrowedBindingPropertyNames == ["logger"])
        let order = try #require(orchestration.result.outcome.topologicalOrder)
        let borrow = order.first { $0.boundType == "Logger" }
        if case .provider(let provider) = borrow {
            // Borrow access path uses the parent-graph parameter's
            // internal name — `_TestContainerWireGraph` becomes the
            // external label `testContainerWireGraph` with the
            // collision-safe leading underscore restored for the
            // internal name (`_testContainerWireGraph`).
            #expect(provider.accessPath == "_testContainerWireGraph.logger")
        } else {
            Issue.record("expected synthetic borrow provider in topological order")
        }
    }

    @Test func withResultReturnsCopyCarryingOtherFields() throws {
        // `withResult` is used by the cross-scope-hint enrichment to
        // round-trip an orchestration with an updated GraphResult
        // while preserving the rest of the descriptor. Verify the
        // copy carries seedTypeExpression, identifierSuffix,
        // parentGraphType, and borrowedBindingPropertyNames
        // unchanged, and the new result replaces the old.
        let original = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "HBRequestSeed"),
            containerName: "TestContainer",
            scopeBindings: [],
            borrowBindings: [],
            parentGraphType: "_TestContainerWireGraph",
            typealiases: [],
            module: testModule
        )
        // Replace the result with one that has a different
        // topological order so we can assert the new value is what's
        // exposed.
        let first = singletonProvider("first", type: "First")
        let second = singletonProvider("second", type: "Second")
        let newResult = buildDependencyGraph(from: [first, second], typealiases: [])
        let updated = original.withResult(newResult)
        #expect(updated.seedTypeExpression == original.seedTypeExpression)
        #expect(updated.identifierSuffix == original.identifierSuffix)
        #expect(updated.parentGraphType == original.parentGraphType)
        #expect(updated.borrowedBindingPropertyNames == original.borrowedBindingPropertyNames)
        let updatedOrder = try #require(updated.result.outcome.topologicalOrder)
        // The new result has two bindings — distinct from the
        // original's single synthetic seed entry, proving the result
        // field is the only thing replaced.
        #expect(updatedOrder.count == 2)
        #expect(updatedOrder.contains { $0.boundType == "First" })
        #expect(updatedOrder.contains { $0.boundType == "Second" })
    }

    @Test func unreferencedSingletonsStillAppearInTopologicalOrderButAreBorrowed() throws {
        // Every default-graph singleton becomes a synthetic borrow,
        // whether or not any scope binding actually `@Inject`s it. The
        // topological order includes all borrows; emission uses
        // `borrowedBindingPropertyNames` to filter them out of the
        // scope struct's stored properties.
        let scope = scopedSingleton("RequestLogger", seed: "HBRequestSeed")
        let unused = singletonProvider("httpClient", type: "HTTPClient")
        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "HBRequestSeed"),
            scopeBindings: [scope],
            borrowBindings: syntheticSingletonBorrowBindings(from: [unused]),
            typealiases: [],
            module: testModule
        )
        let order = try #require(orchestration.result.outcome.topologicalOrder)
        #expect(order.contains { $0.boundType == "HTTPClient" })
        // Property name follows the same `lowerCamelCased(sanitised)`
        // rule the rest of emission uses — only the first character
        // is lowercased, so `HTTPClient` yields `hTTPClient`.
        #expect(orchestration.borrowedBindingPropertyNames == ["hTTPClient"])
    }
}
