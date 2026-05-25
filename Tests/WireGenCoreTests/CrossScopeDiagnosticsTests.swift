import Testing

@testable import WireGenCore

/// Diagnostic-gallery-style tests for cross-scope storage errors.
/// Lives in its own suite (rather than appended to
/// `DiagnosticGalleryTests`) so the gallery struct's body stays
/// under the lint threshold.
@Suite("CrossScopeDiagnostics")
struct CrossScopeDiagnosticsTests {
    // MARK: - Harness

    /// Run discovery on a source string, validate the default graph,
    /// enrich missing-binding errors with cross-scope hints using
    /// the full partition map, and return the rendered diagnostic
    /// text. Mirrors `DiagnosticGalleryTests`'s harness for
    /// consistency.
    private func validate(
        source: String,
        sourcePath: String
    ) -> (errors: GraphResult.ValidationErrors?, rendered: String) {
        let discovery = discover(in: source, sourcePath: sourcePath)
        let result = buildDependencyGraph(
            from: discovery.bindings,
            typealiases: discovery.typealiases
        )
        let enriched = enrichMissingBindingsWithCrossScopeHints(
            result,
            consumerPartition: .default,
            allBindings: discovery.allBindings
        )
        let errors = enriched.outcome.validationErrors
        let rendered = errors.map { renderValidationErrors($0) } ?? ""
        return (errors, rendered)
    }

    // MARK: - Tests

