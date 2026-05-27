import Testing

@testable import WireGenCore

@Suite("Lazy consumer classification")
struct LazyConsumerClassificationTests {
    // MARK: - classifyLazyConsumers

    @Test func directOnlyClassificationWhenNoLazyConsumers() {
        let bindings: [DiscoveredBinding] = [
            makeConsumer(name: "A", deps: [makeDep(type: "B", isLazyWrapped: false)])
        ]
        let result = classifyLazyConsumers(in: bindings)
        #expect(result[LazyConsumerKey(type: "B")] == .directOnly)
    }

    @Test func lazyOnlyClassificationWhenAllConsumersWrapTheSameType() {
        let bindings: [DiscoveredBinding] = [
            makeConsumer(name: "A", deps: [makeDep(type: "B", isLazyWrapped: true)]),
            makeConsumer(name: "C", deps: [makeDep(type: "B", isLazyWrapped: true)]),
        ]
        let result = classifyLazyConsumers(in: bindings)
        #expect(result[LazyConsumerKey(type: "B")] == .lazyOnly)
    }

    @Test func mixedClassificationWhenBothDirectAndLazyConsumersExist() {
        let bindings: [DiscoveredBinding] = [
            makeConsumer(name: "A", deps: [makeDep(type: "B", isLazyWrapped: true)]),
            makeConsumer(name: "C", deps: [makeDep(type: "B", isLazyWrapped: false)]),
        ]
        let result = classifyLazyConsumers(in: bindings)
        #expect(result[LazyConsumerKey(type: "B")] == .mixed)
    }

    @Test func keyedConsumersClassifyIndependentlyFromUnkeyed() {
        // `B` and `B@primary` are distinct binding slots — Dagger
        // semantics, keys partition the binding space. Same-type
        // mixed-consumer cases at different keys don't bleed.
        let bindings: [DiscoveredBinding] = [
            makeConsumer(
                name: "A",
                deps: [makeDep(type: "B", isLazyWrapped: true)]
            ),
            makeConsumer(
                name: "C",
                deps: [makeDep(type: "B", isLazyWrapped: false, keyIdentifier: "primary")]
            ),
        ]
        let result = classifyLazyConsumers(in: bindings)
        #expect(result[LazyConsumerKey(type: "B")] == .lazyOnly)
        #expect(result[LazyConsumerKey(type: "B", keyIdentifier: "primary")] == .directOnly)
    }

    @Test func canonicalisesWhitespaceInTypeExpressionsAcrossConsumers() {
        // `Router<X, Y>` and `Router<X,Y>` are the same graph slot —
        // canonicalisation strips whitespace, matching the graph
        // builder's identity rule.
        let bindings: [DiscoveredBinding] = [
            makeConsumer(
                name: "A",
                deps: [makeDep(type: "Router<X, Y>", isLazyWrapped: true)]
            ),
            makeConsumer(
                name: "C",
                deps: [makeDep(type: "Router<X,Y>", isLazyWrapped: false)]
            ),
        ]
        let result = classifyLazyConsumers(in: bindings)
        #expect(result[LazyConsumerKey(type: "Router<X,Y>")] == .mixed)
    }

    @Test func typesWithoutConsumersAreAbsentFromResult() {
        // A binding with no deps doesn't appear in any classification
        // slot — classification is about consumer presence, not
        // bindings themselves.
        let bindings: [DiscoveredBinding] = [
            makeConsumer(name: "A", deps: [])
        ]
        let result = classifyLazyConsumers(in: bindings)
        #expect(result.isEmpty)
    }

    // MARK: - lazyNoEffectWarnings

    @Test func emitsWarningAtEachLazyConsumerSiteWhenMixed() {
        let lazyLocation = WireGenCore.SourceLocation(file: "Source.swift", line: 8, column: 17)
        let directLocation = WireGenCore.SourceLocation(file: "Source.swift", line: 15, column: 23)
        let bindings: [DiscoveredBinding] = [
            makeConsumer(
                name: "A",
                deps: [
                    makeDep(
                        type: "DatabasePool",
                        isLazyWrapped: true,
                        location: lazyLocation
                    )
                ]
            ),
            makeConsumer(
                name: "C",
                deps: [
                    makeDep(
                        type: "DatabasePool",
                        isLazyWrapped: false,
                        location: directLocation
                    )
                ]
            ),
        ]
        let warnings = lazyNoEffectWarnings(in: bindings)
        #expect(warnings.count == 1)
        let warning = try! #require(warnings.first)
        #expect(warning.location == lazyLocation)
        #expect(warning.message.contains("'Lazy<DatabasePool>' has no deferral effect here"))
        #expect(warning.message.contains("'DatabasePool' is constructed eagerly for another consumer"))
        #expect(warning.notes.count == 2)
        #expect(warning.notes[0].location == directLocation)
        #expect(warning.notes[0].message.contains("'DatabasePool' is also injected directly here"))
        #expect(warning.notes[1].location == lazyLocation)
        #expect(warning.notes[1].message.contains("inject 'DatabasePool' directly to avoid the wrapper"))
        #expect(warning.notes[1].message.contains("remove the direct injection if deferral was intended"))
    }

    @Test func noWarningsForDirectOnlyClassification() {
        let bindings: [DiscoveredBinding] = [
            makeConsumer(name: "A", deps: [makeDep(type: "B", isLazyWrapped: false)]),
            makeConsumer(name: "C", deps: [makeDep(type: "B", isLazyWrapped: false)]),
        ]
        #expect(lazyNoEffectWarnings(in: bindings).isEmpty)
    }

