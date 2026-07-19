import Testing

@testable import WireGenCore

/// Increment 3.1c — contributor-proxy synthesis. `.contributesProxy` synthesises a proxy binding beside
/// the annotated binding (depending on it, contributing in its place) and re-attributes the binding's
/// factory use-sites onto the proxy, so the factory-synthesis pass lands the factory edge on the proxy —
/// the type it is lifted onto — leaving the subject a plain binding. The fixtures are WireMVC-flavoured
/// (`Controller` / `Middleware`) as concrete examples; the pass itself is domain-free.
@Suite("Contributor-proxy synthesis")
struct ContributorProxySynthesisTests {
    private let key = "WireMVCKeys.routeContributors"
    private let prefix = "_WireRouteContributor_"

    private func controllerAnnotation() -> DiscoveredAdapterAnnotation {
        DiscoveredAdapterAnnotation(
            annotationName: "Controller",
            capability: .contributesProxy(
                key: "WireMVCKeys.routeContributors",
                proxyTypePrefix: "_WireRouteContributor_",
                proxyScope: .singleton
            ),
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
    }

    private func middlewareAnnotation() -> DiscoveredAdapterAnnotation {
        DiscoveredAdapterAnnotation(
            annotationName: "Middleware",
            capability: .injectsFromGraph,
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
    }

    private func controller(
        _ name: String = "TodosController",
        params: [String] = ["Repository"],
        constraints: [String: String] = ["Repository": "TodoRepository"]
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: params,
                genericParameterConstraints: constraints,
                dependencies: [
                    DependencyParameter(
                        name: "repository",
                        type: "Repository",
                        kind: .injectInitParameter,
                        location: mockLocation("C.swift")
                    )
                ],
                location: mockLocation("C.swift"),
                accessLevel: .public,
                originModule: testModule
            )
        )
    }

