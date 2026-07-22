import Testing

@testable import WireGenCore

/// M5.5 front layer — peer suppression. `.suppressesPeers([...])` on a declaration (WireMVC's
/// `@WireMVCBootstrap`) drops the listed peer annotations' use-sites on that declaration before the
/// input-edge passes run, so a global `@Middleware` on the root is not injected as a dependency of the
/// root binding — the adapter's route generator reads it instead. Fixtures are WireMVC-flavoured; the pass
/// is domain-free.
@Suite("Peer suppression")
struct PeerSuppressionTests {
    private func bootstrapAnnotation() -> DiscoveredAdapterAnnotation {
        DiscoveredAdapterAnnotation(
            annotationName: "WireMVCBootstrap",
            capability: .suppressesPeers(peers: ["Middleware"]),
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

    private func useSite(_ annotation: String, argument: String? = nil, on target: String) -> ContributionAliasUseSite {
        ContributionAliasUseSite(
            annotationName: annotation,
            targetIdentity: target,
            argument: argument,
            location: mockLocation("U.swift"),
            originModule: testModule
        )
    }

    /// The suppressed peer on the suppressing declaration is dropped; the same peer on another declaration
    /// survives (no suppressor there), and the suppressor's own use-site passes through.
    @Test func dropsSuppressedPeerOnlyOnSuppressingDecl() {
        let annotations = [bootstrapAnnotation(), middlewareAnnotation()]
        let useSites = [
            useSite("WireMVCBootstrap", on: "AppBootstrap"),
            useSite("Middleware", argument: "AccessLog.self", on: "AppBootstrap"),  // suppressed
            useSite("Middleware", argument: "Own.self", on: "TodosController"),  // survives
        ]
        let filtered = applyPeerSuppression(annotations: annotations, useSites: useSites)

        #expect(!filtered.contains { $0.annotationName == "Middleware" && $0.targetIdentity == "AppBootstrap" })
        #expect(filtered.contains { $0.annotationName == "Middleware" && $0.targetIdentity == "TodosController" })
        #expect(filtered.contains { $0.annotationName == "WireMVCBootstrap" && $0.targetIdentity == "AppBootstrap" })
    }

    /// No suppressor present → the use-site list is returned untouched.
    @Test func noSuppressorLeavesUseSitesUntouched() {
        let annotations = [middlewareAnnotation()]
        let useSites = [useSite("Middleware", argument: "Own.self", on: "TodosController")]
        #expect(applyPeerSuppression(annotations: annotations, useSites: useSites) == useSites)
    }
}