    @Test func noWarningsForLazyOnlyClassification() {
        // The whole point of `Lazy<T>` — no direct consumer forces
        // eager construction, the wrapper is doing work. No warning.
        let bindings: [DiscoveredBinding] = [
            makeConsumer(name: "A", deps: [makeDep(type: "B", isLazyWrapped: true)]),
            makeConsumer(name: "C", deps: [makeDep(type: "B", isLazyWrapped: true)]),
        ]
        #expect(lazyNoEffectWarnings(in: bindings).isEmpty)
    }

    @Test func emitsOneWarningPerLazyConsumerWhenMultipleLazyConsumersAndAtLeastOneDirect() {
        // Two Lazy<T> sites in different files; one direct site
        // elsewhere. Both Lazy sites are no-op — emit a warning at
        // each.
        let bindings: [DiscoveredBinding] = [
            makeConsumer(
                name: "A",
                deps: [
                    makeDep(
                        type: "B",
                        isLazyWrapped: true,
                        location: WireGenCore.SourceLocation(file: "A.swift", line: 5, column: 3)
                    )
                ]
            ),
            makeConsumer(
                name: "C",
                deps: [
                    makeDep(
                        type: "B",
                        isLazyWrapped: true,
                        location: WireGenCore.SourceLocation(file: "C.swift", line: 9, column: 3)
                    )
                ]
            ),
            makeConsumer(
                name: "D",
                deps: [
                    makeDep(
                        type: "B",
                        isLazyWrapped: false,
                        location: WireGenCore.SourceLocation(file: "D.swift", line: 3, column: 3)
                    )
                ]
            ),
        ]
        let warnings = lazyNoEffectWarnings(in: bindings)
        #expect(warnings.count == 2)
        // Sorted by (file, line, column) — A.swift before C.swift.
        #expect(warnings[0].location.file == "A.swift")
        #expect(warnings[1].location.file == "C.swift")
        // Both warnings reference the same direct-consumer site.
        #expect(warnings[0].notes[0].location.file == "D.swift")
        #expect(warnings[1].notes[0].location.file == "D.swift")
    }

    @Test func keyedMixedConsumersWarnUnderTheSameKey() {
        // Mixed at the same `(type, key)` slot fires the warning;
        // mixed at a *different* key would not (the two keys are
        // independent slots).
        let bindings: [DiscoveredBinding] = [
            makeConsumer(
                name: "A",
                deps: [
                    makeDep(
                        type: "DatabasePool",
                        isLazyWrapped: true,
                        keyIdentifier: "primary"
                    )
                ]
            ),
            makeConsumer(
                name: "C",
                deps: [
                    makeDep(
                        type: "DatabasePool",
                        isLazyWrapped: false,
                        keyIdentifier: "primary"
                    )
                ]
            ),
            // A consumer of the unkeyed slot in isolation — lazy only
            // for that slot. Not in `.mixed`, so no warning.
            makeConsumer(
                name: "E",
                deps: [
                    makeDep(type: "DatabasePool", isLazyWrapped: true)
                ]
            ),
        ]
        let warnings = lazyNoEffectWarnings(in: bindings)
        #expect(warnings.count == 1)
    }

    @Test func warningsAreSortedByLocation() {
        // Bindings deliberately reversed in the input — the warning
        // output should still be sorted by `(file, line, column)`.
        let bindings: [DiscoveredBinding] = [
            makeConsumer(
                name: "Late",
                deps: [
                    makeDep(
                        type: "B",
                        isLazyWrapped: true,
                        location: WireGenCore.SourceLocation(file: "Z.swift", line: 20, column: 1)
                    )
                ]
            ),
            makeConsumer(
                name: "Early",
                deps: [
                    makeDep(
                        type: "B",
                        isLazyWrapped: true,
                        location: WireGenCore.SourceLocation(file: "A.swift", line: 5, column: 1)
                    )
                ]
            ),
            makeConsumer(
                name: "Direct",
                deps: [makeDep(type: "B", isLazyWrapped: false)]
            ),
        ]
        let warnings = lazyNoEffectWarnings(in: bindings)
        #expect(warnings.count == 2)
        #expect(warnings[0].location.file == "A.swift")
        #expect(warnings[1].location.file == "Z.swift")
    }

    // MARK: - Helpers

    private func makeConsumer(
        name: String,
        deps: [DependencyParameter]
    ) -> DiscoveredBinding {
        .scopeBound(
            DiscoveredScopeBoundType(
                typeName: name,
                typeKind: "struct",
                genericParameterNames: [],
                dependencies: deps,
                location: WireGenCore.SourceLocation(file: "\(name).swift", line: 1, column: 1)
            )
        )
    }

    private func makeDep(
        type: String,
        isLazyWrapped: Bool,
        keyIdentifier: String? = nil,
        location: WireGenCore.SourceLocation = WireGenCore.SourceLocation(
            file: "Dep.swift",
            line: 1,
            column: 1
        )
    ) -> DependencyParameter {
        DependencyParameter(
            name: "dep",
            type: type,
            kind: .injectProperty,
            location: location,
            keyIdentifier: keyIdentifier,
            isLazyWrapped: isLazyWrapped
        )
    }
}
