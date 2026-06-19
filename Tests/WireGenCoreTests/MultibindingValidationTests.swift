import Testing

@testable import WireGenCore

/// Step 3 of iteration 5β: validation diagnostics. Bare `@Contributes`
/// (no producer macro) surfaces as a visitor warning; the cross-
/// contributor checks (undeclared key, mixed `withOrder:`, duplicate
/// `atKey:`) are assembled module-wide the way WireGen does. Each
/// diagnostic is an `.error` — these patterns either drop a contribution
/// silently or would emit code that traps at runtime.
@Suite("Multibinding validation")
struct MultibindingValidationTests {
    /// All multibinding diagnostics for a source, combining the per-file
    /// visitor warnings with the module-wide cross-contributor checks —
    /// the same composition WireGen performs.
    private func diagnostics(in source: String) -> [Diagnostic] {
        let discovery = discover(in: source, sourcePath: "M.swift")
        let contributions = discovery.allBindings.values
            .flatMap { $0 }
            .flatMap { $0.contributions }
        return discovery.warnings
            + multibindingContributionDiagnostics(
                declaredKeyReferences: Set(discovery.multibindingKeys.map(\.keyReference)),
                contributions: contributions
            )
    }

    private func first(_ source: String, matching needle: String) -> Diagnostic? {
        diagnostics(in: source).first { $0.message.contains(needle) }
    }

    private func crossContainerDiagnostics(in source: String) -> [Diagnostic] {
        let discovery = discover(in: source, sourcePath: "M.swift")
        return crossContainerContributionDiagnostics(
            multibindingKeys: discovery.multibindingKeys,
            bindingsByPartition: discovery.allBindings
        )
    }

    // MARK: - Bare @Contributes (producer-pairing)

    @Test func bareContributesOnTypeRequiresScopeProducer() throws {
        let source = """
            @Contributes(to: App.services)
            struct AuthService {}
            """
        let diagnostic = try #require(first(source, matching: "@Contributes requires"))
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("@Singleton or @Scoped"))
    }

    @Test func bareContributesOnVariableRequiresProvides() throws {
        let source = """
            @Contributes(to: App.services)
            let authService: any Service = AuthService()
            """
        let diagnostic = try #require(first(source, matching: "@Contributes requires"))
        #expect(diagnostic.message.contains("@Provides"))
    }

    @Test func pairedContributorHasNoBareDiagnostic() {
        let source = """
            enum App { static let services = CollectedKey<any Service>() }
            @Singleton @Contributes(to: App.services)
            struct AuthService {}
            """
        #expect(first(source, matching: "@Contributes requires") == nil)
    }

    // MARK: - Undeclared key

    @Test func contributionToUndeclaredKeyIsError() throws {
        let source = """
            @Singleton @Contributes(to: App.missing)
            struct AuthService {}
            """
        let diagnostic = try #require(first(source, matching: "no multibinding key"))
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("App.missing"))
    }

    @Test func contributionToDeclaredKeyIsAccepted() {
        let source = """
            enum App { static let services = CollectedKey<any Service>() }
            @Singleton @Contributes(to: App.services)
            struct AuthService {}
            """
        #expect(first(source, matching: "no multibinding key") == nil)
    }

    // MARK: - Mixed ordering

    @Test func mixedWithOrderIsError() throws {
        let source = """
            enum App { static let services = CollectedKey<any Service>() }
            @Singleton @Contributes(to: App.services, withOrder: 1)
            struct A {}
            @Singleton @Contributes(to: App.services)
            struct B {}
            """
        let diagnostic = try #require(first(source, matching: "all-or-none"))
        #expect(diagnostic.severity == .error)
    }

    @Test func uniformWithOrderIsAccepted() {
        let source = """
            enum App { static let services = CollectedKey<any Service>() }
            @Singleton @Contributes(to: App.services, withOrder: 1)
            struct A {}
            @Singleton @Contributes(to: App.services, withOrder: 2)
            struct B {}
            """
        #expect(first(source, matching: "all-or-none") == nil)
    }

    @Test func duplicateWithOrderIsError() throws {
        let source = """
            enum App { static let services = CollectedKey<any Service>() }
            @Singleton @Contributes(to: App.services, withOrder: 1)
            struct A {}
            @Singleton @Contributes(to: App.services, withOrder: 1)
            struct B {}
            """
        let diagnostic = try #require(first(source, matching: "duplicate withOrder"))
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("ranks must be unique"))
        let note = try #require(diagnostic.notes.first)
        #expect(note.message.contains("first used here"))
    }

    @Test func distinctWithOrderRanksAreAccepted() {
        // Covered by uniformWithOrderIsAccepted's data, asserted here for
        // the duplicate-order check specifically.
        let source = """
            enum App { static let services = CollectedKey<any Service>() }
            @Singleton @Contributes(to: App.services, withOrder: 1)
            struct A {}
            @Singleton @Contributes(to: App.services, withOrder: 2)
            struct B {}
            """
        #expect(first(source, matching: "duplicate withOrder") == nil)
    }

    // MARK: - Duplicate atKey

    @Test func duplicateMapKeyIsError() throws {
        let source = """
            enum App { static let strategies = MappedKey<String, any Strategy>() }
            @Singleton @Contributes(to: App.strategies, atKey: "fast")
            struct A {}
            @Singleton @Contributes(to: App.strategies, atKey: "fast")
            struct B {}
            """
        let diagnostic = try #require(first(source, matching: "duplicate atKey"))
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("\"fast\""))
        // The first contributor's location is a separate note, not
        // embedded in the message.
        let note = try #require(diagnostic.notes.first)
        #expect(note.message.contains("first used here"))
    }

    @Test func distinctMapKeysAreAccepted() {
        let source = """
            enum App { static let strategies = MappedKey<String, any Strategy>() }
            @Singleton @Contributes(to: App.strategies, atKey: "fast")
            struct A {}
            @Singleton @Contributes(to: App.strategies, atKey: "slow")
            struct B {}
            """
        #expect(first(source, matching: "duplicate atKey") == nil)
    }

    // MARK: - Cross-container contribution

    @Test func crossContainerContributionIsError() throws {
        // Key declared in container App; contributor in the default graph.
        let source = """
            @Container
            enum App {
                static let services = CollectedKey<any Service>()
            }
            @Singleton @Contributes(to: App.services)
            struct AuthService {}
            """
        let diagnostic = try #require(crossContainerDiagnostics(in: source).first)
        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("cross container"))
    }

    @Test func sameContainerContributionIsAccepted() {
        let source = """
            @Container
            enum App {
                static let services = CollectedKey<any Service>()
                @Singleton @Contributes(to: App.services)
                struct AuthService {}
            }
            """
        #expect(crossContainerDiagnostics(in: source).isEmpty)
    }

    @Test func defaultGraphContributionIsAccepted() {
        let source = """
            enum App { static let services = CollectedKey<any Service>() }
            @Singleton @Contributes(to: App.services)
            struct AuthService {}
            """
        #expect(crossContainerDiagnostics(in: source).isEmpty)
    }
}