    @Test func singletonStoringScopedBindingRendersCrossScopeNote() throws {
        // `Foo` is `@Singleton` and `@Inject`s `RequestLogger`, which
        // is `@Scoped(seed: HBRequestSeed.self)`. The dep is missing
        // in the default graph (scoped bindings live in their seed
        // partition) but exists elsewhere — the cross-scope hint
        // fires with a `note:` line pointing at the binding's
        // declaration and a fix-it suggesting `Foo` scope to the same
        // seed.
        let source = """
            struct HBRequestSeed {}

            @Scoped(seed: HBRequestSeed.self)
            struct RequestLogger {}

            @Singleton
            struct Foo {
                @Inject var logger: RequestLogger
            }
            """
        let (_, rendered) = validate(source: source, sourcePath: "Source.swift")
        #expect(rendered.contains("error: no binding produces 'RequestLogger'"))
        // Cross-scope hint: binding lives in @Scoped scope.
        #expect(
            rendered.contains(
                "note: 'RequestLogger' is bound in @Scoped(seed: HBRequestSeed.self) scope, not @Singleton"
            )
        )
        // Fix-it: scope the consumer or extract the scope-bound concern.
        #expect(rendered.contains("scope 'Foo' to @Scoped(seed: HBRequestSeed.self)"))
        #expect(rendered.contains("extract the scope-bound concern into a wrapper"))
    }

    @Test func singletonStoringContainerBindingRendersCrossScopeNote() throws {
        // `Foo` is `@Singleton` (default graph) and `@Inject`s a
        // type bound only inside `@Container TestContainer`. Default-
        // graph validation reports the binding missing; the cross-
        // scope hint flags the container-graph location with the
        // "containers are atomic" fix-it.
        let source = """
            @Container
            enum TestContainer {
                @Singleton
                struct Logger {}
            }

            @Singleton
            struct Foo {
                @Inject var logger: TestContainer.Logger
            }
            """
        let (_, rendered) = validate(source: source, sourcePath: "Source.swift")
        #expect(rendered.contains("error: no binding produces 'TestContainer.Logger'"))
        #expect(
            rendered.contains(
                "note: 'TestContainer.Logger' is bound in @Container TestContainer scope, not @Singleton"
            )
        )
        // Fix-it for cross-container cases mentions atomicity.
        #expect(rendered.contains("container graphs are atomic"))
    }

    @Test func siblingSeededScopesProduceIsolationFixIt() throws {
        // Two different seeded scopes (`@Scoped(seed: A.self)` and
        // `@Scoped(seed: B.self)`) are siblings; bindings in one
        // aren't visible to the other. Build the per-seed graph for
        // `A` (which has a binding that `@Inject`s a `B`-scoped
        // type), enrich missing-binding errors against the full
        // partition map, and verify the fix-it points at the
        // sibling-scope isolation reason.
        let source = """
            struct SeedA {}
            struct SeedB {}

            @Scoped(seed: SeedB.self)
            struct BService {}

            @Scoped(seed: SeedA.self)
            struct AService {
                @Inject var b: BService
            }
            """
        let discovery = discover(in: source, sourcePath: "Source.swift")
        // Build the per-seed graph for SeedA only — include the seed
        // synthetic so the orchestrator runs realistically, but no
        // borrows (we want the missing-binding for BService to fire).
        let seedAPartition = Partition(container: nil, scope: ScopeKey(seed: "SeedA"))
        let aBindings = discovery.allBindings[seedAPartition] ?? []
        let orchestration = orchestrateSeedScope(
            seedKey: ScopeKey(seed: "SeedA"),
            scopeBindings: aBindings,
            borrowBindings: [],
            typealiases: discovery.typealiases
        )
        let enriched = enrichMissingBindingsWithCrossScopeHints(
            orchestration.result,
            consumerPartition: seedAPartition,
            allBindings: discovery.allBindings
        )
        let errors = try #require(enriched.outcome.validationErrors)
        let rendered = renderValidationErrors(errors)
        #expect(rendered.contains("error: no binding produces 'BService'"))
        #expect(
            rendered.contains(
                "note: 'BService' is bound in @Scoped(seed: SeedB.self) scope, not @Scoped(seed: SeedA.self)"
            )
        )
        #expect(rendered.contains("sibling seeded scopes are isolated by design"))
    }

    @Test func providerConsumerSurfacedInFixItAsAccessPath() throws {
        // A `@Provides func` whose parameter type is missing should
        // produce a cross-scope hint whose fix-it names the provider
        // by its access path (since providers don't have a type
        // name like scope-bound types do). Exercises the `.provider`
        // branch of consumerTypeName.
        let source = """
            struct HBRequestSeed {}

            @Scoped(seed: HBRequestSeed.self)
            struct RequestLogger {}

            @Provides
            func makeWidget(logger: RequestLogger) -> Widget {
                Widget()
            }

            struct Widget {}
            """
        let (_, rendered) = validate(source: source, sourcePath: "Source.swift")
        #expect(rendered.contains("error: no binding produces 'RequestLogger'"))
        #expect(
            rendered.contains(
                "note: 'RequestLogger' is bound in @Scoped(seed: HBRequestSeed.self) scope"
            )
        )
        // Fix-it names the provider by its access path
        // (`makeWidget` here) rather than a type name.
        #expect(rendered.contains("scope 'makeWidget'"))
    }

    @Test func sameTypeBoundInMultipleContainersListsAllAsNotes() throws {
        // Two containers each bind a `Logger` via `@Provides`. The
        // consumer in the default graph asks for `Logger` (unqualified)
        // — both bindings match by `boundType`. The diagnostic should
        // list both partitions, alphabetised by container name, and
        // use the multiplicity-aware fix-it.
        let source = """
            struct Logger {}

            @Container
            enum Beta {
                @Provides static let logger: Logger = Logger()
            }

            @Container
            enum Alpha {
                @Provides static let logger: Logger = Logger()
            }

            @Singleton
            struct Foo {
                @Inject var logger: Logger
            }
            """
        let (_, rendered) = validate(source: source, sourcePath: "Source.swift")
        #expect(rendered.contains("error: no binding produces 'Logger'"))
        // First (alphabetically): Alpha. Primary note pattern with
        // "is bound in ... scope, not @Singleton".
        #expect(
            rendered.contains(
                "note: 'Logger' is bound in @Container Alpha scope, not @Singleton"
            )
        )
        // Second: Beta. Additional-note pattern with "is also bound in".
        #expect(rendered.contains("note: 'Logger' is also bound in @Container Beta scope"))
        // Fix-it shifts to the multi-binding form.
        #expect(rendered.contains("can't reach any of the listed scopes"))
        #expect(rendered.contains("consolidate the binding into a single reachable scope"))
        // Deterministic order: Alpha note should appear before Beta note
        // in the rendered output (alphabetical sort).
        let alphaMarker = "is bound in @Container Alpha"
        let betaMarker = "is also bound in @Container Beta"
        let alphaSplit = rendered.split(separator: alphaMarker).last.map(String.init) ?? ""
        let betaSplit = rendered.split(separator: betaMarker).last.map(String.init) ?? ""
        #expect(alphaSplit.contains(betaMarker))
        #expect(!betaSplit.contains(alphaMarker))
    }

    @Test func crossScopeHintIsAbsentForGenuinelyMissingBindings() throws {
        // Sanity check: a missing binding where the type ISN'T bound
        // anywhere in the discovery produces only the regular missing-
        // binding error, no cross-scope note. Guards against false
        // positives from the cross-scope enrichment.
        let source = """
            @Singleton
            struct Foo {
                @Inject var nothing: NotABinding
            }
            """
        let (_, rendered) = validate(source: source, sourcePath: "Source.swift")
        #expect(rendered.contains("error: no binding produces 'NotABinding'"))
        #expect(!rendered.contains("is bound in"))
        #expect(!rendered.contains("scope 'Foo' to"))
        #expect(!rendered.contains("containers are atomic"))
    }
}