    /// A `@Scoped(seed:)` controller — the bridge case. Same shape as `controller`, but seeded
    /// (`scopeKey` non-nil), so a `.singleton` proxy over it must bridge rather than hold.
    private func scopedController(
        _ name: String = "SessionController",
        seed: String = "RequestSeed",
        params: [String] = ["Repository"],
        constraints: [String: String] = ["Repository": "TodoRepository"]
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: params,
                genericParameterConstraints: constraints,
                dependencies: [
                    DependencyParameter(
                        name: "repository",
                        type: "Repository",
                        kind: .injectInitParameter,
                        location: mockLocation("C.swift")
                    )
                ],
                location: mockLocation("C.swift"),
                scopeKey: ScopeKey(seed: seed),
                accessLevel: .public,
                originModule: testModule
            )
        )
    }

    private func useSite(_ annotation: String, argument: String? = nil, on target: String) -> ContributionAliasUseSite {
        ContributionAliasUseSite(
            annotationName: annotation,
            targetIdentity: target,
            argument: argument,
            location: mockLocation("C.swift"),
            originModule: testModule
        )
    }

    private func scopeBound(_ binding: DiscoveredBinding) -> DiscoveredScopeBoundType? {
        guard case .scopeBound(let type) = binding else { return nil }
        return type
    }

    private func binding(named name: String, in bindings: [DiscoveredBinding]) -> DiscoveredScopeBoundType? {
        bindings.compactMap(scopeBound).first { $0.typeName == name }
    }

    // MARK: - Proxy synthesis

    @Test func synthesisesGenericProxyBesideController() {
        let result = applyContributorProxies(
            to: [.default: [controller()]],
            annotations: [controllerAnnotation()],
            useSites: [useSite("Controller", on: "TodosController")]
        )
        let bindings = result.bindings[.default] ?? []
        #expect(bindings.count == 2)

        let proxy = binding(named: "_WireRouteContributor_TodosController", in: bindings)
        #expect(proxy != nil)
        // Generic exactly as the subject, depending on TodosController<Repository> (threads transitively).
        #expect(proxy?.genericParameterNames == ["Repository"])
        #expect(proxy?.genericParameterConstraints == ["Repository": "TodoRepository"])
        // The subject is the proxy's first, unlabelled dependency (Wire names no member of the proxy).
        #expect(proxy?.dependencies.first?.name == nil)
        #expect(proxy?.dependencies.first?.type == "TodosController<Repository>")
        #expect(proxy?.contributions.first?.keyReference == key)
        #expect(proxy?.accessLevel == .public)

        // The controller stays plain — no contribution.
        let plainController = binding(named: "TodosController", in: bindings)
        #expect(plainController?.contributions.isEmpty == true)
    }

    @Test func bridgesSeededControllerViaScopeEntryThunk() {
        // A `.singleton` proxy over a `@Scoped(seed:)` subject bridges: instead of holding the seeded
        // subject (which would be a cross-scope violation), the app-scoped proxy takes a labelled
        // scope-entry thunk `(Seed) async throws -> Subject`. The subject lives in its seeded partition;
        // the proxy must land in the app (`.default`) partition — where the app graph collates it.
        let seedPartition = Partition(scope: ScopeKey(seed: "RequestSeed"))
        let result = applyContributorProxies(
            to: [seedPartition: [scopedController()]],
            annotations: [controllerAnnotation()],
            useSites: [useSite("Controller", on: "SessionController")]
        )
        let proxy = binding(named: "_WireRouteContributor_SessionController", in: result.bindings[.default] ?? [])
        #expect(proxy != nil)
        // ...and not in the subject's seeded partition.
        #expect(binding(named: "_WireRouteContributor_SessionController", in: result.bindings[seedPartition] ?? []) == nil)
        // The proxy is app-scoped (singleton), not seeded — it collates into the app graph.
        #expect(proxy?.scopeKey == nil)
        // Generic exactly as the subject, so the injected backend threads into the thunk's return type.
        #expect(proxy?.genericParameterNames == ["Repository"])
        // Primary dependency is the labelled scope-entry thunk, not the positional subject.
        let primary = proxy?.dependencies.first
        #expect(primary?.name == "_wireEnterScope")
        #expect(primary?.type == "@Sendable (RequestSeed) async throws -> SessionController<Repository>")
        #expect(proxy?.contributions.first?.keyReference == key)

        // The controller stays a plain seeded binding in its seeded partition — no contribution of its own.
        let plainController = binding(named: "SessionController", in: result.bindings[seedPartition] ?? [])
        #expect(plainController?.contributions.isEmpty == true)
        #expect(plainController?.scopeKey?.seed == "RequestSeed")
    }

    @Test func synthesisesNonGenericProxy() {
        let result = applyContributorProxies(
            to: [.default: [controller("HealthController", params: [], constraints: [:])]],
            annotations: [controllerAnnotation()],
            useSites: [useSite("Controller", on: "HealthController")]
        )
        let proxy = binding(named: "_WireRouteContributor_HealthController", in: result.bindings[.default] ?? [])
        #expect(proxy?.genericParameterNames.isEmpty == true)
        #expect(proxy?.dependencies.first?.type == "HealthController")
    }

    @Test func reattributesFactoryUseSitesToProxy() {
        let result = applyContributorProxies(
            to: [.default: [controller()]],
            annotations: [controllerAnnotation(), middlewareAnnotation()],
            useSites: [
                useSite("Controller", on: "TodosController"),
                useSite("Middleware", argument: "Keys.factory", on: "TodosController"),
            ]
        )
        // The `@Middleware(key)` demand now targets the proxy; the `@Controller` site is left inert.
        let middlewareSite = result.useSites.first { $0.annotationName == "Middleware" }
        #expect(middlewareSite?.targetIdentity == "_WireRouteContributor_TodosController")
    }

    @Test func noProxyAnnotationsLeavesEverythingUnchanged() {
        let input: [Partition: [DiscoveredBinding]] = [.default: [controller()]]
        let result = applyContributorProxies(
            to: input,
            annotations: [middlewareAnnotation()],
            useSites: [useSite("Middleware", argument: "Keys.factory", on: "TodosController")]
        )
        #expect(result.bindings[.default]?.count == 1)
        #expect(result.useSites.first?.targetIdentity == "TodosController")
    }

    // MARK: - Combined with factory synthesis

    @Test func factorySynthesisLandsFactoryEdgeOnProxyNotController() {
        let template = DiscoveredFactoryTemplate(
            keyReference: "Keys.factory",
            typeName: "RequireAPIKey",
            qualifiedTypeName: "RequireAPIKey",
            typeKind: "struct",
            genericParameterNames: ["Ctx", "Reader", "Sender"],
            genericParameterConstraints: [:],
            dependencies: [
                DependencyParameter(
                    name: "keys",
                    type: "APIKeyStore",
                    kind: .injectProperty,
                    location: mockLocation("M.swift")
                )
            ],
            location: mockLocation("M.swift"),
            originModule: testModule
        )
        let proxied = applyContributorProxies(
            to: [.default: [controller()]],
            annotations: [controllerAnnotation(), middlewareAnnotation()],
            useSites: [
                useSite("Controller", on: "TodosController"),
                useSite("Middleware", argument: "Keys.factory", on: "TodosController"),
            ]
        )
        let synthesis = applyFactorySynthesis(
            to: proxied.bindings,
            templates: [template],
            annotations: [middlewareAnnotation()],
            useSites: proxied.useSites,
            consumerModule: testModule
        )
        let bindings = synthesis.bindings[.default] ?? []

        // The factory edge is on the proxy, alongside the (unlabelled) subject dependency...
        let proxy = binding(named: "_WireRouteContributor_TodosController", in: bindings)
        #expect(proxy?.dependencies.contains { $0.type == "_WireFactory_Keys_factory" } == true)
        #expect(proxy?.dependencies.contains { $0.type == "TodosController<Repository>" } == true)
        // ...and NOT on the plain subject.
        let plainSubject = binding(named: "TodosController", in: bindings)
        #expect(plainSubject?.dependencies.contains { $0.type == "_WireFactory_Keys_factory" } == false)
    }
}
