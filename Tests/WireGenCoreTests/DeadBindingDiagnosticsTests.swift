import Testing

@testable import WireGenCore

/// Iteration 5α: the dead-binding warning. A binding consumed by nothing
/// in the partition warns, gated by visibility — `internal`/`package`
/// warn, `public`/`open` stay silent. Tested in isolation here; it isn't
/// wired into the build output until 3-iii.
@Suite("Dead binding diagnostics")
struct DeadBindingDiagnosticsTests {
    private func singleton(
        _ name: String,
        access: AccessLevel = .internal,
        deps: [(type: String, key: String?)] = [],
        contributesTo keyReference: String? = nil,
        allowUnused: Bool = false
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: deps.map {
                    DependencyParameter(
                        name: "d",
                        type: $0.type,
                        kind: .injectProperty,
                        location: mockLocation("\(name).swift"),
                        keyIdentifier: $0.key
                    )
                },
                location: mockLocation("\(name).swift"),
                accessLevel: access,
                contributions: keyReference.map {
                    [Contribution(keyReference: $0, location: mockLocation("\(name).swift"))]
                } ?? [],
                allowUnused: allowUnused
            )
        )
    }

    private func provider(
        _ name: String,
        boundType: String,
        key: String? = nil,
        access: AccessLevel = .internal
    ) -> DiscoveredBinding {
        .provider(
            DiscoveredProvider(
                boundType: boundType,
                accessPath: name,
                form: .property,
                dependencies: [],
                genericParameterNames: [],
                location: mockLocation("\(name).swift"),
                keyIdentifier: key,
                accessLevel: access
            )
        )
    }

    private func warnings(_ bindings: [DiscoveredBinding]) -> [Diagnostic] {
        deadBindingDiagnostics(in: bindings)
    }

    /// The set of source files the warnings are anchored at. Each fixture
    /// uses a distinct `<name>.swift`, so this pins *exactly* which
    /// bindings warned — and, by Set equality, that nothing else did.
    private func warnedFiles(_ bindings: [DiscoveredBinding]) -> Set<String> {
        Set(warnings(bindings).map(\.location.file))
    }

    // MARK: - Visibility gating

    @Test func unusedInternalSingletonWarnsWithExplanatoryMessage() throws {
        let result = warnings([singleton("Orphan")])
        #expect(result.count == 1)
        let warning = try #require(result.first)
        #expect(warning.severity == .warning)
        #expect(warning.location.file == "Orphan.swift")
        #expect(
            warning.message.contains("'Orphan' is declared but nothing in the build consumes it")
        )
        #expect(warning.message.contains("allowUnused: true"))
    }

    @Test func unusedPackageSingletonWarns() {
        #expect(warnedFiles([singleton("Orphan", access: .package)]) == ["Orphan.swift"])
    }

    @Test func unusedPublicSingletonIsSilent() {
        #expect(warnings([singleton("Orphan", access: .public)]).isEmpty)
    }

    @Test func unusedOpenSingletonIsSilent() {
        #expect(warnings([singleton("Orphan", access: .open)]).isEmpty)
    }

    @Test func unusedProviderWarns() {
        #expect(warnedFiles([provider("makeFoo", boundType: "Foo")]) == ["makeFoo.swift"])
    }

    @Test func allowUnusedSilencesTheWarning() {
        #expect(warnings([singleton("Orphan", allowUnused: true)]).isEmpty)
    }

    // MARK: - Liveness

    @Test func consumedBindingIsLiveOnlyRootWarns() {
        // Consumer depends on Producer: Producer is live; exactly one
        // warning, anchored at the Consumer root — nothing at Producer.
        #expect(
            warnedFiles([
                singleton("Consumer", deps: [(type: "Producer", key: nil)]),
                singleton("Producer"),
            ]) == ["Consumer.swift"]
        )
    }

    @Test func optionalConsumerKeepsProducerLive() {
        // A `Producer?` dependency promotes to the `Producer` producer, so
        // only the Consumer root warns.
        #expect(
            warnedFiles([
                singleton("Consumer", deps: [(type: "Producer?", key: nil)]),
                singleton("Producer"),
            ]) == ["Consumer.swift"]
        )
    }

    @Test func keyedConsumerKeepsKeyedProducerLive() {
        // The keyed provider is consumed; only the Consumer root warns.
        #expect(
            warnedFiles([
                singleton("Consumer", deps: [(type: "Database", key: "Database.primary")]),
                provider("primaryDB", boundType: "Database", key: "Database.primary"),
            ]) == ["Consumer.swift"]
        )
    }

    @Test func unconsumedKeyedBindingNamesTheKeyedSlot() throws {
        let result = warnings([
            provider("primaryDB", boundType: "Database", key: "Database.primary")
        ])
        #expect(result.count == 1)
        let warning = try #require(result.first)
        #expect(warning.location.file == "primaryDB.swift")
        #expect(warning.message.contains("'Database' (key Database.primary)"))
    }

    // MARK: - Multibinding contributors (conservative skip for now)

    @Test func contributorIsLiveViaItsAggregate() {
        // A contributor with no direct @Inject consumer is skipped — it's
        // live via its multibinding's consumer.
        #expect(warnings([singleton("AuthPlugin", contributesTo: "App.plugins")]).isEmpty)
    }
}
