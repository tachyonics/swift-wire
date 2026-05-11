import Testing

@testable import WireGenCore

/// The diagnostic gallery — intentionally-broken graphs paired with the
/// exact diagnostic each should produce. This suite is the regression
/// surface for diagnostic *quality*: every fix-up to an error message
/// or position should land an assertion here so a future change can't
/// silently degrade what the user sees.
///
/// Each test runs the real pipeline end-to-end on an inline source
/// string — `discover()` → `buildDependencyGraph()` →
/// `renderValidationErrors()` — and asserts on the rendered output.
/// The harness deliberately does *not* invoke the WireGen executable:
/// the build-plugin integration is covered by `IntegrationTests`; this
/// suite focuses on the diagnostic content the executable would emit.
@Suite("DiagnosticGallery")
struct DiagnosticGalleryTests {
    // MARK: - Harness

    /// Run discovery + validation on one source string and return the
    /// validation errors plus the rendered diagnostic text. The bindings
    /// list is returned too so tests can assert on what the graph saw
    /// before failing.
    private func validate(
        source: String,
        sourcePath: String
    ) -> (errors: GraphResult.ValidationErrors?, rendered: String) {
        let discovery = discover(in: source, sourcePath: sourcePath)
        let result = buildDependencyGraph(from: discovery.bindings)
        let errors = result.outcome.validationErrors
        let rendered = errors.map { renderValidationErrors($0) } ?? ""
        return (errors, rendered)
    }

    // MARK: - Missing bindings

    @Test func missingBindingForPrimitiveTypeAnchorsAtInjectSite() throws {
        // Greeter `@Inject`s a `Logger`, but no `@Singleton`, `@Provides`,
        // or other binding produces one. The diagnostic should anchor at
        // the @Inject property site (not at the Greeter type) so the
        // user lands on the line with the unsatisfied dependency.
        let source = """
            @Singleton
            struct Greeter {
                @Inject var logger: Logger
            }
            """
        let (errors, rendered) = validate(source: source, sourcePath: "Greeter.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.missingBindings.count == 1)
        // Line 3 = the `@Inject var logger:` line; column 17 = start of
        // `logger` (4-space indent + "@Inject var " = 16 chars; the
        // identifier starts at column 17, 1-based).
        #expect(rendered.contains("Greeter.swift:3:17: error: no binding produces 'Logger'"))
    }

    @Test func missingBindingPointsAtEachUnsatisfiedDependencySeparately() throws {
        // Two unsatisfied dependencies → two diagnostics, each at its
        // own dependency site.
        let source = """
            @Singleton
            struct Service {
                @Inject var alpha: Alpha
                @Inject var beta: Beta
            }
            """
        let (errors, rendered) = validate(source: source, sourcePath: "Service.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.missingBindings.count == 2)
        #expect(rendered.contains("Service.swift:3:17: error: no binding produces 'Alpha'"))
        #expect(rendered.contains("Service.swift:4:17: error: no binding produces 'Beta'"))
    }

    // MARK: - Dependency cycles

    @Test func twoNodeCycleRendersWithArrowsAtFirstNode() throws {
        // A → B → A. The diagnostic should anchor at A (the cycle's
        // first node in the traversal) and render the full path.
        let source = """
            @Singleton
            struct A {
                @Inject var b: B
            }

            @Singleton
            struct B {
                @Inject var a: A
            }
            """
        let (errors, rendered) = validate(source: source, sourcePath: "AB.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.cycles.count == 1)
        // A starts at line 2 column 8 ("struct A" — column points at `A`).
        #expect(rendered.contains("AB.swift:2:8: error: dependency cycle: A → B → A"))
    }

    @Test func threeNodeCycleRendersFullPath() throws {
        // A → B → C → A. All three nodes should appear in the rendered
        // path so the user sees the full cycle, not just the first edge.
        let source = """
            @Singleton
            struct A {
                @Inject var b: B
            }

            @Singleton
            struct B {
                @Inject var c: C
            }

            @Singleton
            struct C {
                @Inject var a: A
            }
            """
        let (errors, rendered) = validate(source: source, sourcePath: "ABC.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.cycles.count == 1)
        #expect(rendered.contains("ABC.swift:2:8: error: dependency cycle: A → B → C → A"))
    }

    @Test func selfLoopRendersAsSingleArrow() throws {
        // A → A. Same cycle machinery but the rendered path is just
        // `A → A` (one edge).
        let source = """
            @Singleton
            struct A {
                @Inject var a: A
            }
            """
        let (errors, rendered) = validate(source: source, sourcePath: "A.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.cycles.count == 1)
        #expect(rendered.contains("A.swift:2:8: error: dependency cycle: A → A"))
    }

    // MARK: - Duplicate bindings

    @Test func twoSingletonsForSameTypeFlagWithNoteOnSecond() throws {
        // Two `@Singleton`s claiming the same type name `Logger`. The
        // primary error lands on the first; subsequent declarations get
        // `note: also bound here`.
        let source = """
            @Singleton
            struct Logger {
            }

            @Singleton
            struct Logger {
            }
            """
        let (errors, rendered) = validate(source: source, sourcePath: "Logger.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.duplicateBindings.count == 1)
        #expect(
            rendered.contains(
                "Logger.swift:2:8: error: type 'Logger' has multiple bindings; the dependency graph is ambiguous"
            )
        )
        #expect(rendered.contains("Logger.swift:6:8: note: also bound here"))
    }

    @Test func singletonAndProviderForSameTypeIsAlsoAmbiguous() throws {
        // The realistic shape: a `@Singleton` and a `@Provides` for the
        // exact same type. Same diagnostic shape — primary error on the
        // first binding, note on the second.
        let source = """
            @Singleton
            struct Logger {
            }

            @Provides
            let alternateLogger: Logger = Logger()
            """
        let (errors, rendered) = validate(source: source, sourcePath: "Loggers.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.duplicateBindings.count == 1)
        #expect(
            rendered.contains(
                "Loggers.swift:2:8: error: type 'Logger' has multiple bindings; the dependency graph is ambiguous"
            )
        )
        #expect(rendered.contains("Loggers.swift:6:5: note: also bound here"))
    }

    // MARK: - Output format

    @Test func everyDiagnosticLineCarriesFileLineColPrefix() throws {
        // Format guard: every non-empty line of the rendered output
        // must start with `<file>:<line>:<col>: <severity>:` so build
        // tools (Xcode, swiftc-driven pipelines) parse and surface them
        // as clickable diagnostics. A regression here that drops the
        // prefix would silently break IDE integration.
        let source = """
            @Singleton
            struct Logger {
            }

            @Singleton
            struct Logger {
            }

            @Singleton
            struct Greeter {
                @Inject var missing: Missing
            }
            """
        let (_, rendered) = validate(source: source, sourcePath: "Combined.swift")
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(!lines.isEmpty)
        for line in lines {
            // `file:line:col: severity:` — verify the first three colons
            // delimit numeric line/col and a recognised severity word.
            let parts = line.split(separator: ":", maxSplits: 4)
            #expect(parts.count >= 5, "diagnostic line missing prefix: \(line)")
            #expect(Int(parts[1]) != nil, "non-numeric line in: \(line)")
            #expect(Int(parts[2]) != nil, "non-numeric column in: \(line)")
            // After splitting on `:`, the severity slot has a leading
            // space from the `: error:` separator. Match against the
            // space-prefixed forms rather than reaching for Foundation
            // to trim.
            #expect(
                parts[3] == " error" || parts[3] == " note",
                "unexpected severity in: \(line)"
            )
        }
    }
}
