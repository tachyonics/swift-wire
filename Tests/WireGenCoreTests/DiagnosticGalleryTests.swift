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

    // MARK: - Keyed bindings

    @Test func keyedMissingBindingIncludesKeyInMessage() throws {
        // Consumer asks for a keyed binding; no provider exists for
        // that exact (type, key) slot. Diagnostic names both the type
        // and the key so the user can see which slot is unfilled.
        let source = """
            @Singleton
            struct UserRepo {
                @Inject(Database.primary) var db: Database
            }
            """
        let (errors, rendered) = validate(source: source, sourcePath: "UserRepo.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.missingBindings.count == 1)
        #expect(validationErrors.missingBindings[0].dependency.keyIdentifier == "Database.primary")
        #expect(
            rendered.contains(
                "UserRepo.swift:3:35: error: no binding produces 'Database' keyed 'Database.primary'"
            )
        )
    }

    @Test func keyedDuplicateBindingNamesTheKeyAndOmitsFixItNote() throws {
        // Two `@Provides` of the same type with the same key — duplicate
        // at the (type, key) level. The key is already named on both
        // sides, so the diagnostic just identifies which keyed slot is
        // overloaded; no fix-it note suggesting "use keys" because the
        // user already is.
        let source = """
            @Provides(Database.primary)
            let dbA: Database = Database()

            @Provides(Database.primary)
            let dbB: Database = Database()
            """
        let (errors, rendered) = validate(source: source, sourcePath: "Loggers.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.duplicateBindings.count == 1)
        #expect(validationErrors.duplicateBindings[0].keyIdentifier == "Database.primary")
        #expect(
            rendered.contains(
                "error: type 'Database' keyed 'Database.primary' has multiple bindings"
            )
        )
        #expect(!rendered.contains("note: to disambiguate"))
    }

    @Test func unkeyedDuplicateBindingShowsFixItNote() throws {
        // Unkeyed duplicate — the original sitting 1a case — now also
        // gets a fix-it note pointing at the key-disambiguation pattern.
        // Reuses the gallery's existing duplicate fixture so the note is
        // the new piece under test.
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
        #expect(validationErrors.duplicateBindings[0].keyIdentifier == nil)
        #expect(rendered.contains("note: to disambiguate, declare named keys"))
        #expect(rendered.contains("BindingKey<Logger>()"))
        #expect(rendered.contains("@Provides(Logger.primary)"))
        #expect(rendered.contains("@Inject(Logger.primary)"))
    }

    @Test func keyedProviderSatisfiesKeyedConsumerCleanly() throws {
        // Positive case — a keyed `@Provides` and a keyed `@Inject` on
        // the same (type, key) resolve, no validation errors. Confirms
        // the happy path through the new graph keying. (Also confirms
        // an unkeyed dep alongside doesn't accidentally match the keyed
        // binding.)
        let source = """
            @Provides(Database.primary)
            let primaryDB: Database = Database()

            @Singleton
            struct UserRepo {
                @Inject(Database.primary) var db: Database
            }
            """
        let (errors, _) = validate(source: source, sourcePath: "App.swift")
        #expect(errors == nil)
    }

    // MARK: - Generic specialisation ambiguity

    @Test func multipleGenericCandidatesEmitDuplicateBindingError() throws {
        // Two `@Provides func` declarations both produce `Repository<T>`
        // for any `T`. A consumer asking for `Repository<DynamoDBTable>`
        // could be satisfied by either — Wire surfaces this as a
        // duplicate-binding error rather than silently picking one.
        let source = """
            @Provides
            func makeRepoA<T>() -> Repository<T> {
                Repository<T>()
            }

            @Provides
            func makeRepoB<T>() -> Repository<T> {
                Repository<T>()
            }

            @Singleton
            struct App {
                @Inject var repo: Repository<DynamoDBTable>
            }
            """
        let (errors, rendered) = validate(source: source, sourcePath: "Repos.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.duplicateBindings.count == 1)
        #expect(
            rendered.contains(
                "error: type 'Repository<DynamoDBTable>' has multiple bindings"
            )
        )
    }

    // MARK: - Generated-identifier collision

    // MARK: - Warnings

    @Test func containerWithScopeRendersAsWarning() throws {
        // The warning prefix is `file:line:col: warning:` per Swift
        // compiler convention. Distinct from errors — render path
        // is its own function (`renderWarnings`), and WireGen will
        // not exit non-zero on warnings alone. Beyond the prefix the
        // test pins both halves of the message: the "why" clause
        // (two roles, separate graphs) and the fix-it (split into
        // two declarations with explicit role assignment).
        let source = """
            @Container
            @Singleton
            struct Mixed {
            }
            """
        let discovery = discover(in: source, sourcePath: "Mixed.swift")
        let rendered = renderWarnings(discovery.warnings)
        #expect(
            rendered.contains(
                "Mixed.swift:3:8: warning: 'Mixed' carries both @Container and @Singleton"
            )
        )
        #expect(rendered.contains("the two roles end up in separate graphs"))
        #expect(
            rendered.contains(
                "Split into two declarations: a @Singleton type for the binding, and a separate @Container type for the grouping."
            )
        )
    }

    @Test func strayInjectOnNonScopeTypeMemberRendersAsWarning() throws {
        // The full rendered line includes prefix + message. Pin both
        // halves so the warning text doesn't drift silently.
        let source = """
            struct Plain {
                @Inject var logger: Logger
            }
            """
        let discovery = discover(in: source, sourcePath: "Plain.swift")
        let rendered = renderWarnings(discovery.warnings)
        #expect(rendered.contains("Plain.swift:2:5: warning:"))
        #expect(rendered.contains("@Inject on 'logger' has no effect"))
        #expect(rendered.contains("Add a scope macro to the type"))
    }

    @Test func strayInjectAtModuleScopeRendersAsWarning() throws {
        let source = """
            @Inject let logger: Logger = Logger()
            """
        let discovery = discover(in: source, sourcePath: "Logger.swift")
        let rendered = renderWarnings(discovery.warnings)
        #expect(rendered.contains("Logger.swift:1:1: warning:"))
        #expect(
            rendered.contains(
                "@Inject on 'logger' at module scope has no effect"
            )
        )
        #expect(rendered.contains("use @Provides for module-scope bindings"))
    }

    @Test func injectInitInExtensionRendersAsWarning() throws {
        let source = """
            @Singleton
            struct Foo {
                @Inject var bar: Bar
            }

            extension Foo {
                @Inject init(custom: String) {
                }
            }
            """
        let discovery = discover(in: source, sourcePath: "Foo.swift")
        let rendered = renderWarnings(discovery.warnings)
        #expect(rendered.contains("warning: @Inject on an extension init has no effect"))
        #expect(rendered.contains("'Foo'"))
    }

    @Test func identifierCollisionNamesTheConflictingAccessor() throws {
        // `Logger` and `Logger?` have distinct (type, key) identities
        // but their generated accessor names both sanitise to `logger`
        // (the `?` is dropped). Codegen would emit two `let logger:`
        // lines; Wire catches the collision at graph-validation time
        // with a clear diagnostic.
        let source = """
            @Provides
            let plainLogger: Logger = Logger()

            @Provides
            let optionalLogger: Logger? = nil
            """
        let (errors, rendered) = validate(source: source, sourcePath: "Loggers.swift")
        let validationErrors = try #require(errors)
        #expect(validationErrors.identifierCollisions.count == 1)
        #expect(
            rendered.contains(
                "error: generated accessor name 'logger' collides across multiple bindings"
            )
        )
        #expect(rendered.contains("note: also generates 'logger'"))
    }
}
