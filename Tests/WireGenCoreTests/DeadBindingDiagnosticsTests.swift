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

    // MARK: - Visibility gating

    @Test func unusedInternalSingletonWarns() throws {
        let warning = try #require(warnings([singleton("Orphan")]).first)
        #expect(warning.severity == .warning)
        #expect(warning.message.contains("'Orphan'"))
    }

    @Test func unusedPackageSingletonWarns() {
        #expect(!warnings([singleton("Orphan", access: .package)]).isEmpty)
    }

    @Test func unusedPublicSingletonIsSilent() {
        #expect(warnings([singleton("Orphan", access: .public)]).isEmpty)
    }

    @Test func unusedOpenSingletonIsSilent() {
        #expect(warnings([singleton("Orphan", access: .open)]).isEmpty)
    }

    @Test func unusedProviderWarns() {
        #expect(!warnings([provider("makeFoo", boundType: "Foo")]).isEmpty)
    }

    @Test func allowUnusedSilencesTheWarning() {
        #expect(warnings([singleton("Orphan", allowUnused: true)]).isEmpty)
    }

    // MARK: - Liveness

    @Test func consumedBindingIsLive() {
        // Consumer depends on Producer: Producer is live; Consumer is the
        // root (nothing consumes it) and warns.
        let result = warnings([
            singleton("Consumer", deps: [(type: "Producer", key: nil)]),
            singleton("Producer"),
        ])
        #expect(result.contains { $0.message.contains("'Consumer'") })
        #expect(!result.contains { $0.message.contains("'Producer'") })
    }

    @Test func optionalConsumerKeepsProducerLive() {
        // A `Producer?` dependency promotes to the `Producer` producer.
        let result = warnings([
            singleton("Consumer", deps: [(type: "Producer?", key: nil)]),
            singleton("Producer"),
        ])
        #expect(!result.contains { $0.message.contains("'Producer'") })
    }

    @Test func keyedConsumerKeepsKeyedProducerLive() {
        let result = warnings([
            singleton("Consumer", deps: [(type: "Database", key: "Database.primary")]),
            provider("primaryDB", boundType: "Database", key: "Database.primary"),
        ])
        #expect(!result.contains { $0.message.contains("key Database.primary") })
    }

    @Test func unconsumedKeyedBindingWarnsWithKeyInMessage() throws {
        let warning = try #require(
            warnings([provider("primaryDB", boundType: "Database", key: "Database.primary")]).first
        )
        #expect(warning.message.contains("key Database.primary"))
    }

    // MARK: - Multibinding contributors (conservative skip for now)

    @Test func contributorIsLiveViaItsAggregate() {
        // A contributor with no direct @Inject consumer is skipped — it's
        // live via its multibinding's consumer.
        #expect(warnings([singleton("AuthPlugin", contributesTo: "App.plugins")]).isEmpty)
    }
}
