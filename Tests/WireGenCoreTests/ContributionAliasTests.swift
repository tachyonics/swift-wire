import Testing

@testable import WireGenCore

/// M2.3: contribution aliases — the `.contributes(to:)` capability of
/// `WireAdapterAnnotationV1`. An adapter declares `WireAdapterAnnotationV1(annotation: "X",
/// capability: .contributes(to: key))`, so `@X` on a binding aliases `@Contributes(to: key)`.
/// These pin the three moving parts: discovery of the capability, name-agnostic use-site
/// capture, and the post-aggregation injection of a synthetic contribution.
@Suite("Contribution alias")
struct ContributionAliasTests {
    @Test func discoversContributesToForm() throws {
        let source = """
            enum HummingbirdAdapter {
                static let route = WireAdapterAnnotationV1(
                    annotation: "HummingbirdRoute", capability: .contributes(to: HummingbirdKeys.routes))
            }
            """
        let annotation = try #require(
            discover(in: source, sourcePath: "Adapter.swift", module: testModule).adapterAnnotations.first
        )
        #expect(annotation.annotationName == "HummingbirdRoute")
        #expect(annotation.capability == .contributes(key: "HummingbirdKeys.routes"))
    }

    @Test func capturesAliasUseSitesNameAgnostically() {
        let source = """
            @Singleton
            @HummingbirdRoute("todos")
            struct TodoController {}
            """
        let sites = discover(in: source, sourcePath: "C.swift", module: testModule).aliasUseSites
        #expect(sites.contains { $0.annotationName == "HummingbirdRoute" && $0.targetIdentity == "TodoController" })
    }

    @Test func capturesAliasUseSitesOnProviderFunctions() {
        // The alias attribute sits on a `@Provides func`, not a type — captured keyed by the
        // provider's access path so it resolves onto the provider binding, not just types.
        let source = """
            @Provides
            @HummingbirdRoute
            func makeController() -> TodoController { TodoController() }
            """
        let sites = discover(in: source, sourcePath: "C.swift", module: testModule).aliasUseSites
        #expect(sites.contains { $0.annotationName == "HummingbirdRoute" && $0.targetIdentity == "makeController" })
    }

    @Test func injectsContributionForAliasedBinding() throws {
        let binding = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "TodoController",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("C.swift"),
                originModule: testModule
            )
        )
        let alias = DiscoveredAdapterAnnotation(
            annotationName: "HummingbirdRoute",
            capability: .contributes(key: "HummingbirdKeys.routes"),
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
        let useSite = ContributionAliasUseSite(
            annotationName: "HummingbirdRoute",
            targetIdentity: "TodoController",
            location: mockLocation("C.swift"),
            originModule: testModule
        )

        let injected = injectAliasContributions(into: [binding], aliases: [alias], useSites: [useSite])
        let contributions = try #require(injected.first?.contributions)
        #expect(contributions.contains { $0.keyReference == "HummingbirdKeys.routes" })
    }

    @Test func injectsContributionForAliasedProvider() throws {
        // A `@Provides` provider (not a type) carrying an alias attribute, matched by its access path.
        let binding = DiscoveredBinding.provider(
            DiscoveredProvider(
                boundType: "ValkeyClient",
                accessPath: "makeClient",
                form: .function,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("C.swift"),
                originModule: testModule
            )
        )
        let alias = DiscoveredAdapterAnnotation(
            annotationName: "BackgroundService",
            capability: .contributes(key: "WireMVCKeys.services"),
            location: mockLocation("Adapter.swift"),
            originModule: testModule
        )
        let useSite = ContributionAliasUseSite(
            annotationName: "BackgroundService",
            targetIdentity: "makeClient",
            location: mockLocation("C.swift"),
            originModule: testModule
        )

        let injected = injectAliasContributions(into: [binding], aliases: [alias], useSites: [useSite])
        let contributions = try #require(injected.first?.contributions)
        #expect(contributions.contains { $0.keyReference == "WireMVCKeys.services" })
    }

    @Test func nonAliasAttributesAreNotInjected() {
        let binding = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Plain",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [],
                location: mockLocation("P.swift"),
                originModule: testModule
            )
        )
        // `@Singleton` is captured as a candidate but matches no alias → no contribution.
        let useSite = ContributionAliasUseSite(
            annotationName: "Singleton",
            targetIdentity: "Plain",
            location: mockLocation("P.swift"),
            originModule: testModule
        )
        let injected = injectAliasContributions(into: [binding], aliases: [], useSites: [useSite])
        #expect(injected.first?.contributions.isEmpty == true)
    }
}
