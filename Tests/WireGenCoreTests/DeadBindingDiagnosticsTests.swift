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
                allowUnused: allowUnused,
                originModule: testModule
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
                accessLevel: access,
                originModule: testModule
            )
        )
    }

    /// An `@Singleton(as: Identity.self)` lift node: generic over one
    /// constrained parameter, injecting it as a bare dependency (which bridges
    /// to the matching `some P` binding).
    private func liftNode(
        _ typeName: String,
        identity: String,
        parameter: String,
        constraint: String
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: typeName,
                typeKind: "struct",
                genericParameterNames: [parameter],
                genericParameterConstraints: [parameter: constraint],
                explicitIdentity: identity,
                dependencies: [
                    DependencyParameter(
                        name: "d",
                        type: parameter,
                        kind: .injectProperty,
                        location: mockLocation("\(typeName).swift")
                    )
                ],
                location: mockLocation("\(typeName).swift"),
                originModule: testModule
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

    // MARK: - Per-container grouping (across:)

    @Test func singletonConsumedOnlyByScopeIsLive() {
        // Logger lives in the default singleton partition; only a default
        // seed-scope binding consumes it (a borrow). Per-container merge
        // keeps it live — only the scope root warns.
        let partitions: [Partition: [DiscoveredBinding]] = [
            Partition(container: nil, scope: nil): [singleton("Logger")],
            Partition(container: nil, scope: ScopeKey(seed: "Req")): [
                singleton("RequestLogger", deps: [(type: "Logger", key: nil)])
            ],
        ]
        let files = Set(deadBindingDiagnostics(across: partitions).map(\.location.file))
        #expect(files == ["RequestLogger.swift"])
    }

    @Test func crossContainerConsumptionDoesNotKeepBindingLive() {
        // bannerA lives in container A but is "consumed" only in container
        // B. Containers are atomic, so A's bannerA is genuinely dead.
        let partitions: [Partition: [DiscoveredBinding]] = [
            Partition(container: "A", scope: nil): [provider("bannerA", boundType: "Banner")],
            Partition(container: "B", scope: nil): [
                singleton("ConsumerB", deps: [(type: "Banner", key: nil)])
            ],
        ]
        let files = Set(deadBindingDiagnostics(across: partitions).map(\.location.file))
        #expect(files == ["bannerA.swift", "ConsumerB.swift"])
    }

    // MARK: - Liveness via generic specialisation

    @Test func concreteProducerConsumedViaSpecialisationIsLive() {
        // `Table` is consumed only by a generic `Repo<T>` whose dependency
        // is the bare parameter `table: T`. The discovered `Repo` is
        // generic (skipped from warnings) and its `table: T` edge doesn't
        // reach `Table`. The resolved graph's specialised `Repo<Table>`
        // carries the substituted `table: Table` edge, which keeps `Table`
        // live.
        let genericRepo = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Repo",
                typeKind: "struct",
                genericParameterNames: ["T"],
                dependencies: [
                    DependencyParameter(
                        name: "table",
                        type: "T",
                        kind: .injectProperty,
                        location: mockLocation("Repo.swift"),
                        keyIdentifier: nil
                    )
                ],
                location: mockLocation("Repo.swift"),
                accessLevel: .internal,
                contributions: [],
                allowUnused: false,
                originModule: testModule
            )
        )
        let specialisedRepo = DiscoveredBinding.scopeBound(
            DiscoveredScopeBoundType(
                typeName: "Repo<Table>",
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: [
                    DependencyParameter(
                        name: "table",
                        type: "Table",
                        kind: .injectProperty,
                        location: mockLocation("Repo.swift"),
                        keyIdentifier: nil
                    )
                ],
                location: mockLocation("Repo.swift"),
                accessLevel: .internal,
                contributions: [],
                allowUnused: false,
                originModule: testModule
            )
        )
        let partitions: [Partition: [DiscoveredBinding]] = [
            Partition(container: nil, scope: nil): [
                genericRepo, provider("makeTable", boundType: "Table"),
            ]
        ]

        // With the resolved graph supplied, the substituted edge keeps
        // `Table` live and nothing warns.
        #expect(
            deadBindingDiagnostics(
                across: partitions,
                resolvedByContainer: [nil: [specialisedRepo]]
            ).isEmpty
        )

        // Without it, the substituted edge is invisible and `Table` is
        // reported dead — the gap this resolved-graph input closes.
        #expect(
            Set(deadBindingDiagnostics(across: partitions).map(\.location.file))
                == ["makeTable.swift"]
        )
    }

    // MARK: - Opaque lift nodes

    @Test func opaqueLiftChainProducesNoDeadBindingWarnings() {
        // leaf (some DBTable & Sendable) <- Repo (some TaskRepo) <- Controller
        // (some API). The leaf is consumed via the constrained-parameter bridge;
        // the lift nodes are generic, so they're skipped like any generic (the
        // controller is read off the graph as a root). Nothing warns.
        let partitions: [Partition: [DiscoveredBinding]] = [
            Partition(container: nil, scope: nil): [
                provider("table", boundType: "some DBTable & Sendable"),
                liftNode("Repo", identity: "TaskRepo", parameter: "Table", constraint: "DBTable & Sendable"),
                liftNode("Controller", identity: "API", parameter: "Repository", constraint: "TaskRepo"),
            ]
        ]
        #expect(deadBindingDiagnostics(across: partitions).isEmpty)
    }

    @Test func unconsumedOpaqueProviderStillWarns() {
        // An opaque `@Provides let x: some P` that nothing consumes is dead like
        // any other provider — the `some P` identity doesn't suppress the check.
        #expect(
            Set(
                deadBindingDiagnostics(across: [
                    Partition(container: nil, scope: nil): [
                        provider("orphan", boundType: "some DBTable & Sendable")
                    ]
                ]).map(\.location.file)
            ) == ["orphan.swift"]
        )
    }

    // MARK: - Multibinding contributors (conservative skip for now)

    @Test func contributorIsLiveViaItsAggregate() {
        // A contributor with no direct @Inject consumer is skipped — it's
        // live via its multibinding's consumer.
        #expect(warnings([singleton("AuthPlugin", contributesTo: "App.plugins")]).isEmpty)
    }
}
