import Testing

@testable import WireGenCore

/// M5.5 front layer — the keyless contributor proxy (`.liftsPeersToProxy`). WireMVC's `@WireMVCBootstrap`
/// synthesises a proxy that lifts the composition root's global `@Middleware` factories onto itself
/// (reattribution + factory synthesis, exactly as `@Controller` does) but contributes to **no** multibinding
/// — a standalone, directly-addressable binding the front layer reads to fold the global tier. Confirms the
/// key-`nil` path through the existing proxy machinery, so no injection lands on the root binding.
@Suite("Lifts-peers-to-proxy (keyless contributor proxy)")
struct LiftsPeersToProxyTests {
    private func bootstrapAnnotation() -> DiscoveredAdapterAnnotation {
        DiscoveredAdapterAnnotation(
            annotationName: "WireMVCBootstrap",
            capability: .liftsPeersToProxy(proxyTypePrefix: "_WireGlobalMiddleware_", proxyScope: .singleton),
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

    private func bootstrap(_ name: String = "AppBootstrap") -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                genericParameterConstraints: [:],
                dependencies: [],
                location: mockLocation("App.swift"),
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

    /// The keyless proxy is synthesised beside the Bootstrap, holds it (unlabelled), is registered as a
    /// proxy identity — and contributes to nothing (the point of the variant). The Bootstrap stays plain.
    @Test func synthesisesAddressableProxyContributingToNothing() {
        let result = applyContributorProxies(
            to: [.default: [bootstrap()]],
            annotations: [bootstrapAnnotation()],
            useSites: [useSite("WireMVCBootstrap", on: "AppBootstrap")]
        )
        let bindings = result.bindings[.default] ?? []

        let proxy = binding(named: "_WireGlobalMiddleware_AppBootstrap", in: bindings)
        #expect(proxy != nil)
        #expect(proxy?.contributions.isEmpty == true)  // ← keyless: collated into no multibinding
        #expect(proxy?.dependencies.first?.name == nil)  // holds the subject positionally
        #expect(proxy?.dependencies.first?.type == "AppBootstrap")
        #expect(result.proxyIdentities.contains("_WireGlobalMiddleware_AppBootstrap"))

        // The Bootstrap stays a plain, footgun-free binding.
        #expect(binding(named: "AppBootstrap", in: bindings)?.contributions.isEmpty == true)
    }

    /// A global `@Middleware(factoryKey)` reattributes onto the keyless proxy and the synthesised factory
    /// lands on it — exactly like a controller, but with no route-contributor contribution and nothing
    /// injected onto the root binding.
    @Test func liftsGlobalMiddlewareFactoryOntoTheProxyNotTheRoot() {
        let template = DiscoveredFactoryTemplate(
            keyReference: "Keys.factory",
            typeName: "AccessLog",
            qualifiedTypeName: "AccessLog",
            typeKind: "struct",
            genericParameterNames: ["Ctx", "Reader", "Sender"],
            genericParameterConstraints: [:],
            dependencies: [
                DependencyParameter(
                    name: "logger",
                    type: "Logger",
                    kind: .injectProperty,
                    location: mockLocation("M.swift")
                )
            ],
            location: mockLocation("M.swift"),
            originModule: testModule
        )
        let proxied = applyContributorProxies(
            to: [.default: [bootstrap()]],
            annotations: [bootstrapAnnotation(), middlewareAnnotation()],
            useSites: [
                useSite("WireMVCBootstrap", on: "AppBootstrap"),
                useSite("Middleware", argument: "Keys.factory", on: "AppBootstrap"),
            ]
        )
        // The `@Middleware(key)` demand reattributed onto the proxy.
        #expect(
            proxied.useSites.first { $0.annotationName == "Middleware" }?.targetIdentity
                == "_WireGlobalMiddleware_AppBootstrap"
        )

        let synthesis = applyFactorySynthesis(
            to: proxied.bindings,
            templates: [template],
            annotations: [middlewareAnnotation()],
            useSites: proxied.useSites,
            consumerModule: testModule
        )
        let bindings = synthesis.bindings[.default] ?? []

        // The factory edge landed on the proxy (alongside the unlabelled subject), the proxy still contributes
        // to nothing, and nothing was injected onto the root binding.
        let proxy = binding(named: "_WireGlobalMiddleware_AppBootstrap", in: bindings)
        #expect(proxy?.dependencies.contains { $0.type == "_WireFactory_Keys_factory" } == true)
        #expect(proxy?.dependencies.contains { $0.type == "AppBootstrap" } == true)
        #expect(proxy?.contributions.isEmpty == true)
        #expect(
            binding(named: "AppBootstrap", in: bindings)?.dependencies.contains { $0.type.contains("_WireFactory") }
                == false
        )
    }
}
