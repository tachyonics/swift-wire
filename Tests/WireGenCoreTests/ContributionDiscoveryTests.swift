import Testing

@testable import WireGenCore

/// Step 2 of iteration 5β: contribution discovery. These pin that
/// `@Contributes(to:withOrder:atKey:)` annotations are captured onto the
/// producer (both `@Singleton`/`@Scoped` types and `@Provides`
/// providers), including the order/atKey arguments and multiple keys per
/// contributor. Contributions are captured-but-unused at this step; the
/// fan-in pass (Step 4) consumes them.
@Suite("Contribution discovery")
struct ContributionDiscoveryTests {
    /// Contributions on the first discovered default-graph binding.
    private func contributions(in source: String) -> [Contribution] {
        discover(in: source, sourcePath: "C.swift", module: testModule).bindings.first?.contributions ?? []
    }

    @Test func singletonContributionCapturesKeyReference() throws {
        let source = """
            @Singleton @Contributes(to: App.services)
            struct AuthService {}
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contributions(in: source).count == 1)
        #expect(contribution.keyReference == "App.services")
        #expect(contribution.order == nil)
        #expect(contribution.mapKeyExpression == nil)
    }

    @Test func withOrderArgumentIsCaptured() throws {
        let source = """
            @Singleton @Contributes(to: App.middleware, withOrder: 2)
            struct LoggingMiddleware {}
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.order == 2)
        #expect(contribution.mapKeyExpression == nil)
    }

    @Test func atKeyArgumentIsCapturedVerbatim() throws {
        let source = """
            @Singleton @Contributes(to: App.strategies, atKey: "fast")
            struct FastStrategy {}
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.mapKeyExpression == "\"fast\"")
        #expect(contribution.order == nil)
    }

    @Test func multipleContributesAttributesYieldMultipleContributions() throws {
        // Repeated `@Contributes` (multiple keys per contributor) —
        // confirmed to compile by spike #1.
        let source = """
            @Singleton
            @Contributes(to: App.alpha)
            @Contributes(to: App.beta, withOrder: 1)
            struct MultiContributor {}
            """
        let result = contributions(in: source)
        #expect(result.count == 2)
        #expect(result.map(\.keyReference) == ["App.alpha", "App.beta"])
        #expect(result[1].order == 1)
    }

    @Test func providesPropertyContributionIsCaptured() throws {
        let source = """
            @Provides @Contributes(to: App.services)
            let authService: any Service = AuthService()
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.keyReference == "App.services")
    }

    @Test func providesFunctionContributionIsCaptured() throws {
        let source = """
            @Provides @Contributes(to: App.middleware, withOrder: 3)
            func makeMiddleware() -> any Middleware { LoggingMiddleware() }
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.keyReference == "App.middleware")
        #expect(contribution.order == 3)
    }

    @Test func plainProducerHasNoContributions() {
        let source = """
            @Singleton
            struct PlainService {}
            """
        #expect(contributions(in: source).isEmpty)
    }

    @Test func moduleQualifiedContributesSelectorIsRecognised() throws {
        // SE-0491 `@Wire::Contributes` resolves to the same macro.
        let source = """
            @Singleton @Wire::Contributes(to: App.services)
            struct AuthService {}
            """
        let contribution = try #require(contributions(in: source).first)
        #expect(contribution.keyReference == "App.services")
    }
}
