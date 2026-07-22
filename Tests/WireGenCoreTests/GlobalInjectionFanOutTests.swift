import Testing

@testable import WireGenCore

/// M5.5 Phase 5 — global-injection fan-out. `.injectsPeerFromGraphIntoAll` on a composition root
/// (WireMVC's `@WireMVCBootstrap`) reinterprets its co-located peer `@Middleware`: the peer's argument is
/// injected onto every proxy collating into the key, not onto the root's own binding. The fixtures are
/// WireMVC-flavoured (`Controller` / `Middleware` / `WireMVCBootstrap`); the pass itself is domain-free.
@Suite("Global-injection fan-out")
struct GlobalInjectionFanOutTests {
    private let key = "WireMVCKeys.routeContributors"

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

    private func bootstrapAnnotation() -> DiscoveredAdapterAnnotation {
        DiscoveredAdapterAnnotation(
            annotationName: "WireMVCBootstrap",
            capability: .injectsPeerFromGraphIntoAll(peer: "Middleware", collatingInto: "WireMVCKeys.routeContributors"),
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
    }

    private func struct_(_ name: String, file: String) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                genericParameterConstraints: [:],
                dependencies: [],
                location: mockLocation(file),
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
            location: mockLocation("U.swift"),
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

    /// End-to-end: proxies → fan-out → adapter dependencies. A global `@Middleware(AccessLog.self)` on the
    /// `@WireMVCBootstrap` root lands `_wireAccessLog` on every route-contributor proxy (alongside a
    /// controller's own `@Middleware`), and on neither the root nor an unrelated binding.
    @Test func liftsGlobalMiddlewareOntoEveryProxyAndNotTheRoot() {
        let annotations = [controllerAnnotation(), middlewareAnnotation(), bootstrapAnnotation()]
        let proxied = applyContributorProxies(
            to: [
                .default: [
                    struct_("TodosController", file: "Todos.swift"),
                    struct_("HealthController", file: "Health.swift"),
                    struct_("AppBootstrap", file: "App.swift"),
                    struct_("Unrelated", file: "Unrelated.swift"),
                ]
            ],
            annotations: annotations,
            useSites: [
                useSite("Controller", on: "TodosController"),
                useSite("Controller", on: "HealthController"),
                useSite("WireMVCBootstrap", on: "AppBootstrap"),
                useSite("Middleware", argument: "AccessLog.self", on: "AppBootstrap"),  // global tier
                useSite("Middleware", argument: "Own.self", on: "TodosController"),  // a controller's own
            ]
        )

        let fanned = applyGlobalInjectionFanOut(
            to: proxied.bindings,
            annotations: annotations,
            useSites: proxied.useSites,
            proxyIdentities: proxied.proxyIdentities
        )

        // The root's global @Middleware use-site is gone; it is re-emitted once per collating proxy.
        #expect(!fanned.contains { $0.annotationName == "Middleware" && $0.targetIdentity == "AppBootstrap" })
        let accessLogTargets = Set(
            fanned.filter { $0.annotationName == "Middleware" && $0.argument == "AccessLog.self" }.map(\.targetIdentity)
        )
        #expect(
            accessLogTargets == ["_WireRouteContributor_TodosController", "_WireRouteContributor_HealthController"]
        )

        let withDeps = applyAdapterDependencies(
            to: proxied.bindings,
            annotations: annotations,
            useSites: fanned,
            bindingKeys: []
        )
        let bindings = withDeps[.default] ?? []

        // Every route-contributor proxy folds the global middleware...
        for proxy in ["_WireRouteContributor_TodosController", "_WireRouteContributor_HealthController"] {
            #expect(binding(named: proxy, in: bindings)?.dependencies.contains { $0.type == "AccessLog" } == true)
        }
        // ...the controller's own middleware coexists on its proxy...
        #expect(
            binding(named: "_WireRouteContributor_TodosController", in: bindings)?
                .dependencies.contains { $0.type == "Own" } == true
        )
        // ...and neither the root nor an unrelated binding gains the field (the root site was removed; the
        // fan-out is gated to synthesised proxies collating into the key).
        #expect(binding(named: "AppBootstrap", in: bindings)?.dependencies.contains { $0.type == "AccessLog" } == false)
        #expect(binding(named: "Unrelated", in: bindings)?.dependencies.contains { $0.type == "AccessLog" } == false)
    }

    /// No reinterpreting directive present → the use-site list is returned untouched (the pass no-ops, so
    /// a package with no `@WireMVCBootstrap` pays nothing).
    @Test func noDirectiveLeavesUseSitesUntouched() {
        let annotations = [controllerAnnotation(), middlewareAnnotation()]
        let proxied = applyContributorProxies(
            to: [.default: [struct_("TodosController", file: "Todos.swift")]],
            annotations: annotations,
            useSites: [
                useSite("Controller", on: "TodosController"),
                useSite("Middleware", argument: "Own.self", on: "TodosController"),
            ]
        )
        let fanned = applyGlobalInjectionFanOut(
            to: proxied.bindings,
            annotations: annotations,
            useSites: proxied.useSites,
            proxyIdentities: proxied.proxyIdentities
        )
        #expect(fanned == proxied.useSites)
    }
}
